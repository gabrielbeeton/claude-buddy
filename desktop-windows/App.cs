// Buddy for Windows: a little Claude Code companion that lives in the corner of your screen.
// It shows what Claude is doing, chats with you, and can look at your screen.
// This is the Windows edition of desktop/Buddy.swift. It talks to Claude through the
// Buddy mod with the same small files (see Model.cs), so the two behave alike.

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Buddy")]
[assembly: AssemblyProduct("Buddy desktop pet")]
[assembly: AssemblyDescription("A little Claude Code companion for your desktop")]
[assembly: AssemblyVersion("0.3.0.0")]
[assembly: AssemblyFileVersion("0.3.0.0")]

namespace Buddy
{
    class BuddyApp : ApplicationContext
    {
        readonly BuddyModel model = new BuddyModel();
        readonly Stopwatch clock = Stopwatch.StartNew();
        readonly float u;
        readonly PetForm pet;
        readonly TabForm tab;
        readonly BubbleForm bubble;
        readonly ChatForm chat;
        readonly Timer frames = new Timer();
        readonly Timer polls = new Timer();
        ContextMenuStrip menu;

        Point home; // where the pet stands when it is not hidden
        bool hasUnread;
        bool openChatOnShow;
        string flashText;
        DateTime flashUntil = DateTime.MinValue;
        bool flashOpensChat;
        bool bubbleOpensChat;
        bool isCapturing;
        bool chatWasOpen;
        int pollCount;

        // The slide in and out when Buddy is hidden or shown
        bool isSliding;
        double slideStart;
        Point slideFrom;
        Point slideTo;
        bool slideHides;

        public BuddyApp()
        {
            Paths.Ensure();
            Paths.Remove(Paths.Quit);
            Paths.Remove(Paths.Show);
            Settings.Load();

            using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) u = Canvas.UnitFor(g.DpiX);

            pet = new PetForm(model, u);
            tab = new TabForm(u);
            bubble = new BubbleForm(u);
            chat = new ChatForm(model, u);

            home = InitialOrigin();
            pet.Location = home;
            if (!Settings.PetHidden)
            {
                pet.Show();
                pet.Render(0);
            }
            tab.PetHidden = Settings.PetHidden;
            LayoutTab();
            tab.Show();
            tab.Render();

            pet.Clicked = ToggleChat;
            pet.Moved = delegate
            {
                home = pet.Location;
                LayoutAttached();
            };
            pet.Dropped = SavePosition;
            pet.MenuRequested = delegate { ShowMenu(pet); };
            tab.Clicked = TogglePetHidden;
            tab.MenuRequested = delegate { ShowMenu(tab); };
            bubble.Clicked = BubbleTapped;
            chat.CloseRequested = CloseChat;
            chat.LookRequested = model.LookNow;

            model.OnDone = delegate { Flash("Claude is done. Your turn!", 6, false); };
            model.OnReply = delegate(string text)
            {
                if (Settings.PetHidden)
                {
                    hasUnread = true;
                    openChatOnShow = true;
                }
                else
                {
                    Flash("Buddy: " + text, 10, true);
                }
            };
            model.OnPolled = RefreshBubble;
            model.SetCapturing = SetCapturing;
            model.OnQuit = Quit;
            model.OnShow = delegate { if (Settings.PetHidden) SetPetHidden(false); }; // `/buddy` brings a hidden Buddy back

            frames.Interval = 40;
            frames.Tick += delegate { Guard(DrawFrame); };
            frames.Start();
            polls.Interval = 500;
            polls.Tick += delegate { Guard(Poll); };
            polls.Start();
            Guard(Poll);

            SystemEvents.DisplaySettingsChanged += OnDisplayChanged;
        }

        static void Guard(Action work)
        {
            try { work(); }
            catch (Exception error) { Log.Write(error.ToString()); }
        }

        int S(float points)
        {
            return (int)Math.Round(points * u);
        }

        void Poll()
        {
            model.Poll();
            if (chat.Visible) chat.RefreshState();
            if (++pollCount % 6 == 0)
            {
                Native.KeepOnTop(pet);
                Native.KeepOnTop(tab);
                Native.KeepOnTop(bubble);
            }
        }

        void DrawFrame()
        {
            double t = clock.Elapsed.TotalSeconds;
            if (isSliding) StepSlide(t);
            if (pet.Visible) pet.Render(t);

            int rgb;
            bool pulses;
            double alpha = 1;
            Mood mood = model.Mood;
            if (hasUnread)
            {
                rgb = 0x8AB4F8;
                pulses = true;
            }
            else
            {
                PetRenderer.StatusLight(mood, out rgb, out pulses);
                if (mood == Mood.Sleeping)
                {
                    rgb = 0x9A9A9A;
                    alpha = 0.3;
                }
                else if (mood == Mood.Idle || mood == Mood.Dragged)
                {
                    alpha = 0.65;
                }
            }
            if (pulses) alpha *= 0.4 + 0.6 * PetRenderer.Wave(t, 1.0);
            tab.Status = Tint.Hex(rgb, alpha);
            tab.Hovered = new Rectangle(tab.Location, tab.PixelSize).Contains(Cursor.Position);
            tab.Render();

            if (chat.Visible && model.IsWaiting) chat.RefreshState();
        }

        void Quit()
        {
            frames.Stop();
            polls.Stop();
            SystemEvents.DisplaySettingsChanged -= OnDisplayChanged;
            foreach (Form form in new Form[] { chat, bubble, tab, pet }) form.Hide();
            ExitThread();
        }

        void OnDisplayChanged(object sender, EventArgs e)
        {
            if (pet.IsDisposed || !pet.IsHandleCreated) return;
            pet.BeginInvoke(new Action(delegate { Guard(KeepOnScreen); }));
        }

        // ---- Hiding

        void TogglePetHidden()
        {
            SetPetHidden(!Settings.PetHidden);
        }

        void SetPetHidden(bool hidden)
        {
            if (hidden == Settings.PetHidden) return;
            Settings.PetHidden = hidden;
            Settings.Save();
            tab.PetHidden = hidden;

            Rectangle frame = new Rectangle(home, pet.PixelSize);
            Rectangle area = WorkArea(frame);
            bool toRight = frame.Left + frame.Width / 2 >= area.Left + area.Width / 2;
            Point away = new Point(toRight ? area.Right + S(8) : area.Left - frame.Width - S(8), home.Y);
            if (hidden)
            {
                if (chat.Visible) CloseChat();
                bubble.Hide();
                slideFrom = pet.Location;
                slideTo = away;
            }
            else
            {
                pet.Location = away;
                pet.Alpha = 0;
                pet.Show();
                slideFrom = away;
                slideTo = home;
            }
            slideHides = hidden;
            slideStart = clock.Elapsed.TotalSeconds;
            isSliding = true;
            Native.KeepOnTop(tab);
        }

        void StepSlide(double t)
        {
            double p = Math.Min(1, (t - slideStart) / 0.22);
            double eased = p * p * (3 - 2 * p);
            pet.Location = new Point(
                (int)Math.Round(slideFrom.X + (slideTo.X - slideFrom.X) * eased),
                (int)Math.Round(slideFrom.Y + (slideTo.Y - slideFrom.Y) * eased));
            pet.Alpha = (byte)Math.Round(255 * (slideHides ? 1 - eased : eased));
            if (p < 1) return;

            isSliding = false;
            pet.Alpha = 255;
            if (slideHides)
            {
                pet.Hide();
                pet.Location = home;
                return;
            }
            pet.Location = home;
            hasUnread = false;
            LayoutTab();
            if (openChatOnShow)
            {
                openChatOnShow = false;
                OpenChat();
            }
            else
            {
                RefreshBubble();
            }
        }

        // ---- Position

        static Rectangle WorkArea(Rectangle frame)
        {
            return Screen.FromPoint(new Point(frame.Left + frame.Width / 2, frame.Top + frame.Height / 2)).WorkingArea;
        }

        Point DefaultOrigin()
        {
            Rectangle area = Screen.PrimaryScreen.WorkingArea;
            return new Point(area.Right - pet.PixelSize.Width - S(18), area.Bottom - pet.PixelSize.Height - S(2));
        }

        Point InitialOrigin()
        {
            if (Settings.HasPosition)
            {
                Point saved = new Point(Settings.PetX, Settings.PetY);
                if (IsOnScreen(saved)) return saved;
            }
            return DefaultOrigin();
        }

        bool IsOnScreen(Point origin)
        {
            Point middle = new Point(origin.X + pet.PixelSize.Width / 2, origin.Y + pet.PixelSize.Height / 2);
            foreach (Screen screen in Screen.AllScreens)
            {
                if (screen.Bounds.Contains(middle)) return true;
            }
            return false;
        }

        void SavePosition()
        {
            home = pet.Location;
            Settings.HasPosition = true;
            Settings.PetX = home.X;
            Settings.PetY = home.Y;
            Settings.Save();
        }

        void KeepOnScreen()
        {
            if (isSliding) return;
            if (!IsOnScreen(home))
            {
                home = DefaultOrigin();
                pet.Location = home;
                SavePosition();
            }
            LayoutAttached();
        }

        void ResetPosition()
        {
            if (isSliding) return;
            Settings.HasPosition = false;
            Settings.Save();
            home = DefaultOrigin();
            pet.Location = home;
            LayoutAttached();
        }

        void LayoutAttached()
        {
            if (chat.Visible) LayoutChat();
            if (bubble.Visible) LayoutBubble();
            LayoutTab();
        }

        void LayoutTab()
        {
            Rectangle frame = new Rectangle(home, pet.PixelSize);
            Rectangle area = WorkArea(frame);
            Size size = tab.PixelSize;
            bool onRight = frame.Left + frame.Width / 2 >= area.Left + area.Width / 2;
            int middle = frame.Top + S(57);
            int y = Math.Min(Math.Max(middle - size.Height / 2, area.Top + S(4)), area.Bottom - size.Height - S(4));
            tab.Location = new Point(onRight ? area.Right - size.Width : area.Left, y);
            tab.OnRight = onRight;
        }

        void LayoutChat()
        {
            Rectangle frame = new Rectangle(pet.Location, pet.PixelSize);
            Rectangle area = WorkArea(frame);
            Size size = chat.Size;
            int x = Math.Min(Math.Max(frame.Left + frame.Width / 2 - size.Width / 2, area.Left + S(8)), area.Right - size.Width - S(8));
            int y = frame.Top + S(10) - size.Height; // above Buddy
            if (y < area.Top + S(8)) y = Math.Min(area.Bottom - S(8) - size.Height, frame.Bottom - S(10)); // or below
            chat.Location = new Point(x, y);
        }

        void LayoutBubble()
        {
            Rectangle frame = new Rectangle(pet.Location, pet.PixelSize);
            Rectangle area = WorkArea(frame);
            Size size = bubble.PixelSize;
            int x = Math.Min(Math.Max(frame.Left + frame.Width / 2 - size.Width / 2, area.Left + S(6)), area.Right - size.Width - S(6));
            int y = Math.Max(frame.Top + S(16) - size.Height, area.Top);
            bubble.Location = new Point(x, y);
        }

        // ---- Chat

        void ToggleChat()
        {
            if (chat.Visible) CloseChat();
            else OpenChat();
        }

        void OpenChat()
        {
            if (Settings.PetHidden)
            {
                openChatOnShow = true; // opens once Buddy is back
                SetPetHidden(false);
                return;
            }
            model.IsChatOpen = true;
            flashUntil = DateTime.MinValue;
            LayoutChat();
            chat.Show();
            chat.Activate();
            chat.FocusInput();
            RefreshBubble();
        }

        void CloseChat()
        {
            model.IsChatOpen = false;
            chat.Hide();
            RefreshBubble();
        }

        // ---- Bubble

        void Flash(string text, double seconds, bool opensChat)
        {
            flashText = text;
            flashUntil = DateTime.UtcNow.AddSeconds(seconds);
            flashOpensChat = opensChat;
            RefreshBubble();
        }

        void RefreshBubble()
        {
            if (isCapturing) return;
            string text = null;
            bool opensChat = false;
            if (flashText != null && DateTime.UtcNow < flashUntil)
            {
                text = flashText;
                opensChat = flashOpensChat;
            }
            else if (Settings.ShowStatus && model.IsBusy)
            {
                text = model.Activity.Length == 0 ? "Claude is working\u2026" : model.Activity;
            }
            if (chat.Visible || Settings.PetHidden || isSliding) text = null;
            if (text == null)
            {
                if (bubble.Visible) bubble.Hide();
                return;
            }
            bubbleOpensChat = opensChat;
            string line = text.Replace("\r", " ").Replace("\n", " ").Replace("*", "").Replace("`", "");
            if (line.Length > 64) line = line.Substring(0, 63) + "\u2026";
            bool changed = bubble.Line != line || !bubble.Visible;
            if (changed) bubble.SetLine(line);
            LayoutBubble();
            if (changed) bubble.Render();
            if (!bubble.Visible) bubble.Show();
        }

        void BubbleTapped()
        {
            if (bubbleOpensChat) OpenChat();
            else OpenClaude();
        }

        // While Buddy takes a screenshot, its chat and bubble step out of the picture.
        void SetCapturing(bool on)
        {
            isCapturing = on;
            if (on)
            {
                chatWasOpen = chat.Visible;
                chat.Hide();
                bubble.Hide();
                return;
            }
            if (chatWasOpen)
            {
                LayoutChat();
                chat.Show();
                chat.Activate();
                chat.FocusInput();
            }
            RefreshBubble();
        }

        // ---- Menu

        void ShowMenu(Form owner)
        {
            if (menu != null) menu.Dispose();
            menu = new ContextMenuStrip();
            menu.Items.Add(chat.Visible ? "Close Chat" : "Chat with Buddy", null, delegate { ToggleChat(); });
            menu.Items.Add(Settings.PetHidden ? "Show Buddy" : "Hide Buddy", null, delegate { TogglePetHidden(); });
            menu.Items.Add("Look at My Screen", null, delegate
            {
                if (!chat.Visible) OpenChat();
                model.LookNow();
            });
            menu.Items.Add("Open Claude", null, delegate { OpenClaude(); });
            menu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem showStatus = new ToolStripMenuItem("Show What Claude Is Doing");
            showStatus.Checked = Settings.ShowStatus;
            showStatus.Click += delegate
            {
                Settings.ShowStatus = !Settings.ShowStatus;
                Settings.Save();
                RefreshBubble();
            };
            menu.Items.Add(showStatus);
            menu.Items.Add("Clear Chat", null, delegate
            {
                model.ClearChat();
                if (chat.Visible) chat.RefreshState();
            });
            menu.Items.Add("Move Back to Corner", null, delegate { ResetPosition(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit Buddy", null, delegate { Quit(); });
            // Without this the menu would not close when you click somewhere else.
            Native.SetForegroundWindow(owner.Handle);
            menu.Show(Cursor.Position);
        }

        void OpenClaude()
        {
            try
            {
                using (RegistryKey key = Registry.ClassesRoot.OpenSubKey("claude"))
                {
                    if (key == null)
                    {
                        Flash("I couldn't find the Claude app to open.", 5, false);
                        return;
                    }
                }
                ProcessStartInfo start = new ProcessStartInfo("claude://");
                start.UseShellExecute = true;
                Process.Start(start);
            }
            catch (Exception error)
            {
                Log.Write("open Claude: " + error.Message);
            }
        }
    }

    static class Program
    {
        static int RenderToFile(string[] args)
        {
            if (args[0] == "--render-icon")
            {
                Pictures.WriteIcon(args[1]);
                return 0;
            }
            Mood mood;
            if (args[0] != "--render" || args.Length < 3 || !Enum.TryParse<Mood>(args[1], true, out mood)) return 2;
            double t = 0.3;
            if (args.Length >= 4)
            {
                double.TryParse(args[3], System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture, out t);
            }
            Pictures.WritePreview(mood, t, args[2]);
            return 0;
        }

        [STAThread]
        static int Main(string[] args)
        {
            try { Native.SetProcessDPIAware(); } catch (Exception) { }

            // Buddy draws its own icon and previews of its moods.
            if (args.Length >= 2 && args[0].StartsWith("--render"))
            {
                try
                {
                    return RenderToFile(args);
                }
                catch (Exception error)
                {
                    Log.Write("render: " + error);
                    return 1;
                }
            }

            bool isFirst;
            using (System.Threading.Mutex only = new System.Threading.Mutex(true, "Local\\BuddyDesktopPet", out isFirst))
            {
                if (!isFirst)
                {
                    // Already running: ask that Buddy to come out, the way `/buddy` expects.
                    try
                    {
                        Paths.Ensure();
                        File.WriteAllText(Paths.Show, "show");
                    }
                    catch (Exception) { }
                    return 0;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += delegate(object sender, System.Threading.ThreadExceptionEventArgs e)
                {
                    Log.Write(e.Exception.ToString());
                };
                AppDomain.CurrentDomain.UnhandledException += delegate(object sender, UnhandledExceptionEventArgs e)
                {
                    Log.Write("fatal: " + e.ExceptionObject);
                };
                Application.Run(new BuddyApp());
                GC.KeepAlive(only);
            }
            return 0;
        }
    }
}
