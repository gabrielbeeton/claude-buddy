// Buddy: a little Claude Code companion that lives in the corner of your screen.
// It shows what Claude is doing, chats with you, and can look at your screen.
// It talks to Claude through the Buddy mod, using small files in ~/.claude/buddy:
//   sessions/<id>.json  each Claude session's status (written by the mod)
//   inbox/<id>.json     what you said to Buddy (written by this app)
//   outbox/<id>.json    Buddy's replies (written by the mod)
//   shots/<id>.png      a screenshot you asked Buddy to look at (deleted after)

import AppKit
import SwiftUI

// MARK: - Files shared with the Buddy mod

enum Paths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/buddy", isDirectory: true)
    static let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    static let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    static let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    static let shots = root.appendingPathComponent("shots", isDirectory: true)
    static let chat = root.appendingPathComponent("chat.json")
    static let quit = root.appendingPathComponent("quit")

    static func ensure() {
        for dir in [root, sessions, inbox, outbox, shots] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

struct SessionStatus: Decodable {
    let sid: String
    let heartbeat: Double
    let isBusy: Bool
    let activity: String
    let lastTurnEndAt: Double?
}

struct ChatLine: Codable, Identifiable, Equatable {
    var id = UUID()
    let who: String // "me" or "buddy"
    let text: String
    enum CodingKeys: String, CodingKey { case who, text }
}

struct Request: Encodable {
    let id: String
    let kind: String // "say" or "look"
    let text: String
    let image: String?
    let history: [ChatLine]
}

struct Reply: Decodable {
    let id: String
    let text: String
}

enum Mood: String, CaseIterable {
    case idle, working, thinking, looking, happy, sleeping, dragged
}

@discardableResult
func run(_ tool: String, _ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return -1
    }
}

func markdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

// MARK: - What Buddy knows

@MainActor
final class BuddyModel: ObservableObject {
    struct Pending {
        let kind: String
        let since: Date
    }

    @Published var chat: [ChatLine] = []
    @Published var draft = ""
    @Published private(set) var activity = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isConnected = false
    @Published private(set) var pending: [String: Pending] = [:]
    @Published var focusRequest = 0
    var isDragging = false
    var isChatOpen = false
    private(set) var happyUntil = Date.distantPast
    private var lastGood: [String: SessionStatus] = [:]
    private var hasPolled = false

    var onDone: (() -> Void)?
    var onReply: ((String) -> Void)?
    var onPolled: (() -> Void)?
    var setCapturing: ((Bool) -> Void)?
    var onQuit: (() -> Void)?

    static let lookWords = try! NSRegularExpression(
        pattern: #"\b(look|screen|see (this|that|what)|what'?s on)\b"#,
        options: [.caseInsensitive]
    )

    init() { loadChat() }

    var isWaiting: Bool { !pending.isEmpty }
    var isLooking: Bool { pending.values.contains { $0.kind == "look" } }

    var mood: Mood {
        if isDragging { return .dragged }
        if isLooking { return .looking }
        if isWaiting { return .thinking }
        if Date() < happyUntil { return .happy }
        if isBusy { return .working }
        if !isConnected { return .sleeping }
        return .idle
    }

    // Called twice a second.
    func poll() {
        if FileManager.default.fileExists(atPath: Paths.quit.path) {
            try? FileManager.default.removeItem(at: Paths.quit)
            onQuit?()
            return
        }
        readSessions()
        readReplies()
        expireWaits()
        hasPolled = true
        onPolled?()
    }

    private func readSessions() {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970 * 1000
        let urls = (try? fm.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        var seen: [String: SessionStatus] = [:]
        for url in urls where url.pathExtension == "json" {
            let key = url.lastPathComponent
            if let data = try? Data(contentsOf: url),
               let status = try? JSONDecoder().decode(SessionStatus.self, from: data) {
                seen[key] = status
            } else if let old = lastGood[key] {
                seen[key] = old // caught mid-write: keep the last good read
            }
        }
        lastGood = seen
        for (key, status) in seen where now - status.heartbeat > 86_400_000 {
            try? fm.removeItem(at: Paths.sessions.appendingPathComponent(key))
        }

        let alive = seen.values.filter { now - $0.heartbeat < 15_000 }
        let busy = alive.filter(\.isBusy).sorted { $0.heartbeat > $1.heartbeat }
        let nowBusy = !busy.isEmpty
        if hasPolled, isBusy, !nowBusy,
           alive.contains(where: { ($0.lastTurnEndAt ?? 0) > now - 20_000 }) {
            happyUntil = Date().addingTimeInterval(6)
            onDone?()
        }
        if isBusy != nowBusy { isBusy = nowBusy }
        let newActivity = busy.first?.activity ?? ""
        if activity != newActivity { activity = newActivity }
        let connected = !alive.isEmpty
        if isConnected != connected { isConnected = connected }
    }

    private func readReplies() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: Paths.outbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in urls where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard pending[id] != nil else {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, Date().timeIntervalSince(modified) > 600 { try? fm.removeItem(at: url) }
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let reply = try? JSONDecoder().decode(Reply.self, from: data) else { continue }
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: Paths.shots.appendingPathComponent("\(id).png"))
            pending[id] = nil
            add(ChatLine(who: "buddy", text: reply.text))
            if !isChatOpen { onReply?(reply.text) }
        }
    }

    private func expireWaits() {
        let now = Date()
        for (id, wait) in pending where now.timeIntervalSince(wait.since) > (wait.kind == "look" ? 150 : 90) {
            pending[id] = nil
            try? FileManager.default.removeItem(at: Paths.inbox.appendingPathComponent("\(id).json"))
            try? FileManager.default.removeItem(at: Paths.shots.appendingPathComponent("\(id).png"))
            add(ChatLine(who: "buddy", text: "*(I couldn't reach Claude just now. Is a Claude Code session with Buddy open?)*"))
        }
    }

    // Returns false when Buddy can't take the message right now.
    @discardableResult
    func send(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWaiting else { return false }
        let history = Array(chat.suffix(14))
        add(ChatLine(who: "me", text: text))
        guard isConnected else {
            add(ChatLine(who: "buddy", text: Self.asleep))
            return true
        }
        let range = NSRange(text.startIndex..., in: text)
        if Self.lookWords.firstMatch(in: text, range: range) != nil {
            look(question: text, history: history)
        } else {
            post(Request(id: Self.newID(), kind: "say", text: text, image: nil, history: history))
        }
        return true
    }

    func lookNow() {
        guard !isWaiting else { return }
        let question = "What do you see on my screen?"
        let history = Array(chat.suffix(14))
        add(ChatLine(who: "me", text: question))
        guard isConnected else {
            add(ChatLine(who: "buddy", text: Self.asleep))
            return
        }
        look(question: question, history: history)
    }

    static let asleep = "zzz… I'm only awake while Claude is open. Start a Claude Code session with Buddy loaded, then try again!"

    private func look(question: String, history: [ChatLine]) {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            add(ChatLine(who: "buddy", text: "I need permission to see your screen. Turn on **Buddy** in System Settings › Privacy & Security › Screen & System Audio Recording, then ask me again."))
            return
        }
        let id = Self.newID()
        let shot = Paths.shots.appendingPathComponent("\(id).png")
        pending[id] = Pending(kind: "look", since: Date())
        setCapturing?(true)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let captured = run("/usr/sbin/screencapture", ["-x", "-C", "-t", "png", shot.path]) == 0
            if captured { run("/usr/bin/sips", ["-Z", "1600", shot.path]) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setCapturing?(false)
                    guard captured, FileManager.default.fileExists(atPath: shot.path) else {
                        self.pending[id] = nil
                        self.add(ChatLine(who: "buddy", text: "*(I tried to look, but I couldn't take a screenshot.)*"))
                        return
                    }
                    self.post(Request(id: id, kind: "look", text: question, image: shot.path, history: history))
                }
            }
        }
    }

    private func post(_ request: Request) {
        pending[request.id] = Pending(kind: request.kind, since: Date())
        do {
            let data = try JSONEncoder().encode(request)
            let temp = Paths.inbox.appendingPathComponent("\(request.id).tmp")
            try data.write(to: temp)
            try FileManager.default.moveItem(at: temp, to: Paths.inbox.appendingPathComponent("\(request.id).json"))
        } catch {
            pending[request.id] = nil
            add(ChatLine(who: "buddy", text: "*(I couldn't pass that on to Claude: \(error.localizedDescription))*"))
        }
    }

    static func newID() -> String {
        "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
    }

    func add(_ line: ChatLine) {
        chat.append(line)
        if chat.count > 100 { chat.removeFirst(chat.count - 100) }
        saveChat()
    }

    func clearChat() {
        chat = []
        saveChat()
    }

    private func saveChat() {
        if let data = try? JSONEncoder().encode(chat) { try? data.write(to: Paths.chat, options: .atomic) }
    }

    private func loadChat() {
        if let data = try? Data(contentsOf: Paths.chat),
           let lines = try? JSONDecoder().decode([ChatLine].self, from: data) {
            chat = lines
        }
    }
}

// MARK: - Drawing the pet
//
// The orange creature from Claude Code's welcome screen, redrawn as pixel art:
// a block body with two eyes, little arms and four legs. The grid is 18 columns
// by 10 rows of 7-point squares, in a view 150 x 118 points (y grows down).

enum PetRenderer {
    static let size = NSSize(width: 150, height: 118)
    static let s: CGFloat = 7
    static let x0: CGFloat = 12
    static let ground: CGFloat = 92

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }

    static let orange = color(0xD97757)
    static let light = color(0xE8977A)
    static let shade = color(0xB65A3E)
    static let outline = color(0x2A1712, 0.92)
    static let eyeColor = color(0x1E1410)

    // 0 → 1 → 0 over one period
    static func wave(_ t: Double, _ period: Double) -> CGFloat {
        CGFloat(0.5 - 0.5 * cos(2 * .pi * t / period))
    }

    static func draw(_ ctx: CGContext, mood: Mood, t: Double, gaze: CGPoint = .zero, blink: Bool = false, showGround: Bool = true) {
        let s = self.s
        var dy: CGFloat
        switch mood {
        case .idle: dy = -2 * wave(t, 2.6)
        case .working: dy = -3 * wave(t, 0.5)
        case .thinking: dy = -2 * wave(t, 1.8)
        case .looking: dy = -1.5 * wave(t, 1.6)
        case .happy: dy = -14 * CGFloat(abs(sin(.pi * t / 0.6)))
        case .sleeping: dy = -1 * wave(t, 4)
        case .dragged: dy = 0
        }
        dy = (dy * 2).rounded() / 2
        let top = ground - 10 * s + dy
        let feetLift: CGFloat = mood == .happy ? dy : 0

        func cell(_ col: CGFloat, _ row: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x0 + col * s, y: top + row * s, width: w * s, height: h * s)
        }

        // Arms
        var armL = cell(1, 4, 2, 2)
        var armR = cell(15, 4, 2, 2)
        switch mood {
        case .happy:
            let up = sin(2 * .pi * t / 0.6) > 0
            armL = cell(1, up ? 2 : 4, 2, 2)
            armR = cell(15, up ? 4 : 2, 2, 2)
        case .dragged:
            armL = cell(1, 2, 2, 2)
            armR = cell(15, 2, 2, 2)
        case .working:
            let pump: CGFloat = sin(2 * .pi * t / 0.32) > 0 ? -1 : 1
            armL = armL.offsetBy(dx: 0, dy: pump)
            armR = armR.offsetBy(dx: 0, dy: -pump)
        default:
            break
        }

        // Legs: planted on the ground while the body bobs, so they stretch a little
        let body = cell(3, 0, 12, 8)
        let bodyBottom = body.maxY
        var legs: [CGRect] = []
        for (i, col) in [4.0, 6.0, 11.0, 13.0].enumerated() {
            var bottom = ground + feetLift
            var dx: CGFloat = 0
            switch mood {
            case .working:
                let step = sin(2 * .pi * t / 0.32 + (i % 2 == 0 ? 0 : .pi))
                bottom -= max(0, CGFloat(step)) * 5
            case .dragged:
                bottom = bodyBottom + 2.6 * s
                dx = CGFloat(sin(2 * .pi * t / 0.7 + Double(i))) * 1.5
            default:
                break
            }
            legs.append(CGRect(x: x0 + CGFloat(col) * s + dx, y: bodyBottom - 1, width: s, height: max(3, bottom - bodyBottom + 1)))
        }

        // Shadow on the ground
        if showGround {
            ctx.setShouldAntialias(true)
            let lift = min(1, -dy / 20)
            let width = 76 * (1 - 0.35 * lift)
            ctx.setFillColor(color(0x000000, 0.22 * (1 - 0.4 * lift)))
            ctx.fillEllipse(in: CGRect(x: 75 - width / 2, y: ground - 2, width: width, height: 6))
        }

        // Outline first, then the orange on top, so parts join without seams
        let parts = [body, armL, armR] + legs
        ctx.setShouldAntialias(false)
        ctx.setFillColor(outline)
        for rect in parts { ctx.fill(rect.insetBy(dx: -1.5, dy: -1.5)) }
        ctx.setFillColor(orange)
        for rect in parts { ctx.fill(rect) }
        ctx.setFillColor(light)
        ctx.fill(CGRect(x: body.minX + s, y: body.minY, width: body.width - 2 * s, height: s / 2))
        ctx.setFillColor(shade)
        ctx.fill(CGRect(x: body.minX, y: body.maxY - s / 2, width: body.width, height: s / 2))
        for rect in legs + [armL, armR] {
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 2.5, width: rect.width, height: 2.5))
        }

        drawEyes(ctx, mood: mood, t: t, gaze: gaze, blink: blink, top: top)
        drawExtras(ctx, mood: mood, t: t, top: top)

        // Status light under the pet
        if showGround {
            let (hex, pulses): (UInt32, Bool) = {
                switch mood {
                case .working: return (0xD97757, true)
                case .happy: return (0x4CC38A, false)
                case .thinking, .looking: return (0x8AB4F8, true)
                case .sleeping: return (0x777777, false)
                case .idle, .dragged: return (0x9A9A9A, false)
                }
            }()
            let alpha: CGFloat = pulses ? 0.55 + 0.45 * wave(t, 1.0) : (mood == .sleeping ? 0.35 : 0.6)
            ctx.setShouldAntialias(true)
            ctx.setFillColor(color(hex, alpha))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 60, y: ground + 12, width: 30, height: 5), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            ctx.fillPath()
        }
    }

    static func drawEyes(_ ctx: CGContext, mood: Mood, t: Double, gaze: CGPoint, blink: Bool, top: CGFloat) {
        let s = self.s
        var look = gaze
        switch mood {
        case .thinking: look = CGPoint(x: 1.5, y: -3)
        case .looking: look = CGPoint(x: 2.5 * CGFloat(sin(2 * .pi * t / 1.6)), y: 0)
        case .sleeping, .happy, .dragged: look = .zero
        case .idle, .working: break
        }
        look = CGPoint(x: (look.x * 2).rounded() / 2, y: (look.y * 2).rounded() / 2)

        for col in [5.0, 12.0] {
            let x = x0 + CGFloat(col) * s + look.x
            let y = top + 2 * s + look.y
            ctx.setFillColor(eyeColor)
            switch mood {
            case .sleeping:
                ctx.setShouldAntialias(false)
                ctx.fill(CGRect(x: x - 1, y: y + 2 * s - 5, width: s + 2, height: 2.5))
            case .happy:
                stroke(ctx, [(x - 0.5, y + 11), (x + s / 2, y + 4), (x + s + 0.5, y + 11)])
            case .dragged:
                let isLeft = col < 10
                stroke(ctx, isLeft
                    ? [(x, y + 2), (x + s, y + 7), (x, y + 12)]
                    : [(x + s, y + 2), (x, y + 7), (x + s, y + 12)])
            case .idle, .working, .thinking, .looking:
                ctx.setShouldAntialias(false)
                if blink {
                    ctx.fill(CGRect(x: x, y: y + 2 * s - 4, width: s, height: 2.5))
                } else {
                    let tall: CGFloat = mood == .looking ? 2.3 * s : 2 * s
                    ctx.fill(CGRect(x: x, y: y + 2 * s - tall, width: s, height: tall))
                    ctx.setFillColor(color(0xFFFFFF, 0.85))
                    ctx.fill(CGRect(x: x + 1, y: y + 2 * s - tall + 1.5, width: 2.5, height: 3))
                }
            }
        }
    }

    static func stroke(_ ctx: CGContext, _ points: [(CGFloat, CGFloat)]) {
        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(eyeColor)
        ctx.setLineWidth(2.6)
        ctx.setLineCap(.square)
        ctx.setLineJoin(.miter)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() { ctx.addLine(to: CGPoint(x: point.0, y: point.1)) }
        ctx.strokePath()
    }

    static let zGlyph = ["####", "..#.", ".#..", "####"]
    static let sparkle = [".#.", "###", ".#."]

    static func pixels(_ ctx: CGContext, _ pattern: [String], at origin: CGPoint, size: CGFloat, color fill: CGColor) {
        ctx.setShouldAntialias(false)
        ctx.setFillColor(fill)
        for (row, line) in pattern.enumerated() {
            for (col, char) in line.enumerated() where char == "#" {
                ctx.fill(CGRect(x: origin.x + CGFloat(col) * size, y: origin.y + CGFloat(row) * size, width: size, height: size))
            }
        }
    }

    static func drawExtras(_ ctx: CGContext, mood: Mood, t: Double, top: CGFloat) {
        let s = self.s
        switch mood {
        case .sleeping:
            for i in 0..<2 {
                let phase = CGFloat((t / 3.2 + Double(i) / 2).truncatingRemainder(dividingBy: 1))
                let origin = CGPoint(x: x0 + 15 * s + 2 + phase * 14, y: top + 4 - phase * 24)
                pixels(ctx, zGlyph, at: origin, size: 1.5 + phase * 1.2, color: color(0xF0E6DF, 0.9 * sin(.pi * phase)))
            }
        case .thinking:
            for i in 0..<3 {
                let alpha = 0.35 + 0.65 * wave(t + Double(i) * 0.2, 1.1)
                ctx.setShouldAntialias(false)
                ctx.setFillColor(color(0xF0E6DF, alpha))
                ctx.fill(CGRect(x: x0 + 15 * s + CGFloat(i) * 7, y: top - 8, width: 4, height: 4))
            }
        case .happy:
            let spots: [(CGFloat, CGFloat, Double)] = [(4, 18, 0), (134, 12, 0.35), (139, 46, 0.7), (2, 50, 0.5)]
            for (x, y, offset) in spots {
                pixels(ctx, sparkle, at: CGPoint(x: x, y: y), size: 2.5, color: color(0xFFD9A8, wave(t + offset, 0.9)))
            }
        case .idle, .working, .looking, .dragged:
            break
        }
    }
}

// MARK: - The pet window

final class FloatingPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    static func make(size: NSSize, allowsKey: Bool) -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.allowsKey = allowsKey
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }
}

final class ClickThroughHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PetView: NSView {
    let model: BuddyModel
    var onClick: (() -> Void)?
    var onMove: (() -> Void)?
    var onDrop: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var didDrag = false
    private var nextBlink = CACurrentMediaTime() + 3
    private var blinkUntil: CFTimeInterval = 0

    init(model: BuddyModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: PetRenderer.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = CACurrentMediaTime()
        if t > nextBlink {
            blinkUntil = t + 0.13
            nextBlink = t + Double.random(in: 2.5...5.5)
        }
        PetRenderer.draw(ctx, mood: model.mood, t: t, gaze: gaze(), blink: t < blinkUntil)
    }

    // The eyes follow your pointer a little.
    private func gaze() -> CGPoint {
        guard let window else { return .zero }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - window.frame.midX
        let dy = mouse.y - window.frame.midY
        let length = max(1, hypot(dx, dy))
        let strength = min(1, length / 200)
        return CGPoint(x: dx / length * 2 * strength, y: -dy / length * 2 * strength)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = windowStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        if !didDrag, hypot(dx, dy) < 3 { return }
        if !didDrag {
            didDrag = true
            model.isDragging = true
        }
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        onMove?()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        if didDrag {
            model.isDragging = false
            onMove?()
            onDrop?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

// MARK: - The pop-out tab
//
// A little tab on the screen edge beside Buddy: click it to tuck Buddy away,
// click it again to bring Buddy back. It pops out a bit under the pointer, and
// its dot shows what Claude is up to even while Buddy is hidden.

final class TabView: NSView {
    enum Edge { case left, right }
    static let size = NSSize(width: 20, height: 46)

    var edge: Edge = .right { didSet { needsDisplay = true } }
    var isPetHidden = false {
        didSet {
            toolTip = isPetHidden ? "Show Buddy" : "Hide Buddy"
            needsDisplay = true
        }
    }
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private var statusColor = PetRenderer.color(0x9A9A9A, 0.6)
    private var pulses = false
    private var isHovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setStatus(_ color: CGColor, pulses: Bool) {
        if pulses || self.pulses || color != statusColor { needsDisplay = true }
        statusColor = color
        self.pulses = pulses
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if !event.modifierFlags.contains(.control) { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let width: CGFloat = isHovered ? 20 : 14
        let height = bounds.height
        // A rounded tab that runs past the screen edge, so it looks flush with it.
        let shape = edge == .right
            ? CGRect(x: bounds.width - width, y: 0, width: width + 10, height: height)
            : CGRect(x: -10, y: 0, width: width + 10, height: height)
        let path = CGPath(roundedRect: shape.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 7, cornerHeight: 7, transform: nil)
        ctx.setShouldAntialias(true)
        ctx.addPath(path)
        ctx.setFillColor(PetRenderer.color(0x1C1C1E, isHovered ? 0.97 : 0.88))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(PetRenderer.color(0xFFFFFF, 0.16))
        ctx.setLineWidth(1)
        ctx.strokePath()

        // Chevron: points out of the edge when Buddy is hidden, into it when shown.
        let cx = edge == .right ? bounds.width - width / 2 : width / 2
        let pointsLeft = (edge == .right) == isPetHidden
        let dx: CGFloat = pointsLeft ? -2.5 : 2.5
        ctx.setStrokeColor(PetRenderer.color(0xFFFFFF, isHovered ? 0.95 : 0.7))
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx - dx, y: 13))
        ctx.addLine(to: CGPoint(x: cx + dx, y: 18.5))
        ctx.addLine(to: CGPoint(x: cx - dx, y: 24))
        ctx.strokePath()

        // Status dot
        var dot = statusColor
        if pulses { dot = dot.copy(alpha: 0.4 + 0.6 * PetRenderer.wave(CACurrentMediaTime(), 1.0)) ?? dot }
        ctx.setFillColor(dot)
        ctx.fillEllipse(in: CGRect(x: cx - 2.5, y: 31, width: 5, height: 5))
    }
}

// MARK: - The status bubble and the chat

final class BubbleState: ObservableObject {
    @Published var text = ""
}

struct BubbleView: View {
    @ObservedObject var state: BubbleState
    let onTap: () -> Void

    var body: some View {
        Text(state.text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Color(white: 0.10).opacity(0.94)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ChatBubble: View {
    let line: ChatLine

    var body: some View {
        let isMine = line.who == "me"
        HStack {
            if isMine { Spacer(minLength: 40) }
            Text(markdown(line.text))
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isMine ? claudeOrange.opacity(0.9) : Color.white.opacity(0.09))
                )
                .foregroundStyle(isMine ? Color.white : Color.primary)
            if !isMine { Spacer(minLength: 40) }
        }
    }
}

struct TypingLine: View {
    let text: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let dots = Int(context.date.timeIntervalSince1970 / 0.4) % 4
            Text("Buddy is \(text)" + String(repeating: ".", count: dots))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

struct ChatView: View {
    @ObservedObject var model: BuddyModel
    let onClose: () -> Void
    let onLook: () -> Void
    @FocusState private var isFocused: Bool

    private var status: String {
        if !model.isConnected { return "Asleep: no Claude session with Buddy is open" }
        if model.isBusy { return model.activity.isEmpty ? "Claude is working…" : model.activity }
        return "Claude is idle"
    }

    private var statusColor: Color {
        if !model.isConnected { return .gray }
        return model.isBusy ? claudeOrange : Color(red: 0.30, green: 0.76, blue: 0.54)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Buddy").font(.system(size: 13, weight: .semibold))
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.chat.isEmpty {
                            Text("Hi! I'm Buddy. Ask me anything, or press the eye and I'll look at your screen.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                        ForEach(model.chat) { line in
                            ChatBubble(line: line).id(line.id)
                        }
                        if model.isWaiting {
                            TypingLine(text: model.isLooking ? "looking at your screen" : "thinking").id("typing")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.chat.count) { _, _ in
                    withAnimation { proxy.scrollTo(model.chat.last?.id, anchor: .bottom) }
                }
                .onChange(of: model.isWaiting) { _, waiting in
                    if waiting { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                }
                .onAppear { proxy.scrollTo(model.chat.last?.id, anchor: .bottom) }
            }

            HStack(spacing: 8) {
                TextField("Talk to Buddy…", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)
                    .onSubmit(sendDraft)
                Button(action: onLook) {
                    Image(systemName: "eye").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Look at my screen")
                .disabled(model.isWaiting)
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(claudeOrange)
                .disabled(model.isWaiting || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
            .padding(10)
        }
        .frame(width: AppDelegate.chatSize.width, height: AppDelegate.chatSize.height)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .onExitCommand(perform: onClose)
        .onChange(of: model.focusRequest) { _, _ in isFocused = true }
        .onAppear { isFocused = true }
    }

    private func sendDraft() {
        if model.send(model.draft) { model.draft = "" }
    }
}

// MARK: - The app

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let chatSize = NSSize(width: 320, height: 400)

    let model = BuddyModel()
    let bubbleState = BubbleState()
    var pet: FloatingPanel!
    var petView: PetView!
    var bubble: FloatingPanel!
    var chatPanel: FloatingPanel!
    var tab: FloatingPanel!
    var tabView: TabView!
    var hasUnread = false
    var openChatOnShow = false
    var timers: [Timer] = []
    var activity: NSObjectProtocol?
    var flashText: String?
    var flashUntil = Date.distantPast
    var flashOpensChat = false
    var bubbleOpensChat = false
    var isCapturing = false
    var chatWasOpen = false

    var showStatus: Bool {
        get { UserDefaults.standard.object(forKey: "showStatus") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showStatus") }
    }

    var isPetHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "petHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "petHidden") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensure()
        try? FileManager.default.removeItem(at: Paths.quit)
        // Keep animating smoothly while in the background (no App Nap).
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Buddy is keeping you company")

        petView = PetView(model: model)
        pet = FloatingPanel.make(size: PetRenderer.size, allowsKey: false)
        pet.contentView = petView
        pet.setFrameOrigin(initialOrigin())
        if !isPetHidden { pet.orderFrontRegardless() }

        tabView = TabView(frame: NSRect(origin: .zero, size: TabView.size))
        tabView.isPetHidden = isPetHidden
        tabView.onClick = { [weak self] in self?.togglePetHidden() }
        tabView.menuProvider = { [weak self] in self?.makeMenu() }
        tab = FloatingPanel.make(size: TabView.size, allowsKey: false)
        tab.contentView = tabView
        layoutTab()
        tab.orderFrontRegardless()

        let bubbleHost = ClickThroughHost(rootView: BubbleView(state: bubbleState) { [weak self] in self?.bubbleTapped() })
        bubbleHost.sizingOptions = []
        bubble = FloatingPanel.make(size: NSSize(width: 200, height: 40), allowsKey: false)
        bubble.contentView = bubbleHost

        let chatHost = ClickThroughHost(rootView: ChatView(
            model: model,
            onClose: { [weak self] in self?.closeChat() },
            onLook: { [weak self] in self?.model.lookNow() }
        ))
        chatHost.sizingOptions = []
        chatPanel = FloatingPanel.make(size: Self.chatSize, allowsKey: true)
        chatPanel.contentView = chatHost
        chatPanel.hasShadow = true
        chatPanel.appearance = NSAppearance(named: .darkAqua)

        petView.onClick = { [weak self] in self?.toggleChat() }
        petView.onMove = { [weak self] in self?.layoutAttached() }
        petView.onDrop = { [weak self] in self?.savePosition() }
        petView.menuProvider = { [weak self] in self?.makeMenu() }

        model.onDone = { [weak self] in self?.flash("Claude is done. Your turn! ✨", seconds: 6) }
        model.onReply = { [weak self] text in
            guard let self else { return }
            if self.isPetHidden {
                self.hasUnread = true
                self.openChatOnShow = true
            } else {
                self.flash("Buddy: \(text)", seconds: 10, opensChat: true)
            }
        }
        model.onPolled = { [weak self] in self?.refreshBubble() }
        model.setCapturing = { [weak self] on in self?.setCapturing(on) }
        model.onQuit = { NSApp.terminate(nil) }

        let frames = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drawFrame() }
        }
        let polls = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.poll() }
        }
        for timer in [frames, polls] {
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
        model.poll()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isPetHidden { setPetHidden(false) } // `/buddy` brings a hidden Buddy back
        return false
    }

    func drawFrame() {
        if pet.isVisible { petView.needsDisplay = true }
        let (hex, alpha, pulses): (UInt32, CGFloat, Bool) = {
            if hasUnread { return (0x8AB4F8, 1, true) }
            switch model.mood {
            case .working: return (0xD97757, 1, true)
            case .happy: return (0x4CC38A, 1, false)
            case .thinking, .looking: return (0x8AB4F8, 1, true)
            case .sleeping: return (0x9A9A9A, 0.3, false)
            case .idle, .dragged: return (0x9A9A9A, 0.65, false)
            }
        }()
        tabView.setStatus(PetRenderer.color(hex, alpha), pulses: pulses)
    }

    // MARK: Hiding

    @objc func togglePetHidden() { setPetHidden(!isPetHidden) }

    func setPetHidden(_ hidden: Bool) {
        guard hidden != isPetHidden else { return }
        isPetHidden = hidden
        tabView.isPetHidden = hidden
        let home = NSRect(origin: initialOrigin(), size: PetRenderer.size)
        let visible = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: home.midX, y: home.midY)) } ?? NSScreen.main)?.visibleFrame ?? home
        let toRight = home.midX >= visible.midX
        let away = home.offsetBy(dx: toRight ? visible.maxX - home.minX + 8 : visible.minX - home.maxX - 8, dy: 0)
        if hidden {
            if chatPanel.isVisible { closeChat() }
            bubble.orderOut(nil)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                self.pet.animator().setFrame(away, display: true)
                self.pet.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard self.isPetHidden else { return }
                    self.pet.orderOut(nil)
                    self.pet.setFrame(home, display: false)
                    self.pet.alphaValue = 1
                }
            })
        } else {
            pet.setFrame(away, display: false)
            pet.alphaValue = 0
            pet.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                self.pet.animator().setFrame(home, display: true)
                self.pet.animator().alphaValue = 1
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard !self.isPetHidden else { return }
                    self.hasUnread = false
                    self.layoutTab()
                    if self.openChatOnShow {
                        self.openChatOnShow = false
                        self.openChat()
                    } else {
                        self.refreshBubble()
                    }
                }
            })
        }
        tab.orderFrontRegardless()
    }

    func layoutTab() {
        let home = pet.frame
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: home.midX, y: home.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? home
        let size = TabView.size
        let onRight = home.midX >= visible.midX
        let spriteMiddle = home.minY + PetRenderer.size.height - 57
        let y = min(max(spriteMiddle - size.height / 2, visible.minY + 4), visible.maxY - size.height - 4)
        let x = onRight ? visible.maxX - size.width : visible.minX
        tab.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        tabView.edge = onRight ? .right : .left
    }

    // MARK: Position

    func defaultOrigin() -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - PetRenderer.size.width - 18, y: visible.minY + 2)
    }

    func initialOrigin() -> NSPoint {
        if let saved = UserDefaults.standard.array(forKey: "petOrigin") as? [Double], saved.count == 2 {
            let origin = NSPoint(x: saved[0], y: saved[1])
            if isOnScreen(origin) { return origin }
        }
        return defaultOrigin()
    }

    func isOnScreen(_ origin: NSPoint) -> Bool {
        let center = NSPoint(x: origin.x + PetRenderer.size.width / 2, y: origin.y + PetRenderer.size.height / 2)
        return NSScreen.screens.contains { $0.frame.contains(center) }
    }

    func savePosition() {
        UserDefaults.standard.set([Double(pet.frame.origin.x), Double(pet.frame.origin.y)], forKey: "petOrigin")
    }

    func keepOnScreen() {
        if !isOnScreen(pet.frame.origin) {
            pet.setFrameOrigin(defaultOrigin())
            savePosition()
        }
        layoutAttached()
    }

    @objc func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "petOrigin")
        pet.setFrameOrigin(defaultOrigin())
        layoutAttached()
    }

    // MARK: Chat

    func toggleChat() {
        if chatPanel.isVisible { closeChat() } else { openChat() }
    }

    func openChat() {
        if isPetHidden {
            openChatOnShow = true // opens once Buddy is back
            setPetHidden(false)
            return
        }
        model.isChatOpen = true
        flashUntil = .distantPast
        layoutChat()
        NSApp.activate()
        chatPanel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
        refreshBubble()
    }

    func closeChat() {
        model.isChatOpen = false
        chatPanel.orderOut(nil)
        if NSApp.isActive { NSApp.deactivate() }
        refreshBubble()
    }

    func layoutAttached() {
        if chatPanel.isVisible { layoutChat() }
        if bubble.isVisible { layoutBubble() }
        layoutTab()
    }

    func layoutChat() {
        let petFrame = pet.frame
        let visible = (pet.screen ?? NSScreen.main)?.visibleFrame ?? petFrame
        let size = Self.chatSize
        let x = min(max(petFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        var y = petFrame.maxY - 10
        if y + size.height > visible.maxY - 8 { y = max(visible.minY + 8, petFrame.minY - size.height + 10) }
        chatPanel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    func layoutBubble() {
        let petFrame = pet.frame
        let visible = (pet.screen ?? NSScreen.main)?.visibleFrame ?? petFrame
        let size = bubble.frame.size
        let x = min(max(petFrame.midX - size.width / 2, visible.minX + 6), visible.maxX - size.width - 6)
        let y = min(petFrame.maxY - 16, visible.maxY - size.height)
        bubble.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Bubble

    func flash(_ text: String, seconds: Double, opensChat: Bool = false) {
        flashText = text
        flashUntil = Date().addingTimeInterval(seconds)
        flashOpensChat = opensChat
        refreshBubble()
    }

    func refreshBubble() {
        guard !isCapturing else { return }
        if isPetHidden {
            if bubble.isVisible { bubble.orderOut(nil) }
            return
        }
        var text: String?
        var opensChat = false
        if let flashText, Date() < flashUntil {
            text = flashText
            opensChat = flashOpensChat
        } else if showStatus && model.isBusy {
            text = model.activity.isEmpty ? "Claude is working…" : model.activity
        }
        if chatPanel.isVisible { text = nil }
        guard let raw = text else {
            if bubble.isVisible { bubble.orderOut(nil) }
            return
        }
        bubbleOpensChat = opensChat
        let line = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
        let clipped = line.count > 64 ? String(line.prefix(63)) + "…" : line
        if bubbleState.text != clipped || !bubble.isVisible {
            bubbleState.text = clipped
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let width = ceil((clipped as NSString).size(withAttributes: [.font: font]).width) + 36
            bubble.setContentSize(NSSize(width: min(width, 320), height: 40))
        }
        layoutBubble()
        if !bubble.isVisible { bubble.orderFrontRegardless() }
    }

    func bubbleTapped() {
        if bubbleOpensChat { openChat() } else { openClaude() }
    }

    func setCapturing(_ on: Bool) {
        isCapturing = on
        if on {
            chatWasOpen = chatPanel.isVisible
            chatPanel.orderOut(nil)
            bubble.orderOut(nil)
        } else {
            if chatWasOpen {
                layoutChat()
                chatPanel.makeKeyAndOrderFront(nil)
            }
            refreshBubble()
        }
    }

    // MARK: Menu

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, checked: Bool? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
        add(chatPanel.isVisible ? "Close Chat" : "Chat with Buddy", #selector(menuChat))
        add(isPetHidden ? "Show Buddy" : "Hide Buddy", #selector(togglePetHidden))
        add("Look at My Screen", #selector(menuLook))
        add("Open Claude", #selector(menuOpenClaude))
        menu.addItem(.separator())
        add("Show What Claude Is Doing", #selector(menuToggleStatus), checked: showStatus)
        add("Clear Chat", #selector(menuClear))
        add("Move Back to Corner", #selector(resetPosition))
        menu.addItem(.separator())
        add("Quit Buddy", #selector(menuQuit))
        return menu
    }

    @objc func menuChat() { toggleChat() }
    @objc func menuLook() {
        if !chatPanel.isVisible { openChat() }
        model.lookNow()
    }
    @objc func menuOpenClaude() { openClaude() }
    @objc func menuToggleStatus() {
        showStatus.toggle()
        refreshBubble()
    }
    @objc func menuClear() { model.clearChat() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    func openClaude() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Rendering to files (app icon, previews)

func renderPNG(size: NSSize, scale: CGFloat, to path: String, draw: (CGContext) -> Void) {
    let width = Int(size.width * scale)
    let height = Int(size.height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: scale, y: -scale)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

func renderIcon(to path: String) {
    renderPNG(size: NSSize(width: 1024, height: 1024), scale: 1, to: path) { ctx in
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let colors = [PetRenderer.color(0x2B2724), PetRenderer.color(0x161413)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.translateBy(x: 512 - 75 * 5.4, y: 540 - 57 * 5.4)
        ctx.scaleBy(x: 5.4, y: 5.4)
        PetRenderer.draw(ctx, mood: .idle, t: 0, showGround: false)
        ctx.restoreGState()
    }
}

func renderPreview(mood: Mood, t: Double, to path: String) {
    renderPNG(size: PetRenderer.size, scale: 3, to: path) { ctx in
        ctx.setFillColor(PetRenderer.color(0x1C1C1E))
        ctx.fill(CGRect(origin: .zero, size: PetRenderer.size))
        PetRenderer.draw(ctx, mood: mood, t: t)
    }
}

// MARK: - Start

@main
struct BuddyMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--render-icon" {
            renderIcon(to: args[2])
            return
        }
        if args.count >= 4, args[1] == "--render", let mood = Mood(rawValue: args[2]) {
            renderPreview(mood: mood, t: args.count >= 5 ? Double(args[4]) ?? 0.3 : 0.3, to: args[3])
            return
        }
        if let me = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: me).count > 1 {
            return // already running
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
