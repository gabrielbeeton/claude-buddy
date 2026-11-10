// Buddy for Windows: drawing the pet.
//
// The orange creature from Claude Code's welcome screen as pixel art: a block body with
// two eyes, little arms and four legs. Everything here uses the Mac app's measurements
// (an 18 x 10 grid of 7-point squares in a 150 x 118 point picture, y growing down), and
// Canvas turns points into whole pixels so the squares stay crisp at any display scale.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;

namespace Buddy
{
    static class Tint
    {
        public static Color Hex(int rgb, double alpha)
        {
            int a = (int)Math.Round(Math.Max(0, Math.Min(1, alpha)) * 255);
            return Color.FromArgb(a, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
        }

        public static Color Hex(int rgb)
        {
            return Hex(rgb, 1);
        }
    }

    class Canvas
    {
        public readonly Graphics G;
        public readonly float U;  // pixels per point
        public readonly float Dx; // where the picture's corner sits, in pixels
        public readonly float Dy;
        public int Outline;       // the dark edge around the pet, in pixels

        public Canvas(Graphics g, float u) : this(g, u, 0, 0) { }

        public Canvas(Graphics g, float u, float dx, float dy)
        {
            G = g;
            U = u;
            Dx = dx;
            Dy = dy;
            Outline = Math.Max(1, Round(1.5f * u));
            g.PixelOffsetMode = PixelOffsetMode.Half;
        }

        public static int Round(float value)
        {
            return (int)Math.Floor(value + 0.5f);
        }

        // How many pixels one point is, so that a 7-point square is a whole number of pixels.
        public static float UnitFor(float dpi)
        {
            return Math.Max(1, Round(7f * dpi / 96f)) / 7f;
        }

        public float X(float x) { return Dx + x * U; }
        public float Y(float y) { return Dy + y * U; }

        public Rectangle Snap(RectangleF points)
        {
            int left = Round(X(points.Left));
            int top = Round(Y(points.Top));
            int right = Round(X(points.Right));
            int bottom = Round(Y(points.Bottom));
            if (right <= left) right = left + 1;
            if (bottom <= top) bottom = top + 1;
            return Rectangle.FromLTRB(left, top, right, bottom);
        }

        public void Fill(Color color, Rectangle pixels)
        {
            G.SmoothingMode = SmoothingMode.None;
            using (SolidBrush brush = new SolidBrush(color)) G.FillRectangle(brush, pixels);
        }

        public void Fill(Color color, RectangleF points)
        {
            Fill(color, Snap(points));
        }

        RectangleF Scaled(RectangleF points)
        {
            return new RectangleF(X(points.X), Y(points.Y), points.Width * U, points.Height * U);
        }

        public void FillEllipse(Color color, RectangleF points)
        {
            G.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush brush = new SolidBrush(color)) G.FillEllipse(brush, Scaled(points));
        }

        public void FillRound(Color color, RectangleF points, float radius)
        {
            G.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = RoundPath(Scaled(points), radius * U))
            using (SolidBrush brush = new SolidBrush(color))
            {
                G.FillPath(brush, path);
            }
        }

        public void StrokeRound(Color color, RectangleF points, float radius, float width)
        {
            G.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = RoundPath(Scaled(points), radius * U))
            using (Pen pen = new Pen(color, Math.Max(1f, width * U)))
            {
                G.DrawPath(pen, path);
            }
        }

        public void Lines(Color color, float width, bool round, params PointF[] points)
        {
            PointF[] scaled = new PointF[points.Length];
            for (int i = 0; i < points.Length; i++) scaled[i] = new PointF(X(points[i].X), Y(points[i].Y));
            G.SmoothingMode = SmoothingMode.AntiAlias;
            using (Pen pen = new Pen(color, width * U))
            {
                pen.StartCap = round ? LineCap.Round : LineCap.Square;
                pen.EndCap = pen.StartCap;
                pen.LineJoin = round ? LineJoin.Round : LineJoin.Miter;
                G.DrawLines(pen, scaled);
            }
        }

        // A rounded rectangle, in pixels.
        public static GraphicsPath RoundPath(RectangleF r, float radius)
        {
            GraphicsPath path = new GraphicsPath();
            float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            if (d < 0.5f)
            {
                path.AddRectangle(r);
                return path;
            }
            path.AddArc(r.Left, r.Top, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    static class PetRenderer
    {
        public const float Width = 150;
        public const float Height = 118;
        const float S = 7;
        const float X0 = 12;
        const float Ground = 92;

        static readonly Color Orange = Tint.Hex(0xD97757);
        static readonly Color Light = Tint.Hex(0xE8977A);
        static readonly Color Shade = Tint.Hex(0xB65A3E);
        static readonly Color Edge = Tint.Hex(0x2A1712, 0.92);
        static readonly Color Eye = Tint.Hex(0x1E1410);

        public static Size PixelSize(float u)
        {
            return new Size((int)Math.Ceiling(Width * u), (int)Math.Ceiling(Height * u));
        }

        // 0 -> 1 -> 0 over one period
        public static float Wave(double t, double period)
        {
            return (float)(0.5 - 0.5 * Math.Cos(2 * Math.PI * t / period));
        }

        static float Sin(double value)
        {
            return (float)Math.Sin(value);
        }

        static RectangleF Cell(float top, float col, float row, float w, float h)
        {
            return new RectangleF(X0 + col * S, top + row * S, w * S, h * S);
        }

        static RectangleF Moved(RectangleF r, float dy)
        {
            return new RectangleF(r.X, r.Y + dy, r.Width, r.Height);
        }

        // The light under the pet, and the dot on the tab: what Claude is up to.
        public static void StatusLight(Mood mood, out int rgb, out bool pulses)
        {
            switch (mood)
            {
                case Mood.Working: rgb = 0xD97757; pulses = true; break;
                case Mood.Happy: rgb = 0x4CC38A; pulses = false; break;
                case Mood.Thinking:
                case Mood.Looking: rgb = 0x8AB4F8; pulses = true; break;
                case Mood.Sleeping: rgb = 0x777777; pulses = false; break;
                default: rgb = 0x9A9A9A; pulses = false; break;
            }
        }

        public static void Draw(Canvas c, Mood mood, double t, PointF gaze, bool blink, bool showGround)
        {
            float dy;
            switch (mood)
            {
                case Mood.Idle: dy = -2f * Wave(t, 2.6); break;
                case Mood.Working: dy = -3f * Wave(t, 0.5); break;
                case Mood.Thinking: dy = -2f * Wave(t, 1.8); break;
                case Mood.Looking: dy = -1.5f * Wave(t, 1.6); break;
                case Mood.Happy: dy = -14f * Math.Abs(Sin(Math.PI * t / 0.6)); break;
                case Mood.Sleeping: dy = -1f * Wave(t, 4); break;
                default: dy = 0; break;
            }
            dy = Canvas.Round(dy * c.U) / c.U; // move by whole pixels
            float top = Ground - 10 * S + dy;
            float feetLift = mood == Mood.Happy ? dy : 0;

            // Arms
            RectangleF armL = Cell(top, 1, 4, 2, 2);
            RectangleF armR = Cell(top, 15, 4, 2, 2);
            if (mood == Mood.Happy)
            {
                bool up = Math.Sin(2 * Math.PI * t / 0.6) > 0;
                armL = Cell(top, 1, up ? 2 : 4, 2, 2);
                armR = Cell(top, 15, up ? 4 : 2, 2, 2);
            }
            else if (mood == Mood.Dragged)
            {
                armL = Cell(top, 1, 2, 2, 2);
                armR = Cell(top, 15, 2, 2, 2);
            }
            else if (mood == Mood.Working)
            {
                float pump = Math.Sin(2 * Math.PI * t / 0.32) > 0 ? -1 : 1;
                armL = Moved(armL, pump);
                armR = Moved(armR, -pump);
            }

            // Legs: planted on the ground while the body bobs, so they stretch a little
            RectangleF body = Cell(top, 3, 0, 12, 8);
            float bodyBottom = body.Bottom;
            float[] columns = new float[] { 4, 6, 11, 13 };
            RectangleF[] legs = new RectangleF[4];
            for (int i = 0; i < 4; i++)
            {
                float bottom = Ground + feetLift;
                float dx = 0;
                if (mood == Mood.Working)
                {
                    float step = Sin(2 * Math.PI * t / 0.32 + (i % 2 == 0 ? 0 : Math.PI));
                    bottom -= Math.Max(0, step) * 5;
                }
                else if (mood == Mood.Dragged)
                {
                    bottom = bodyBottom + 2.6f * S;
                    dx = Sin(2 * Math.PI * t / 0.7 + i) * 1.5f;
                }
                legs[i] = new RectangleF(X0 + columns[i] * S + dx, bodyBottom - 1, S, Math.Max(3, bottom - bodyBottom + 1));
            }

            // Shadow on the ground
            if (showGround)
            {
                float lift = Math.Min(1, -dy / 20);
                float width = 76 * (1 - 0.35f * lift);
                c.FillEllipse(Tint.Hex(0x000000, 0.22 * (1 - 0.4 * lift)), new RectangleF(75 - width / 2, Ground - 2, width, 6));
            }

            // Outline first, then the orange on top, so the parts join without seams
            List<RectangleF> parts = new List<RectangleF>();
            parts.Add(body);
            parts.Add(armL);
            parts.Add(armR);
            parts.AddRange(legs);
            if (c.Outline > 0)
            {
                foreach (RectangleF part in parts) c.Fill(Edge, Rectangle.Inflate(c.Snap(part), c.Outline, c.Outline));
            }
            foreach (RectangleF part in parts) c.Fill(Orange, part);
            c.Fill(Light, new RectangleF(body.Left + S, body.Top, body.Width - 2 * S, S / 2));
            c.Fill(Shade, new RectangleF(body.Left, body.Bottom - S / 2, body.Width, S / 2));
            for (int i = 3; i < parts.Count; i++) Shadow(c, parts[i]);
            Shadow(c, armL);
            Shadow(c, armR);

            DrawEyes(c, mood, t, gaze, blink, top);
            DrawExtras(c, mood, t, top);

            // Status light under the pet
            if (showGround)
            {
                int rgb;
                bool pulses;
                StatusLight(mood, out rgb, out pulses);
                if (mood == Mood.Idle || mood == Mood.Dragged) rgb = 0x9A9A9A;
                double alpha = pulses ? 0.55 + 0.45 * Wave(t, 1.0) : (mood == Mood.Sleeping ? 0.35 : 0.6);
                c.FillRound(Tint.Hex(rgb, alpha), new RectangleF(60, Ground + 12, 30, 5), 2.5f);
            }
        }

        static void Shadow(Canvas c, RectangleF part)
        {
            c.Fill(Shade, new RectangleF(part.Left, part.Bottom - 2.5f, part.Width, 2.5f));
        }

        static void DrawEyes(Canvas c, Mood mood, double t, PointF gaze, bool blink, float top)
        {
            PointF look = gaze;
            if (mood == Mood.Thinking) look = new PointF(1.5f, -3);
            else if (mood == Mood.Looking) look = new PointF(2.5f * Sin(2 * Math.PI * t / 1.6), 0);
            else if (mood == Mood.Sleeping || mood == Mood.Happy || mood == Mood.Dragged) look = new PointF(0, 0);
            look = new PointF(Canvas.Round(look.X * c.U) / c.U, Canvas.Round(look.Y * c.U) / c.U);

            foreach (float col in new float[] { 5, 12 })
            {
                float x = X0 + col * S + look.X;
                float y = top + 2 * S + look.Y;
                if (mood == Mood.Sleeping)
                {
                    c.Fill(Eye, new RectangleF(x - 1, y + 2 * S - 5, S + 2, 2.5f));
                }
                else if (mood == Mood.Happy)
                {
                    c.Lines(Eye, 2.6f, false,
                        new PointF(x - 0.5f, y + 11), new PointF(x + S / 2, y + 4), new PointF(x + S + 0.5f, y + 11));
                }
                else if (mood == Mood.Dragged)
                {
                    if (col < 10)
                    {
                        c.Lines(Eye, 2.6f, false, new PointF(x, y + 2), new PointF(x + S, y + 7), new PointF(x, y + 12));
                    }
                    else
                    {
                        c.Lines(Eye, 2.6f, false, new PointF(x + S, y + 2), new PointF(x, y + 7), new PointF(x + S, y + 12));
                    }
                }
                else if (blink)
                {
                    c.Fill(Eye, new RectangleF(x, y + 2 * S - 4, S, 2.5f));
                }
                else
                {
                    float tall = mood == Mood.Looking ? 2.3f * S : 2 * S;
                    c.Fill(Eye, new RectangleF(x, y + 2 * S - tall, S, tall));
                    c.Fill(Tint.Hex(0xFFFFFF, 0.85), new RectangleF(x + 1, y + 2 * S - tall + 1.5f, 2.5f, 3));
                }
            }
        }

        static readonly string[] ZGlyph = new string[] { "####", "..#.", ".#..", "####" };
        static readonly string[] Sparkle = new string[] { ".#.", "###", ".#." };

        static void Pixels(Canvas c, string[] pattern, float x, float y, float size, Color color)
        {
            for (int row = 0; row < pattern.Length; row++)
            {
                for (int col = 0; col < pattern[row].Length; col++)
                {
                    if (pattern[row][col] != '#') continue;
                    c.Fill(color, new RectangleF(x + col * size, y + row * size, size, size));
                }
            }
        }

        static void DrawExtras(Canvas c, Mood mood, double t, float top)
        {
            if (mood == Mood.Sleeping)
            {
                for (int i = 0; i < 2; i++)
                {
                    double whole = t / 3.2 + i / 2.0;
                    float phase = (float)(whole - Math.Floor(whole));
                    Pixels(c, ZGlyph, X0 + 15 * S + 2 + phase * 14, top + 4 - phase * 24, 1.5f + phase * 1.2f,
                        Tint.Hex(0xF0E6DF, 0.9 * Math.Sin(Math.PI * phase)));
                }
            }
            else if (mood == Mood.Thinking)
            {
                for (int i = 0; i < 3; i++)
                {
                    double alpha = 0.35 + 0.65 * Wave(t + i * 0.2, 1.1);
                    c.Fill(Tint.Hex(0xF0E6DF, alpha), new RectangleF(X0 + 15 * S + i * 7, top - 8, 4, 4));
                }
            }
            else if (mood == Mood.Happy)
            {
                float[][] spots = new float[][]
                {
                    new float[] { 4, 18, 0 }, new float[] { 134, 12, 0.35f },
                    new float[] { 139, 46, 0.7f }, new float[] { 2, 50, 0.5f },
                };
                foreach (float[] spot in spots)
                {
                    Pixels(c, Sparkle, spot[0], spot[1], 2.5f, Tint.Hex(0xFFD9A8, Wave(t + spot[2], 0.9)));
                }
            }
        }
    }

    // The little tab on the screen edge that tucks Buddy away and brings Buddy back.
    static class TabRenderer
    {
        public const float Width = 20;
        public const float Height = 46;

        public static Size PixelSize(float u)
        {
            return new Size((int)Math.Ceiling(Width * u), (int)Math.Ceiling(Height * u));
        }

        public static void Draw(Canvas c, bool onRight, bool petHidden, bool hovered, Color status)
        {
            float width = hovered ? 20 : 14;
            // A rounded tab that runs past the screen edge, so it looks flush with it.
            RectangleF shape = onRight
                ? new RectangleF(Width - width + 0.5f, 0.5f, width + 9, Height - 1)
                : new RectangleF(-9.5f, 0.5f, width + 9, Height - 1);
            c.FillRound(Tint.Hex(0x1C1C1E, hovered ? 0.97 : 0.88), shape, 7);
            c.StrokeRound(Tint.Hex(0xFFFFFF, 0.16), shape, 7, 1);

            // Chevron: points out of the edge when Buddy is hidden, into it when shown.
            float cx = onRight ? Width - width / 2 : width / 2;
            bool pointsLeft = onRight == petHidden;
            float dx = pointsLeft ? -2.5f : 2.5f;
            c.Lines(Tint.Hex(0xFFFFFF, hovered ? 0.95 : 0.7), 2, true,
                new PointF(cx - dx, 13), new PointF(cx + dx, 18.5f), new PointF(cx - dx, 24));

            // Status dot
            c.FillEllipse(status, new RectangleF(cx - 2.5f, 31, 5, 5));
        }
    }

    // The pill above Buddy that says what Claude is doing.
    static class BubbleRenderer
    {
        const float Height = 40;

        static Font MakeFont(float u)
        {
            return new Font("Segoe UI", 12f * u, FontStyle.Regular, GraphicsUnit.Pixel);
        }

        static StringFormat MakeFormat()
        {
            StringFormat format = new StringFormat();
            format.FormatFlags = StringFormatFlags.NoWrap;
            format.Trimming = StringTrimming.EllipsisCharacter;
            format.Alignment = StringAlignment.Center;
            format.LineAlignment = StringAlignment.Center;
            return format;
        }

        public static Size Measure(string text, float u)
        {
            using (Bitmap scratch = new Bitmap(1, 1))
            using (Graphics g = Graphics.FromImage(scratch))
            using (Font font = MakeFont(u))
            using (StringFormat format = MakeFormat())
            {
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                float width = g.MeasureString(text, font, 10000, format).Width / u + 30;
                return new Size((int)Math.Ceiling(Math.Min(width, 320) * u), (int)Math.Ceiling(Height * u));
            }
        }

        public static void Draw(Canvas c, string text, Size pixels)
        {
            float width = pixels.Width / c.U;
            RectangleF pill = new RectangleF(5, 5, width - 10, Height - 10);
            c.FillRound(Tint.Hex(0x1A1A1A, 0.94), pill, 15);
            c.StrokeRound(Tint.Hex(0xFFFFFF, 0.14), pill, 15, 1);
            using (Font font = MakeFont(c.U))
            using (StringFormat format = MakeFormat())
            using (SolidBrush brush = new SolidBrush(Tint.Hex(0xFFFFFF, 0.92)))
            {
                c.G.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                RectangleF box = new RectangleF(c.X(12), c.Y(5), (width - 24) * c.U, (Height - 10) * c.U);
                c.G.DrawString(text, font, brush, box, format);
            }
        }
    }

    // Pictures saved to files: the app's icon, and previews of each mood.
    static class Pictures
    {
        static Bitmap Icon(int size)
        {
            Bitmap bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bitmap))
            {
                g.Clear(Color.Transparent);
                bool hasTile = size >= 48;
                int cell = hasTile ? Math.Max(1, (int)(size * 0.78f / 16)) : Math.Max(1, size / 16);
                float u = cell / 7f;
                if (hasTile)
                {
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    RectangleF tile = new RectangleF(0, 0, size, size);
                    using (GraphicsPath path = Canvas.RoundPath(tile, size * 0.22f))
                    using (LinearGradientBrush brush = new LinearGradientBrush(
                        new Rectangle(0, -1, size, size + 2), Tint.Hex(0x2B2724), Tint.Hex(0x161413), LinearGradientMode.Vertical))
                    {
                        g.FillPath(brush, path);
                    }
                }
                // The pet's middle is at (75, 57) in its own picture.
                Canvas canvas = new Canvas(g, u, (float)Math.Round(size / 2f - 75 * u), (float)Math.Round(size / 2f - 57 * u));
                if (!hasTile) canvas.Outline = 0;
                PetRenderer.Draw(canvas, Mood.Idle, 0, new PointF(0, 0), false, false);
            }
            return bitmap;
        }

        // An .ico with plain bitmap images, which every version of Windows and its compiler reads.
        public static void WriteIcon(string path)
        {
            int[] sizes = new int[] { 16, 32, 48, 256 };
            List<byte[]> images = new List<byte[]>();
            foreach (int size in sizes)
            {
                using (Bitmap bitmap = Icon(size)) images.Add(IconImage(bitmap));
            }
            using (FileStream file = new FileStream(path, FileMode.Create))
            using (BinaryWriter writer = new BinaryWriter(file))
            {
                writer.Write((ushort)0);
                writer.Write((ushort)1);
                writer.Write((ushort)sizes.Length);
                int offset = 6 + 16 * sizes.Length;
                for (int i = 0; i < sizes.Length; i++)
                {
                    writer.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
                    writer.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
                    writer.Write((byte)0);
                    writer.Write((byte)0);
                    writer.Write((ushort)1);
                    writer.Write((ushort)32);
                    writer.Write((uint)images[i].Length);
                    writer.Write((uint)offset);
                    offset += images[i].Length;
                }
                foreach (byte[] image in images) writer.Write(image);
            }
        }

        static byte[] IconImage(Bitmap bitmap)
        {
            int size = bitmap.Width;
            int maskRow = ((size + 31) / 32) * 4;
            using (MemoryStream memory = new MemoryStream())
            using (BinaryWriter writer = new BinaryWriter(memory))
            {
                writer.Write((uint)40);
                writer.Write(size);
                writer.Write(size * 2); // colour rows, then the see-through mask
                writer.Write((ushort)1);
                writer.Write((ushort)32);
                writer.Write((uint)0);
                writer.Write((uint)(size * size * 4 + maskRow * size));
                writer.Write(0);
                writer.Write(0);
                writer.Write((uint)0);
                writer.Write((uint)0);
                for (int y = size - 1; y >= 0; y--)
                {
                    for (int x = 0; x < size; x++)
                    {
                        Color pixel = bitmap.GetPixel(x, y);
                        writer.Write(pixel.B);
                        writer.Write(pixel.G);
                        writer.Write(pixel.R);
                        writer.Write(pixel.A);
                    }
                }
                for (int y = size - 1; y >= 0; y--)
                {
                    byte[] row = new byte[maskRow];
                    for (int x = 0; x < size; x++)
                    {
                        if (bitmap.GetPixel(x, y).A == 0) row[x / 8] |= (byte)(0x80 >> (x % 8));
                    }
                    writer.Write(row);
                }
                writer.Flush();
                return memory.ToArray();
            }
        }

        public static void WritePreview(Mood mood, double t, string path)
        {
            const float u = 3;
            Size size = PetRenderer.PixelSize(u);
            using (Bitmap bitmap = new Bitmap(size.Width, size.Height, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bitmap))
                {
                    g.Clear(Tint.Hex(0x1C1C1E));
                    PetRenderer.Draw(new Canvas(g, u), mood, t, new PointF(0, 0), false, true);
                }
                bitmap.Save(path, ImageFormat.Png);
            }
        }
    }
}
