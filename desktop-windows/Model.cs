// Buddy for Windows: what Buddy knows, and the small files it shares with the Buddy mod.
// It is the same set of files the Mac app uses, in %USERPROFILE%\.claude\buddy:
//   sessions\<id>.json  each Claude session's status (written by the mod)
//   inbox\<id>.json     what you said to Buddy (written by this app)
//   outbox\<id>.json    Buddy's replies (written by the mod)
//   shots\<id>.png      a screenshot you asked Buddy to look at (deleted after)
//   quit                asks this app to quit (/buddy bye)
//   show                asks a Buddy that is already running to come out of hiding (/buddy)
//
// This file is plain ASCII and plain C# 5 on purpose: it is compiled on your own PC by
// the C# compiler that ships inside Windows, so there is nothing to download.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace Buddy
{
    enum Mood { Idle, Working, Thinking, Looking, Happy, Sleeping, Dragged }

    static class Paths
    {
        public static readonly string Home = FindHome();
        public static readonly string Root = Path.Combine(Path.Combine(Home, ".claude"), "buddy");
        public static readonly string Sessions = Path.Combine(Root, "sessions");
        public static readonly string Inbox = Path.Combine(Root, "inbox");
        public static readonly string Outbox = Path.Combine(Root, "outbox");
        public static readonly string Shots = Path.Combine(Root, "shots");
        public static readonly string Chat = Path.Combine(Root, "chat.json");
        public static readonly string Quit = Path.Combine(Root, "quit");
        public static readonly string Show = Path.Combine(Root, "show");
        public static readonly string Settings = Path.Combine(Root, "desktop-settings.json");
        public static readonly string Log = Path.Combine(Root, "desktop-log.txt");

        // The same folder the mod uses: it reads USERPROFILE too.
        static string FindHome()
        {
            string home = Environment.GetEnvironmentVariable("USERPROFILE");
            if (string.IsNullOrEmpty(home)) home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return home;
        }

        public static void Ensure()
        {
            foreach (string dir in new string[] { Root, Sessions, Inbox, Outbox, Shots })
            {
                try { Directory.CreateDirectory(dir); } catch (Exception) { }
            }
        }

        public static void Remove(string path)
        {
            try { File.Delete(path); } catch (Exception) { }
        }
    }

    static class Log
    {
        static int lines;

        public static void Write(string message)
        {
            if (lines++ > 200) return; // never fill the disk
            try
            {
                File.AppendAllText(Paths.Log, DateTime.Now.ToString("s") + " " + message + Environment.NewLine);
            }
            catch (Exception) { }
        }
    }

    static class Json
    {
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

        static JavaScriptSerializer Serializer()
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = int.MaxValue;
            return serializer;
        }

        // Null when the file is missing, half-written or not JSON.
        public static object Read(string path)
        {
            try { return Serializer().DeserializeObject(File.ReadAllText(path, Utf8)); }
            catch (Exception) { return null; }
        }

        public static Dictionary<string, object> ReadObject(string path)
        {
            return Read(path) as Dictionary<string, object>;
        }

        public static void Write(string path, object value)
        {
            File.WriteAllText(path, Serializer().Serialize(value), Utf8);
        }

        public static string Str(Dictionary<string, object> map, string key)
        {
            object value;
            return map.TryGetValue(key, out value) ? value as string : null;
        }

        public static double Num(Dictionary<string, object> map, string key, double fallback)
        {
            object value;
            if (!map.TryGetValue(key, out value) || value == null || value is string || value is bool) return fallback;
            try { return Convert.ToDouble(value, CultureInfo.InvariantCulture); }
            catch (Exception) { return fallback; }
        }

        public static bool Bool(Dictionary<string, object> map, string key, bool fallback)
        {
            object value;
            if (map.TryGetValue(key, out value) && value is bool) return (bool)value;
            return fallback;
        }
    }

    // What the app remembers between runs.
    static class Settings
    {
        public static bool HasPosition;
        public static int PetX;
        public static int PetY;
        public static bool ShowStatus = true;
        public static bool PetHidden;

        public static void Load()
        {
            Dictionary<string, object> map = Json.ReadObject(Paths.Settings);
            if (map == null) return;
            HasPosition = Json.Bool(map, "hasPosition", false);
            PetX = (int)Json.Num(map, "petX", 0);
            PetY = (int)Json.Num(map, "petY", 0);
            ShowStatus = Json.Bool(map, "showStatus", true);
            PetHidden = Json.Bool(map, "petHidden", false);
        }

        public static void Save()
        {
            Dictionary<string, object> map = new Dictionary<string, object>();
            map["hasPosition"] = HasPosition;
            map["petX"] = PetX;
            map["petY"] = PetY;
            map["showStatus"] = ShowStatus;
            map["petHidden"] = PetHidden;
            try { Json.Write(Paths.Settings, map); }
            catch (Exception error) { Log.Write("settings: " + error.Message); }
        }
    }

    class ChatLine
    {
        public readonly string Who; // "me" or "buddy"
        public readonly string Text;

        public ChatLine(string who, string text)
        {
            Who = who;
            Text = text;
        }
    }

    class Pending
    {
        public readonly string Kind;
        public readonly DateTime Since = DateTime.UtcNow;

        public Pending(string kind)
        {
            Kind = kind;
        }
    }

    static class Screenshot
    {
        // Saves the main screen as a PNG, at most 1600 pixels on its longer side.
        public static void Save(string path)
        {
            Rectangle bounds = Screen.PrimaryScreen.Bounds;
            using (Bitmap full = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format24bppRgb))
            {
                using (Graphics g = Graphics.FromImage(full))
                {
                    g.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);
                }
                int longest = Math.Max(bounds.Width, bounds.Height);
                if (longest <= 1600)
                {
                    full.Save(path, ImageFormat.Png);
                    return;
                }
                double scale = 1600.0 / longest;
                int width = Math.Max(1, (int)Math.Round(bounds.Width * scale));
                int height = Math.Max(1, (int)Math.Round(bounds.Height * scale));
                using (Bitmap small = new Bitmap(width, height, PixelFormat.Format24bppRgb))
                {
                    using (Graphics g = Graphics.FromImage(small))
                    {
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.PixelOffsetMode = PixelOffsetMode.Half;
                        g.DrawImage(full, new Rectangle(0, 0, width, height));
                    }
                    small.Save(path, ImageFormat.Png);
                }
            }
        }
    }

    class BuddyModel
    {
        public readonly List<ChatLine> Chat = new List<ChatLine>();
        public int ChatVersion;
        public string Activity = "";
        public bool IsBusy;
        public bool IsConnected;
        public bool IsDragging;
        public bool IsChatOpen;

        public Action OnDone;
        public Action<string> OnReply;
        public Action OnPolled;
        public Action<bool> SetCapturing;
        public Action OnQuit;
        public Action OnShow;

        readonly Dictionary<string, Pending> pending = new Dictionary<string, Pending>();
        Dictionary<string, Dictionary<string, object>> lastGood = new Dictionary<string, Dictionary<string, object>>();
        DateTime happyUntil = DateTime.MinValue;
        bool hasPolled;

        static readonly Regex LookWords = new Regex(
            @"\b(look|screen|see (this|that|what)|what'?s on)\b", RegexOptions.IgnoreCase);

        const string Asleep =
            "zzz\u2026 I'm only awake while Claude is open. Start a Claude Code session with Buddy loaded, then try again!";

        public BuddyModel()
        {
            LoadChat();
        }

        public bool IsWaiting
        {
            get { return pending.Count > 0; }
        }

        public bool IsLooking
        {
            get
            {
                foreach (Pending wait in pending.Values)
                {
                    if (wait.Kind == "look") return true;
                }
                return false;
            }
        }

        public Mood Mood
        {
            get
            {
                if (IsDragging) return Mood.Dragged;
                if (IsLooking) return Mood.Looking;
                if (IsWaiting) return Mood.Thinking;
                if (DateTime.UtcNow < happyUntil) return Mood.Happy;
                if (IsBusy) return Mood.Working;
                if (!IsConnected) return Mood.Sleeping;
                return Mood.Idle;
            }
        }

        static double NowMs()
        {
            return (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
        }

        static string[] JsonFiles(string dir)
        {
            try
            {
                List<string> found = new List<string>();
                foreach (string file in Directory.GetFiles(dir))
                {
                    if (file.EndsWith(".json", StringComparison.OrdinalIgnoreCase)) found.Add(file);
                }
                return found.ToArray();
            }
            catch (Exception)
            {
                return new string[0];
            }
        }

        // Called twice a second.
        public void Poll()
        {
            if (File.Exists(Paths.Quit))
            {
                Paths.Remove(Paths.Quit);
                if (OnQuit != null) OnQuit();
                return;
            }
            if (File.Exists(Paths.Show))
            {
                Paths.Remove(Paths.Show);
                if (OnShow != null) OnShow();
            }
            ReadSessions();
            ReadReplies();
            ExpireWaits();
            hasPolled = true;
            if (OnPolled != null) OnPolled();
        }

        void ReadSessions()
        {
            double now = NowMs();
            Dictionary<string, Dictionary<string, object>> seen = new Dictionary<string, Dictionary<string, object>>();
            foreach (string file in JsonFiles(Paths.Sessions))
            {
                string key = Path.GetFileName(file);
                Dictionary<string, object> status = Json.ReadObject(file);
                if (status != null && status.ContainsKey("heartbeat")) seen[key] = status;
                else if (lastGood.ContainsKey(key)) seen[key] = lastGood[key]; // caught mid-write: keep the last good read
            }
            lastGood = seen;

            bool nowBusy = false;
            bool connected = false;
            bool justEnded = false;
            double newest = double.MinValue;
            string newActivity = "";
            foreach (KeyValuePair<string, Dictionary<string, object>> pair in seen)
            {
                double beat = Json.Num(pair.Value, "heartbeat", 0);
                if (now - beat > 86400000)
                {
                    Paths.Remove(Path.Combine(Paths.Sessions, pair.Key));
                    continue;
                }
                if (now - beat >= 15000) continue;
                connected = true;
                if (Json.Num(pair.Value, "lastTurnEndAt", 0) > now - 20000) justEnded = true;
                if (Json.Bool(pair.Value, "isBusy", false))
                {
                    nowBusy = true;
                    if (beat > newest)
                    {
                        newest = beat;
                        newActivity = Json.Str(pair.Value, "activity") ?? "";
                    }
                }
            }
            if (hasPolled && IsBusy && !nowBusy && justEnded)
            {
                happyUntil = DateTime.UtcNow.AddSeconds(6);
                if (OnDone != null) OnDone();
            }
            IsBusy = nowBusy;
            Activity = newActivity;
            IsConnected = connected;
        }

        void ReadReplies()
        {
            foreach (string file in JsonFiles(Paths.Outbox))
            {
                string id = Path.GetFileNameWithoutExtension(file);
                if (!pending.ContainsKey(id))
                {
                    try
                    {
                        if ((DateTime.UtcNow - File.GetLastWriteTimeUtc(file)).TotalSeconds > 600) File.Delete(file);
                    }
                    catch (Exception) { }
                    continue;
                }
                Dictionary<string, object> reply = Json.ReadObject(file);
                if (reply == null) continue;
                string text = Json.Str(reply, "text");
                if (text == null) continue;
                Paths.Remove(file);
                Paths.Remove(Path.Combine(Paths.Shots, id + ".png"));
                pending.Remove(id);
                Add(new ChatLine("buddy", text));
                if (!IsChatOpen && OnReply != null) OnReply(text);
            }
        }

        void ExpireWaits()
        {
            DateTime now = DateTime.UtcNow;
            foreach (string id in new List<string>(pending.Keys))
            {
                Pending wait = pending[id];
                if ((now - wait.Since).TotalSeconds <= (wait.Kind == "look" ? 150 : 90)) continue;
                pending.Remove(id);
                Paths.Remove(Path.Combine(Paths.Inbox, id + ".json"));
                Paths.Remove(Path.Combine(Paths.Shots, id + ".png"));
                Add(new ChatLine("buddy", "*(I couldn't reach Claude just now. Is a Claude Code session with Buddy open?)*"));
            }
        }

        List<ChatLine> Recent(int count)
        {
            int start = Math.Max(0, Chat.Count - count);
            return Chat.GetRange(start, Chat.Count - start);
        }

        // False when Buddy can't take the message right now.
        public bool Send(string raw)
        {
            string text = (raw ?? "").Trim();
            if (text.Length == 0 || IsWaiting) return false;
            List<ChatLine> history = Recent(14);
            Add(new ChatLine("me", text));
            if (!IsConnected)
            {
                Add(new ChatLine("buddy", Asleep));
                return true;
            }
            if (LookWords.IsMatch(text)) Look(text, history);
            else Post(NewId(), "say", text, null, history);
            return true;
        }

        public void LookNow()
        {
            if (IsWaiting) return;
            string question = "What do you see on my screen?";
            List<ChatLine> history = Recent(14);
            Add(new ChatLine("me", question));
            if (!IsConnected)
            {
                Add(new ChatLine("buddy", Asleep));
                return;
            }
            Look(question, history);
        }

        void Look(string question, List<ChatLine> history)
        {
            string id = NewId();
            string shot = Path.Combine(Paths.Shots, id + ".png");
            pending[id] = new Pending("look");
            if (SetCapturing != null) SetCapturing(true); // the chat steps out of the picture
            System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
            timer.Interval = 300;
            timer.Tick += delegate
            {
                timer.Stop();
                timer.Dispose();
                bool captured = false;
                try
                {
                    Directory.CreateDirectory(Paths.Shots);
                    Screenshot.Save(shot);
                    captured = File.Exists(shot);
                }
                catch (Exception error)
                {
                    Log.Write("screenshot: " + error.Message);
                }
                if (SetCapturing != null) SetCapturing(false);
                if (!captured)
                {
                    pending.Remove(id);
                    Add(new ChatLine("buddy", "*(I tried to look, but I couldn't take a screenshot.)*"));
                    return;
                }
                Post(id, "look", question, shot, history);
            };
            timer.Start();
        }

        static ArrayList Lines(List<ChatLine> lines)
        {
            ArrayList list = new ArrayList();
            foreach (ChatLine line in lines)
            {
                Dictionary<string, object> map = new Dictionary<string, object>();
                map["who"] = line.Who;
                map["text"] = line.Text;
                list.Add(map);
            }
            return list;
        }

        void Post(string id, string kind, string text, string image, List<ChatLine> history)
        {
            pending[id] = new Pending(kind);
            try
            {
                Dictionary<string, object> request = new Dictionary<string, object>();
                request["id"] = id;
                request["kind"] = kind;
                request["text"] = text;
                if (image != null) request["image"] = image;
                request["history"] = Lines(history);
                Directory.CreateDirectory(Paths.Inbox);
                string temp = Path.Combine(Paths.Inbox, id + ".tmp");
                Json.Write(temp, request);
                File.Move(temp, Path.Combine(Paths.Inbox, id + ".json"));
            }
            catch (Exception error)
            {
                pending.Remove(id);
                Add(new ChatLine("buddy", "*(I couldn't pass that on to Claude: " + error.Message + ")*"));
            }
        }

        static string NewId()
        {
            return ((long)NowMs()).ToString(CultureInfo.InvariantCulture) + "-" +
                Guid.NewGuid().ToString("N").Substring(0, 8).ToUpperInvariant();
        }

        public void Add(ChatLine line)
        {
            Chat.Add(line);
            if (Chat.Count > 100) Chat.RemoveRange(0, Chat.Count - 100);
            ChatVersion++;
            SaveChat();
        }

        public void ClearChat()
        {
            Chat.Clear();
            ChatVersion++;
            SaveChat();
        }

        void SaveChat()
        {
            try { Json.Write(Paths.Chat, Lines(Chat)); }
            catch (Exception error) { Log.Write("chat: " + error.Message); }
        }

        void LoadChat()
        {
            object[] lines = Json.Read(Paths.Chat) as object[];
            if (lines == null) return;
            foreach (object item in lines)
            {
                Dictionary<string, object> map = item as Dictionary<string, object>;
                if (map == null) continue;
                string who = Json.Str(map, "who");
                string text = Json.Str(map, "text");
                if (who != null && text != null) Chat.Add(new ChatLine(who, text));
            }
        }
    }
}
