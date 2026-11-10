// Buddy for Windows: the windows. The pet, its tab and its status bubble are small
// see-through windows that float above everything and never take the keyboard; the chat
// is an ordinary dark window you can type in.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace Buddy
{
    static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X;
            public int Y;
            public POINT(int x, int y) { X = x; Y = y; }
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct SIZE
        {
            public int Width;
            public int Height;
            public SIZE(int width, int height) { Width = width; Height = height; }
        }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct BLENDFUNCTION
        {
            public byte BlendOp;
            public byte BlendFlags;
            public byte SourceConstantAlpha;
            public byte AlphaFormat;
        }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UpdateLayeredWindow(IntPtr window, IntPtr screenDc, ref POINT position, ref SIZE size,
            IntPtr sourceDc, ref POINT source, int colorKey, ref BLENDFUNCTION blend, int flags);

        [DllImport("user32.dll")]
        public static extern IntPtr GetDC(IntPtr window);

        [DllImport("user32.dll")]
        public static extern int ReleaseDC(IntPtr window, IntPtr dc);

        [DllImport("gdi32.dll")]
        public static extern IntPtr CreateCompatibleDC(IntPtr dc);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteDC(IntPtr dc);

        [DllImport("gdi32.dll")]
        public static extern IntPtr SelectObject(IntPtr dc, IntPtr item);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteObject(IntPtr item);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, string lParam);

        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        public static extern int SetWindowTheme(IntPtr window, string app, string idList);

        // Keeps a window above the others without giving it the keyboard.
        public static void KeepOnTop(Form form)
        {
            if (form.IsHandleCreated && form.Visible)
            {
                SetWindowPos(form.Handle, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
            }
        }
    }

    // A window drawn from a picture with see-through parts. Clicks on the see-through
    // parts go to whatever is behind it, and clicking it never takes the keyboard away
    // from the app you are working in.
    class LayeredForm : Form
    {
        public Size PixelSize;
        public byte Alpha = 255;

        public LayeredForm(string title, Size size)
        {
            Text = title;
            PixelSize = size;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            ControlBox = false;
            MinimizeBox = false;
            MaximizeBox = false;
            Size = size;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                // layered | tool window (no taskbar button) | never activated | always on top
                cp.ExStyle |= 0x00080000 | 0x00000080 | 0x08000000 | 0x00000008;
                return cp;
            }
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0021) // WM_MOUSEACTIVATE
            {
                m.Result = (IntPtr)3; // MA_NOACTIVATE
                return;
            }
            base.WndProc(ref m);
        }

        protected override void OnPaintBackground(PaintEventArgs e) { }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            if (Visible) Native.KeepOnTop(this);
        }

        public void SetImage(Bitmap bitmap)
        {
            if (IsDisposed) return;
            IntPtr window = Handle;
            IntPtr screen = Native.GetDC(IntPtr.Zero);
            IntPtr memory = Native.CreateCompatibleDC(screen);
            IntPtr image = IntPtr.Zero;
            IntPtr before = IntPtr.Zero;
            try
            {
                image = bitmap.GetHbitmap(Color.FromArgb(0));
                before = Native.SelectObject(memory, image);
                Native.SIZE size = new Native.SIZE(bitmap.Width, bitmap.Height);
                Native.POINT source = new Native.POINT(0, 0);
                Native.POINT position = new Native.POINT(Left, Top);
                Native.BLENDFUNCTION blend = new Native.BLENDFUNCTION();
                blend.BlendOp = 0;             // AC_SRC_OVER
                blend.SourceConstantAlpha = Alpha;
                blend.AlphaFormat = 1;         // AC_SRC_ALPHA
                Native.UpdateLayeredWindow(window, screen, ref position, ref size, memory, ref source, 0, ref blend, 2);
            }
            finally
            {
                Native.ReleaseDC(IntPtr.Zero, screen);
                if (image != IntPtr.Zero)
                {
                    Native.SelectObject(memory, before);
                    Native.DeleteObject(image);
                }
                Native.DeleteDC(memory);
            }
        }
    }

    class PetForm : LayeredForm
    {
        public Action Clicked;
        public Action Moved;
        public Action Dropped;
        public Action MenuRequested;

        readonly BuddyModel model;
        readonly float u;
        readonly Random random = new Random();
        Point dragStart;
        Point windowStart;
        bool isDown;
        bool didDrag;
        double nextBlink = 3;
        double blinkUntil;

        public PetForm(BuddyModel model, float u) : base("Buddy Pet", PetRenderer.PixelSize(u))
        {
            this.model = model;
            this.u = u;
        }

        public void Render(double t)
        {
            if (t > nextBlink)
            {
                blinkUntil = t + 0.13;
                nextBlink = t + 2.5 + random.NextDouble() * 3;
            }
            using (Bitmap bitmap = new Bitmap(PixelSize.Width, PixelSize.Height, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bitmap))
                {
                    PetRenderer.Draw(new Canvas(g, u), model.Mood, t, Gaze(), t < blinkUntil, true);
                }
                SetImage(bitmap);
            }
        }

        // The eyes follow your pointer a little.
        PointF Gaze()
        {
            Point mouse = Cursor.Position;
            float dx = mouse.X - (Left + PixelSize.Width / 2f);
            float dy = mouse.Y - (Top + PixelSize.Height / 2f);
            float length = Math.Max(1, (float)Math.Sqrt(dx * dx + dy * dy));
            float strength = Math.Min(1, length / (200 * u));
            return new PointF(dx / length * 2 * strength, dy / length * 2 * strength);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            isDown = true;
            didDrag = false;
            dragStart = Cursor.Position;
            windowStart = Location;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (!isDown) return;
            Point now = Cursor.Position;
            int dx = now.X - dragStart.X;
            int dy = now.Y - dragStart.Y;
            if (!didDrag && dx * dx + dy * dy < 9 * u * u) return;
            if (!didDrag)
            {
                didDrag = true;
                model.IsDragging = true;
            }
            Location = new Point(windowStart.X + dx, windowStart.Y + dy);
            if (Moved != null) Moved();
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Right)
            {
                if (MenuRequested != null) MenuRequested();
                return;
            }
            if (e.Button != MouseButtons.Left || !isDown) return;
            isDown = false;
            if (didDrag)
            {
                model.IsDragging = false;
                if (Moved != null) Moved();
                if (Dropped != null) Dropped();
            }
            else if (Clicked != null)
            {
                Clicked();
            }
        }
    }

    class TabForm : LayeredForm
    {
        public Action Clicked;
        public Action MenuRequested;
        public bool OnRight = true;
        public bool PetHidden;
        public bool Hovered;
        public Color Status = Tint.Hex(0x9A9A9A, 0.65);

        readonly float u;

        public TabForm(float u) : base("Buddy Tab", TabRenderer.PixelSize(u))
        {
            this.u = u;
        }

        public void Render()
        {
            using (Bitmap bitmap = new Bitmap(PixelSize.Width, PixelSize.Height, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bitmap))
                {
                    TabRenderer.Draw(new Canvas(g, u), OnRight, PetHidden, Hovered, Status);
                }
                SetImage(bitmap);
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Right)
            {
                if (MenuRequested != null) MenuRequested();
            }
            else if (e.Button == MouseButtons.Left && Clicked != null)
            {
                Clicked();
            }
        }
    }

    class BubbleForm : LayeredForm
    {
        public const string Title = "Buddy Bubble";
        public Action Clicked;
        public string Line = "";

        readonly float u;

        public BubbleForm(float u) : base(Title, new Size(10, 10))
        {
            this.u = u;
        }

        public void SetLine(string line)
        {
            Line = line;
            Text = Title + ": " + line;
            PixelSize = BubbleRenderer.Measure(line, u);
            Size = PixelSize;
        }

        public void Render()
        {
            using (Bitmap bitmap = new Bitmap(PixelSize.Width, PixelSize.Height, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bitmap))
                {
                    BubbleRenderer.Draw(new Canvas(g, u), Line, PixelSize);
                }
                SetImage(bitmap);
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && Clicked != null) Clicked();
        }
    }

    // A small picture button: the chat's close, look and send buttons.
    class GlyphButton : Control
    {
        public string Glyph = "";
        public float U = 1;
        bool hovered;

        static readonly Color Orange = Tint.Hex(0xD97757);

        public GlyphButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            Cursor = Cursors.Hand;
        }

        protected override void OnMouseEnter(EventArgs e)
        {
            hovered = true;
            Invalidate();
            base.OnMouseEnter(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            hovered = false;
            Invalidate();
            base.OnMouseLeave(e);
        }

        protected override void OnEnabledChanged(EventArgs e)
        {
            Invalidate();
            base.OnEnabledChanged(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            float cx = Width / 2f;
            float cy = Height / 2f;
            Color line = !Enabled ? Tint.Hex(0x6A6A6E) : (hovered ? Tint.Hex(0xFFFFFF) : Tint.Hex(0xA4A4A8));
            if (Glyph == "close")
            {
                float r = 4.2f * U;
                using (Pen pen = RoundPen(line, 1.7f * U))
                {
                    g.DrawLine(pen, cx - r, cy - r, cx + r, cy + r);
                    g.DrawLine(pen, cx - r, cy + r, cx + r, cy - r);
                }
            }
            else if (Glyph == "look")
            {
                float w = 7.5f * U;
                float h = 6.2f * U;
                using (Pen pen = RoundPen(line, 1.5f * U))
                {
                    g.DrawBezier(pen, cx - w, cy, cx - w * 0.45f, cy - h, cx + w * 0.45f, cy - h, cx + w, cy);
                    g.DrawBezier(pen, cx - w, cy, cx - w * 0.45f, cy + h, cx + w * 0.45f, cy + h, cx + w, cy);
                }
                using (SolidBrush brush = new SolidBrush(line))
                {
                    g.FillEllipse(brush, cx - 2.3f * U, cy - 2.3f * U, 4.6f * U, 4.6f * U);
                }
            }
            else if (Glyph == "send")
            {
                float r = 10 * U;
                Color fill = Enabled ? (hovered ? Tint.Hex(0xE8977A) : Orange) : Tint.Hex(0x5A4A45);
                using (SolidBrush brush = new SolidBrush(fill)) g.FillEllipse(brush, cx - r, cy - r, 2 * r, 2 * r);
                using (Pen pen = RoundPen(Enabled ? Color.White : Tint.Hex(0x9A9A9E), 2 * U))
                {
                    g.DrawLine(pen, cx, cy + 4.5f * U, cx, cy - 4.5f * U);
                    g.DrawLines(pen, new PointF[]
                    {
                        new PointF(cx - 4 * U, cy - 0.5f * U), new PointF(cx, cy - 4.5f * U), new PointF(cx + 4 * U, cy - 0.5f * U),
                    });
                }
            }
        }

        static Pen RoundPen(Color color, float width)
        {
            Pen pen = new Pen(color, width);
            pen.StartCap = LineCap.Round;
            pen.EndCap = LineCap.Round;
            pen.LineJoin = LineJoin.Round;
            return pen;
        }
    }

    class ChatForm : Form
    {
        public Action CloseRequested;
        public Action LookRequested;

        static readonly Color Back = Tint.Hex(0x1E1E20);
        static readonly Color Field = Tint.Hex(0x2C2C2F);
        static readonly Color Ink = Tint.Hex(0xECECEC);
        static readonly Color Dim = Tint.Hex(0x9A9A9E);
        static readonly Color Mine = Tint.Hex(0xF0A58A);
        static readonly Color Orange = Tint.Hex(0xD97757);
        static readonly Color Green = Tint.Hex(0x4CC38A);
        static readonly Color Grey = Tint.Hex(0x808084);

        // **bold**, `code` or *italic*
        static readonly Regex Marks = new Regex(@"\*\*(.+?)\*\*|`([^`\n]+)`|\*(?!\s)([^*\n]+?)(?<!\s)\*");

        readonly BuddyModel model;
        readonly float u;
        readonly RichTextBox box = new RichTextBox();
        readonly TextBox input = new TextBox();
        readonly Label title = new Label();
        readonly Label status = new Label();
        readonly Label typing = new Label();
        readonly GlyphButton close = new GlyphButton();
        readonly GlyphButton look = new GlyphButton();
        readonly GlyphButton send = new GlyphButton();
        readonly Font regular;
        readonly Font bold;
        readonly Font italic;
        readonly Font code;
        readonly Font gap;
        Color dot = Grey;
        int shownVersion = -1;
        string shownTyping = "";

        public ChatForm(BuddyModel model, float u)
        {
            this.model = model;
            this.u = u;
            regular = new Font("Segoe UI", 12.5f * u, FontStyle.Regular, GraphicsUnit.Pixel);
            bold = new Font("Segoe UI", 12.5f * u, FontStyle.Bold, GraphicsUnit.Pixel);
            italic = new Font("Segoe UI", 12.5f * u, FontStyle.Italic, GraphicsUnit.Pixel);
            code = new Font("Consolas", 12f * u, FontStyle.Regular, GraphicsUnit.Pixel);
            gap = new Font("Segoe UI", 5f * u, FontStyle.Regular, GraphicsUnit.Pixel);

            Text = "Buddy Chat";
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            TopMost = true;
            DoubleBuffered = true;
            BackColor = Back;
            ForeColor = Ink;
            ClientSize = new Size(S(320), S(400));

            title.Text = "Buddy";
            title.Font = new Font("Segoe UI", 13f * u, FontStyle.Bold, GraphicsUnit.Pixel);
            title.ForeColor = Ink;
            title.BackColor = Back;
            title.AutoSize = false;
            title.Bounds = new Rectangle(S(28), S(5), S(220), S(19));

            status.Font = new Font("Segoe UI", 11f * u, FontStyle.Regular, GraphicsUnit.Pixel);
            status.ForeColor = Dim;
            status.BackColor = Back;
            status.AutoSize = false;
            status.AutoEllipsis = true;
            status.Bounds = new Rectangle(S(28), S(23), S(248), S(17));

            close.Glyph = "close";
            close.U = u;
            close.BackColor = Back;
            close.Bounds = new Rectangle(S(320 - 12 - 22), S(11), S(22), S(22));
            close.Click += delegate { if (CloseRequested != null) CloseRequested(); };

            box.ReadOnly = true;
            box.BorderStyle = BorderStyle.None;
            box.BackColor = Back;
            box.ForeColor = Ink;
            box.Font = regular;
            box.ScrollBars = RichTextBoxScrollBars.Vertical;
            box.DetectUrls = false;
            box.TabStop = false;
            box.Bounds = new Rectangle(S(12), S(52), S(320 - 12 - 3), S(270));
            box.HandleCreated += delegate
            {
                try { Native.SetWindowTheme(box.Handle, "DarkMode_Explorer", null); } catch (Exception) { }
            };

            typing.Font = new Font("Segoe UI", 12f * u, FontStyle.Regular, GraphicsUnit.Pixel);
            typing.ForeColor = Dim;
            typing.BackColor = Back;
            typing.AutoSize = false;
            typing.Bounds = new Rectangle(S(14), S(326), S(290), S(18));
            typing.Visible = false;

            input.BorderStyle = BorderStyle.None;
            input.BackColor = Field;
            input.ForeColor = Ink;
            input.Font = new Font("Segoe UI", 13f * u, FontStyle.Regular, GraphicsUnit.Pixel);
            input.Width = S(300 - 12 - 66);
            input.Location = new Point(S(22), S(352) + (S(38) - input.Height) / 2);
            input.KeyDown += delegate(object sender, KeyEventArgs e)
            {
                if (e.KeyCode != Keys.Enter) return;
                e.SuppressKeyPress = true;
                SendDraft();
            };
            input.TextChanged += delegate { RefreshButtons(); };
            input.HandleCreated += delegate
            {
                try { Native.SendMessage(input.Handle, 0x1501, (IntPtr)1, "Talk to Buddy\u2026"); } catch (Exception) { }
            };

            look.Glyph = "look";
            look.U = u;
            look.BackColor = Field;
            look.Bounds = new Rectangle(S(310 - 8 - 24 - 6 - 24), S(352 + 7), S(24), S(24));
            look.Click += delegate { if (LookRequested != null) LookRequested(); };

            send.Glyph = "send";
            send.U = u;
            send.BackColor = Field;
            send.Bounds = new Rectangle(S(310 - 8 - 24), S(352 + 7), S(24), S(24));
            send.Click += delegate { SendDraft(); };

            Controls.Add(title);
            Controls.Add(status);
            Controls.Add(close);
            Controls.Add(box);
            Controls.Add(typing);
            Controls.Add(input);
            Controls.Add(look);
            Controls.Add(send);
            RefreshState();
        }

        int S(float points)
        {
            return (int)Math.Round(points * u);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000080; // tool window: no taskbar button
                cp.ClassStyle |= 0x00020000; // drop shadow
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try
            {
                int round = 2; // rounded corners, on Windows 11
                Native.DwmSetWindowAttribute(Handle, 33, ref round, 4);
            }
            catch (Exception) { }
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Escape)
            {
                if (CloseRequested != null) CloseRequested();
                return true;
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            using (Pen pen = new Pen(Tint.Hex(0x353538))) g.DrawLine(pen, 0, S(44), ClientSize.Width, S(44));
            using (Pen pen = new Pen(Tint.Hex(0x3C3C40))) g.DrawRectangle(pen, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            using (SolidBrush brush = new SolidBrush(dot)) g.FillEllipse(brush, S(13), S(18), S(8), S(8));
            using (GraphicsPath path = Canvas.RoundPath(new RectangleF(S(10), S(352), S(300), S(38)), S(10)))
            using (SolidBrush brush = new SolidBrush(Field))
            {
                g.FillPath(brush, path);
            }
        }

        public void FocusInput()
        {
            input.Focus();
        }

        void SendDraft()
        {
            if (model.Send(input.Text)) input.Text = "";
            RefreshState();
        }

        void RefreshButtons()
        {
            bool waiting = model.IsWaiting;
            look.Enabled = !waiting;
            send.Enabled = !waiting && input.Text.Trim().Length > 0;
        }

        // Called a few times a second while the chat is open.
        public void RefreshState()
        {
            string line;
            Color color;
            if (!model.IsConnected)
            {
                line = "Asleep: no Claude session with Buddy is open";
                color = Grey;
            }
            else if (model.IsBusy)
            {
                line = model.Activity.Length == 0 ? "Claude is working\u2026" : model.Activity;
                color = Orange;
            }
            else
            {
                line = "Claude is idle";
                color = Green;
            }
            line = line.Replace("\r", " ").Replace("\n", " ").Replace("&", "&&");
            if (status.Text != line) status.Text = line;
            if (dot != color)
            {
                dot = color;
                Invalidate(new Rectangle(0, 0, S(28), S(44)));
            }

            string wait = "";
            if (model.IsWaiting)
            {
                int dots = (int)(DateTime.UtcNow.Ticks / 4000000 % 4);
                wait = "Buddy is " + (model.IsLooking ? "looking at your screen" : "thinking") + new string('.', dots);
            }
            if (wait != shownTyping)
            {
                shownTyping = wait;
                typing.Text = wait;
                typing.Visible = wait.Length > 0;
            }
            RefreshButtons();
            if (shownVersion != model.ChatVersion && IsHandleCreated) ShowChat();
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            if (Visible)
            {
                shownVersion = -1;
                RefreshState();
            }
        }

        void ShowChat()
        {
            shownVersion = model.ChatVersion;
            box.Clear();
            if (model.Chat.Count == 0)
            {
                Paragraph(false);
                Append("Hi! I'm Buddy. Ask me anything, or press the eye and I'll look at your screen.", Dim, regular);
            }
            foreach (ChatLine line in model.Chat)
            {
                bool mine = line.Who == "me";
                Paragraph(mine);
                Color color = mine ? Mine : Ink;
                int at = 0;
                foreach (Match match in Marks.Matches(line.Text))
                {
                    if (match.Index > at) Append(line.Text.Substring(at, match.Index - at), color, regular);
                    if (match.Groups[1].Success) Append(match.Groups[1].Value, color, bold);
                    else if (match.Groups[2].Success) Append(match.Groups[2].Value, color, code);
                    else Append(match.Groups[3].Value, color, italic);
                    at = match.Index + match.Length;
                }
                if (at < line.Text.Length) Append(line.Text.Substring(at), color, regular);
                Append("\n", color, regular);
                Append("\n", color, gap);
            }
            box.SelectionStart = box.TextLength;
            box.SelectionLength = 0;
            box.ScrollToCaret();
        }

        void Paragraph(bool mine)
        {
            box.SelectionStart = box.TextLength;
            box.SelectionLength = 0;
            box.SelectionAlignment = mine ? HorizontalAlignment.Right : HorizontalAlignment.Left;
            box.SelectionIndent = mine ? S(36) : 0;
            box.SelectionRightIndent = mine ? S(4) : S(36);
        }

        void Append(string text, Color color, Font font)
        {
            box.SelectionStart = box.TextLength;
            box.SelectionLength = 0;
            box.SelectionColor = color;
            box.SelectionFont = font;
            box.AppendText(text);
        }
    }
}
