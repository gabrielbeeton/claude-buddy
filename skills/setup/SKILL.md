---
name: setup
description: Builds and installs Buddy's desktop pet (Buddy.app) on this Mac, or rebuilds it after an update. Use when the person asks to set up, install, update, rebuild or fix Buddy's desktop pet, or when /buddy says the desktop app isn't installed.
---

# Set up Buddy's desktop pet

Buddy's desktop pet is a small Mac app, Buddy.app, built from the source in this plugin on the person's own Mac, so nothing unsigned is downloaded. It needs macOS 14 or later and Apple's Command Line Tools.

1. Check for Swift: run `xcrun --find swiftc`. If that fails, tell the person to run `xcode-select --install` (Apple's free Command Line Tools), wait for it to finish, then ask again. Stop there.
2. Build and install: run `bash "<this skill's base directory>/../../desktop/build.sh" --install`, using the base directory this skill was loaded from. It takes about a minute. It installs the app to `~/Applications/Buddy.app`, replacing an older Buddy but never another app, and starts it.
3. If the build fails, show the person the error lines and stop. Don't work around the script.
4. When it worked, tell the person briefly:
   - Buddy sits in the bottom-right corner of the screen. Click it to chat, drag it anywhere, right-click it for more.
   - The little tab at the screen edge hides and shows Buddy. `/buddy bye` quits it and `/buddy` brings it back.
   - The first time they ask Buddy to look at the screen, macOS asks for Screen Recording permission for Buddy (System Settings › Privacy & Security › Screen & System Audio Recording). After a rebuild, macOS may ask again.
