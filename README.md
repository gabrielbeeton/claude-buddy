# Buddy

A little companion for Claude Code: the orange Claude creature, living in the
bottom-right corner of your screen, on a Mac or a Windows PC. While Claude
works, Buddy shows what it's doing. Click Buddy to chat with it, or ask it to
look at your screen.

## Install

The steps are the same on Mac and Windows.

In the Claude desktop app: click **+** next to the prompt box, then **Plugins**,
**Add marketplace**, and enter `gabrielbeeton/claude-buddy`. Then **Add plugin**
and choose **buddy**.

Or at the prompt of a terminal Claude Code session:

```
/plugin install buddy --marketplace gabrielbeeton/claude-buddy
```

From a shell:

```
claude plugin install buddy --marketplace gabrielbeeton/claude-buddy
```

Then, in a Claude Code session, type `/buddy:setup`. Claude builds Buddy's
desktop app on your own computer and starts it, so nothing unsigned is
downloaded:

- **Mac**: about a minute. Needs macOS 14 or later and Apple's Command Line
  Tools (`xcode-select --install`).
- **Windows**: a few seconds. Needs Windows 10 or 11 and nothing else: it uses
  the C# compiler that is part of Windows.
- **Linux**: there is no floating pet yet. `/buddy panel` opens Buddy in a side
  panel inside Claude instead.

## Using Buddy

- Click Buddy to chat, drag it anywhere, right-click it for more.
- The little tab at the screen edge hides and shows Buddy.
- Say "look", or press the eye in the chat, and Buddy describes your screen.
  On a Mac, the first time, macOS asks for Screen Recording permission for Buddy.
- `/buddy` wakes Buddy, `/buddy bye` quits it, and `/buddy panel` opens Buddy
  in a side panel in Claude.

Buddy answers while a Claude Code session with the plugin is open; otherwise it naps.

## Turning it off

- Hide it: click the tab at the screen edge. Quit it: right-click Buddy and
  choose Quit Buddy, or type `/buddy bye`.
- Stop the plugin: `claude plugin disable buddy@claude-buddy`. Remove it:
  `claude plugin uninstall buddy@claude-buddy`, then delete the app:
  `~/Applications/Buddy.app` on a Mac, the `%LOCALAPPDATA%\Buddy` folder on Windows.

## How it works

The plugin (`hooks/register.tsx`) follows what Claude does in each session,
answers Buddy's chat with a small model call, and writes status files to
`~/.claude/buddy/` (`%USERPROFILE%\.claude\buddy\` on Windows). The desktop app
reads them and draws Buddy. There are two editions that share those files and
behave alike: `desktop/Buddy.swift` for Mac and `desktop-windows/` (C#) for
Windows. A "look" saves one screenshot to the `shots` folder there; a helper
agent that may read only that file describes it, and Buddy deletes it afterwards.

## Testing

`claude plugin test .` runs the plugin's tests on any computer. The Windows
edition is built and tried on a real Windows desktop by GitHub Actions on every
push (`.github/workflows/windows.yml`): it clicks Buddy, types to it, hides,
shows and drags it, and has it talk to a real Claude Code session.
