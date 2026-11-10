# Tries Buddy.exe for real on a Windows desktop: starts it, clicks it, types to it, hides
# and shows it, drags it, and checks what it does. Screenshots go to -Out.
#
#   smoke.ps1               this script plays the part of the Buddy mod
#   smoke.ps1 -Live         a real Claude Code session with the Buddy mod answers
#                           (needs "claude" and "node"; talks to test/fake-api.mjs, not the internet)
#
# It runs Buddy with a throwaway home folder, so it never touches your own Buddy.
param([string]$Out = 'artifacts', [switch]$Live)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktop = Split-Path -Parent $here
$repo = Split-Path -Parent $desktop
$exe = Join-Path $desktop 'build\Buddy.exe'
if (-not (Test-Path $exe)) {
    Write-Host "Build first: $exe is missing."
    exit 1
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Win {
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    delegate bool EnumProc(IntPtr window, IntPtr data);

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);

    public static string Title(IntPtr window) {
        StringBuilder text = new StringBuilder(512);
        GetWindowText(window, text, 512);
        return text.ToString();
    }

    // The first window of that program whose title starts with the prefix.
    public static IntPtr Find(int pid, string prefix) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr data) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == (uint)pid && Title(window).StartsWith(prefix)) { found = window; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // How many windows of that program are on screen.
    public static int Visible(int pid) {
        int count = 0;
        EnumWindows(delegate(IntPtr window, IntPtr data) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == (uint)pid && IsWindowVisible(window)) count++;
            return true;
        }, IntPtr.Zero);
        return count;
    }

    // left, top, right, bottom
    public static int[] Rect(IntPtr window) {
        RECT r;
        GetWindowRect(window, out r);
        return new int[] { r.Left, r.Top, r.Right, r.Bottom };
    }
}
'@
[void][Win]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:failures = New-Object System.Collections.ArrayList
$script:buddy = $null

function Check([string]$name, $ok, [string]$detail = '') {
    if ($ok) {
        Write-Host "pass  $name"
    } else {
        Write-Host "FAIL  $name  $detail"
        [void]$script:failures.Add($name)
    }
}

# Runs the test until it gives something true, or the time is up.
function Wait-For([scriptblock]$test, [int]$seconds = 15) {
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
        $value = & $test
        if ($value) { return $value }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Handle([string]$prefix) { return [Win]::Find($script:buddy.Id, $prefix) }

function Shown([string]$prefix) {
    $window = Handle $prefix
    return (($window -ne [IntPtr]::Zero) -and [Win]::IsWindowVisible($window))
}

function Move-Mouse([int]$x, [int]$y) {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $ax = [uint32][Math]::Round($x * 65535.0 / ($screen.Width - 1))
    $ay = [uint32][Math]::Round($y * 65535.0 / ($screen.Height - 1))
    [Win]::mouse_event(0x8001, $ax, $ay, 0, [UIntPtr]::Zero)
    [void][Win]::SetCursorPos($x, $y)
}

function Click([int]$x, [int]$y, [switch]$Right) {
    Move-Mouse $x $y
    Start-Sleep -Milliseconds 250
    if ($Right) { $down = 0x0008; $up = 0x0010 } else { $down = 0x0002; $up = 0x0004 }
    [Win]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [Win]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 250
}

function Shot([string]$name) {
    try {
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
        $graphics.Dispose()
        $bitmap.Save((Join-Path $Out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
    } catch {
        Write-Host "      (no screenshot ${name}: $_)"
    }
}

function Read-Json([string]$path) {
    try { return (Get-Content -Raw -Encoding UTF8 -Path $path | ConvertFrom-Json) } catch { return $null }
}

function Write-Text([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function NowMs { return [long](([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalMilliseconds) }

function ChatHas([string]$who, [string]$text) {
    $lines = Read-Json (Join-Path $root 'chat.json')
    foreach ($line in @($lines)) {
        if ($line -and $line.who -eq $who -and $line.text -eq $text) { return $true }
    }
    return $false
}

# Standing in for the mod: take the next request out of the inbox...
function Next-Request([int]$seconds = 20) {
    $inbox = Join-Path $root 'inbox'
    $file = Wait-For {
        $found = @(Get-ChildItem -Path $inbox -Filter '*.json' -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) { $found[0].FullName }
    } $seconds
    if (-not $file) { return $null }
    $request = Read-Json $file
    Remove-Item -Force $file
    return $request
}

# ...and answer it.
function Reply($request, [string]$text) {
    if (-not $request) { return }
    $outbox = Join-Path $root 'outbox'
    New-Item -ItemType Directory -Force -Path $outbox | Out-Null
    $temp = Join-Path $outbox ($request.id + '.tmp')
    Write-Text $temp (@{ id = $request.id; text = $text } | ConvertTo-Json -Compress)
    Move-Item -Force $temp (Join-Path $outbox ($request.id + '.json'))
}

function Write-Session([bool]$busy, [string]$activity, $endedAt) {
    $status = @{ v = 1; sid = 'smoke-test'; heartbeat = (NowMs) + 3600000; isBusy = $busy; activity = $activity; lastTurnEndAt = $endedAt }
    $temp = Join-Path $root 'sessions\smoke-test.tmp'
    Write-Text $temp ($status | ConvertTo-Json -Compress)
    Move-Item -Force $temp (Join-Path $root 'sessions\smoke-test.json')
}

function Pet-Middle {
    $r = [Win]::Rect((Handle 'Buddy Pet'))
    $unit = ($r[2] - $r[0]) / 150.0
    return @([int]($r[0] + 75 * $unit), [int]($r[1] + 50 * $unit))
}

# ---- Pictures of every mood

foreach ($mood in 'idle', 'working', 'thinking', 'looking', 'happy', 'sleeping', 'dragged') {
    $picture = Join-Path $Out "mood-$mood.png"
    $draw = Start-Process -FilePath $exe -ArgumentList '--render', $mood, "`"$picture`"", '0.3' -Wait -PassThru
    Check "draws the $mood pet" (($draw.ExitCode -eq 0) -and (Test-Path $picture))
}

# ---- A throwaway home folder

$profileDir = Join-Path ([System.IO.Path]::GetTempPath()) ('buddy-smoke-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$root = Join-Path $profileDir '.claude\buddy'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'sessions') | Out-Null
$env:USERPROFILE = $profileDir

$api = $null
$claude = $null
$releaseFile = Join-Path $profileDir 'release'

try {
    if ($Live) {
        $port = 18900 + (Get-Random -Maximum 90)
        $env:HOME = $profileDir
        $env:CLAUDE_CONFIG_DIR = Join-Path $profileDir '.claude'
        $env:ANTHROPIC_API_KEY = 'test-key'
        $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$port"
        $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
        $env:DISABLE_AUTOUPDATER = '1'
        $env:FAKE_API_PORT = "$port"
        $env:FAKE_API_LOG = Join-Path $Out 'fake-api.log'
        $env:RELEASE_FILE = $releaseFile
        $api = Start-Process -FilePath 'node' -ArgumentList "`"$(Join-Path $here 'fake-api.mjs')`"" -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 1
        $command = "claude -p E2E-MAIN-TURN --plugin-dir `"$repo`" --model claude-haiku-5-5 > `"$(Join-Path $Out 'claude.log')`" 2>&1"
        $claude = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $command -WorkingDirectory $profileDir -PassThru -WindowStyle Hidden
        $session = Wait-For {
            foreach ($file in @(Get-ChildItem -Path (Join-Path $root 'sessions') -Filter '*.json' -ErrorAction SilentlyContinue)) {
                $status = Read-Json $file.FullName
                if ($status -and $status.isBusy) { return $file.FullName }
            }
        } 120
        Check 'a real Claude Code session with the Buddy mod is running' $session
        if (-not $session) { throw 'the Claude Code session did not start' }
    }

    # ---- Start Buddy

    $script:buddy = Start-Process -FilePath $exe -PassThru
    $null = $script:buddy.Handle
    $started = Wait-For { Shown 'Buddy Pet' } 30
    Check 'the pet appears on the desktop' $started
    if (-not $started) { throw 'Buddy did not start' }
    Start-Sleep -Milliseconds 800

    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $r = [Win]::Rect((Handle 'Buddy Pet'))
    $unit = ($r[2] - $r[0]) / 150.0
    Write-Host ("      screen work area {0}x{1}, scale {2:N2}, pet at {3},{4} to {5},{6}" -f $area.Width, $area.Height, $unit, $r[0], $r[1], $r[2], $r[3])
    $inCorner = ($r[2] -le $area.Right) -and ($r[2] -ge $area.Right - 40 * $unit) -and ($r[3] -le $area.Bottom) -and ($r[3] -ge $area.Bottom - 20 * $unit)
    Check 'it stands in the bottom-right corner, above the taskbar' $inCorner
    $t = [Win]::Rect((Handle 'Buddy Tab'))
    Check 'its tab sits on the screen edge' ((Shown 'Buddy Tab') -and ($t[2] -eq $area.Right)) "tab right edge $($t[2]), screen $($area.Right)"

    if ($Live) {
        $bubble = Wait-For { Shown 'Buddy Bubble' } 15
        Check 'the bubble shows what the real session is doing' $bubble ([Win]::Title((Handle 'Buddy Bubble')))
        Write-Host "      $([Win]::Title((Handle 'Buddy Bubble')))"
        Shot '02-working'
    } else {
        Shot '01-asleep'
        Check 'no bubble while no Claude session is open' (-not (Shown 'Buddy Bubble'))

        Write-Session $true 'Editing main.py' $null
        $bubble = Wait-For { [Win]::Title((Handle 'Buddy Bubble')) -eq 'Buddy Bubble: Editing main.py' } 10
        Check 'the bubble shows what Claude is doing' ($bubble -and (Shown 'Buddy Bubble')) ([Win]::Title((Handle 'Buddy Bubble')))
        Shot '02-working'

        Write-Session $false '' (NowMs)
        $done = Wait-For { [Win]::Title((Handle 'Buddy Bubble')) -like 'Buddy Bubble: Claude is done*' } 10
        Check 'it celebrates when Claude finishes' $done ([Win]::Title((Handle 'Buddy Bubble')))
        Shot '03-done'
    }

    # ---- Chat

    $middle = Pet-Middle
    Click $middle[0] $middle[1]
    Check 'clicking the pet opens the chat' (Wait-For { Shown 'Buddy Chat' } 8)
    Start-Sleep -Milliseconds 700
    $front = [Win]::Title([Win]::GetForegroundWindow())
    Check 'the chat takes the keyboard' ($front -eq 'Buddy Chat') "the front window is '$front'"
    Shot '04-chat'

    [System.Windows.Forms.SendKeys]::SendWait('hello buddy{ENTER}')
    if ($Live) {
        $answer = 'Hello friend! This is the test model.'
    } else {
        $answer = 'Hi from the **test**!'
        $request = Next-Request
        Check 'typing a message sends it to Claude' ($request -and $request.kind -eq 'say' -and $request.text -eq 'hello buddy') ($request | ConvertTo-Json -Compress)
        Check 'the message carries the chat so far' ($request -and ($request.PSObject.Properties.Name -contains 'history'))
        Reply $request $answer
    }
    Check 'Buddy shows the answer' (Wait-For { ChatHas 'buddy' $answer } 90)
    Start-Sleep -Milliseconds 700
    Shot '05-answer'

    [System.Windows.Forms.SendKeys]::SendWait('look at my screen{ENTER}')
    if ($Live) {
        Check 'Buddy looks at the screen through real Claude Code' (Wait-For { ChatHas 'buddy' 'I can see the test screen.' } 150)
    } else {
        $request = Next-Request
        $image = ''
        if ($request -and $request.image) { $image = [string]$request.image }
        Check 'asking Buddy to look sends a screenshot request' ($request -and $request.kind -eq 'look' -and $request.text -eq 'look at my screen')
        $saved = $image -and (Test-Path $image) -and ((Get-Item $image).Length -gt 2000) -and ((Split-Path -Parent $image) -eq (Join-Path $root 'shots')) -and ((Split-Path -Leaf $image) -eq ($request.id + '.png'))
        Check 'the screenshot is saved where the mod expects it' $saved $image
        if ($saved) { Copy-Item $image (Join-Path $Out 'what-buddy-saw.png') }
        Reply $request 'I can see your desktop.'
        Check 'Buddy shows what it saw' (Wait-For { ChatHas 'buddy' 'I can see your desktop.' } 20)
    }
    Check 'the screenshot is deleted afterwards' (Wait-For { @(Get-ChildItem -Path (Join-Path $root 'shots') -ErrorAction SilentlyContinue).Count -eq 0 } 5)
    Check 'the chat comes back after the screenshot' (Wait-For { Shown 'Buddy Chat' } 5)
    Start-Sleep -Milliseconds 700
    Shot '06-looked'

    $front = [Win]::Title([Win]::GetForegroundWindow())
    Check 'the chat still has the keyboard' ($front -eq 'Buddy Chat') "the front window is '$front'"
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Check 'Esc closes the chat' (Wait-For { -not (Shown 'Buddy Chat') } 5)

    # ---- The tab hides and shows Buddy

    $t = [Win]::Rect((Handle 'Buddy Tab'))
    $tabX = [int](($t[0] + $t[2]) / 2)
    $tabY = [int](($t[1] + $t[3]) / 2)
    Click $tabX $tabY
    Check 'clicking the tab hides Buddy' (Wait-For { -not (Shown 'Buddy Pet') } 5)
    Start-Sleep -Milliseconds 400
    Shot '07-hidden'
    $settings = Read-Json (Join-Path $root 'desktop-settings.json')
    Check 'and it stays hidden next time' ($settings -and $settings.petHidden -eq $true)
    Check 'the tab stays' (Shown 'Buddy Tab')

    Click $tabX $tabY
    Check 'clicking the tab again brings Buddy back' (Wait-For { Shown 'Buddy Pet' } 5)
    Start-Sleep -Milliseconds 600

    Click $tabX $tabY
    Check 'hidden once more' (Wait-For { -not (Shown 'Buddy Pet') } 5)
    $second = Start-Process -FilePath $exe -PassThru
    $null = $second.Handle
    Check 'starting Buddy twice leaves just one' ($second.WaitForExit(10000) -and ($second.ExitCode -eq 0))
    Check 'and /buddy brings a hidden Buddy back' (Wait-For { Shown 'Buddy Pet' } 6)
    Start-Sleep -Milliseconds 800

    # ---- Dragging

    $before = [Win]::Rect((Handle 'Buddy Pet'))
    $middle = Pet-Middle
    Move-Mouse $middle[0] $middle[1]
    Start-Sleep -Milliseconds 250
    [Win]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    for ($i = 1; $i -le 10; $i++) {
        Move-Mouse ($middle[0] - 12 * $i) ($middle[1] - 6 * $i)
        Start-Sleep -Milliseconds 50
    }
    Start-Sleep -Milliseconds 300
    Shot '08-dragging'
    [Win]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    $after = [Win]::Rect((Handle 'Buddy Pet'))
    $dx = $after[0] - $before[0]
    $dy = $after[1] - $before[1]
    Check 'dragging moves Buddy' (([Math]::Abs($dx + 120) -le 4) -and ([Math]::Abs($dy + 60) -le 4)) "it moved by $dx, $dy"
    $settings = Read-Json (Join-Path $root 'desktop-settings.json')
    Check 'and Buddy remembers the new spot' ($settings -and $settings.hasPosition -and ($settings.petX -eq $after[0]) -and ($settings.petY -eq $after[1]))
    Check 'a drag is not a click: the chat stays closed' (-not (Shown 'Buddy Chat'))

    # ---- Menu

    $windows = [Win]::Visible($script:buddy.Id)
    $middle = Pet-Middle
    Click $middle[0] $middle[1] -Right
    Check 'right-clicking opens the menu' (Wait-For { [Win]::Visible($script:buddy.Id) -gt $windows } 5)
    Start-Sleep -Milliseconds 400
    Shot '09-menu'
    Click 300 300
    Check 'clicking elsewhere closes the menu' (Wait-For { [Win]::Visible($script:buddy.Id) -le $windows } 5)

    # ---- Quit

    Write-Text (Join-Path $root 'quit') 'bye'
    Check '/buddy bye makes Buddy quit' ($script:buddy.WaitForExit(8000))
    Start-Sleep -Milliseconds 300
    Shot '10-gone'
    $log = Join-Path $root 'desktop-log.txt'
    $logText = ''
    if (Test-Path $log) { $logText = Get-Content -Raw $log }
    Check 'Buddy logged no errors' (-not $logText) $logText

    if ($Live) {
        Write-Text $releaseFile 'done'
        Check 'the Claude Code session ends cleanly' ($claude.WaitForExit(90000))
    }
} catch {
    Write-Host "FAIL  $_"
    Write-Host $_.ScriptStackTrace
    [void]$script:failures.Add("$_")
    Shot '99-failed'
} finally {
    if ($Live) { Write-Text $releaseFile 'done' }
    foreach ($process in @($script:buddy, $claude, $api)) {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
    foreach ($name in 'chat.json', 'desktop-settings.json', 'desktop-log.txt') {
        $file = Join-Path $root $name
        if (Test-Path $file) { Copy-Item -Force $file (Join-Path $Out $name) }
    }
}

if ($script:failures.Count -gt 0) {
    Write-Host ''
    Write-Host "FAILED: $($script:failures.Count) check(s)"
    if ($Live) {
        foreach ($name in 'claude.log', 'fake-api.log') {
            $file = Join-Path $Out $name
            Write-Host "---- $name"
            if (Test-Path $file) { Get-Content -Tail 60 $file | Out-Host } else { Write-Host '(none)' }
        }
    }
    exit 1
}
Write-Host ''
Write-Host 'ALL PASSED'
exit 0
