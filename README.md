# Buddy

A little companion for Claude Code: the orange Claude creature, living in the
bottom-right corner of your Mac. While Claude works, Buddy shows what it's
doing. Click Buddy to chat with it, or ask it to look at your screen.

## Install

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
desktop app for your Mac (about a minute) and starts it. This needs macOS 14 or
later and Apple's Command Line Tools (`xcode-select --install`).

## Using Buddy

- Click Buddy to chat, drag it anywhere, right-click it for more.
- The little tab at the screen edge hides and shows Buddy.
- Say "look", or press the eye in the chat, and Buddy describes your screen.
  The first time, macOS asks for Screen Recording permission for Buddy.
- `/buddy` wakes Buddy, `/buddy bye` quits it, and `/buddy panel` opens Buddy
  in a side panel in Claude.

Buddy answers while a Claude Code session with the plugin is open; otherwise it naps.

## Turning it off

- Hide it: click the tab at the screen edge. Quit it: right-click Buddy and
  choose Quit Buddy, or type `/buddy bye`.
- Stop the plugin: `claude plugin disable buddy@claude-buddy`. Remove it:
  `claude plugin uninstall buddy@claude-buddy`, then delete `~/Applications/Buddy.app`.

## How it works

The plugin (`hooks/register.tsx`) follows what Claude does in each session,
answers Buddy's chat with a small model call, and writes status files to
`~/.claude/buddy/`. The desktop app (`desktop/Buddy.swift`) reads them and draws
Buddy. A "look" saves one screenshot to `~/.claude/buddy/shots/`; a helper agent
that may read only that file describes it, and Buddy deletes it afterwards.
