---
name: setup
description: Builds and installs Buddy's desktop pet on this computer (Buddy.app on a Mac, Buddy.exe on a Windows PC), or rebuilds it after an update. Use when the person asks to set up, install, update, rebuild or fix Buddy's desktop pet, or when /buddy says the desktop app isn't installed.
---

# Set up Buddy's desktop pet

Buddy's desktop pet is a small app built from the source in this plugin on the person's own computer, so nothing unsigned is downloaded. There is one edition for Mac and a separate one for Windows. Work out which computer this is, then follow that section only.

## On a Mac

It needs macOS 14 or later and Apple's Command Line Tools.

1. Check for Swift: run `xcrun --find swiftc`. If that fails, tell the person to run `xcode-select --install` (Apple's free Command Line Tools), wait for it to finish, then ask again. Stop there.
2. Build and install: run `bash "<this skill's base directory>/../../desktop/build.sh" --install`, using the base directory this skill was loaded from. It takes about a minute. It installs the app to `~/Applications/Buddy.app`, replacing an older Buddy but never another app, and starts it.
3. If the build fails, show the person the error lines and stop. Don't work around the script.
4. When it worked, tell the person briefly:
   - Buddy sits in the bottom-right corner of the screen. Click it to chat, drag it anywhere, right-click it for more.
   - The little tab at the screen edge hides and shows Buddy. `/buddy bye` quits it and `/buddy` brings it back.
   - The first time they ask Buddy to look at the screen, macOS asks for Screen Recording permission for Buddy (System Settings › Privacy & Security › Screen & System Audio Recording). After a rebuild, macOS may ask again.

## On a Windows PC

It needs Windows 10 or 11. Nothing has to be installed first: the build uses the C# compiler that is part of Windows.

1. Build and install: run `powershell -NoProfile -ExecutionPolicy Bypass -File "<this skill's base directory>/../../desktop-windows/build.ps1" -Install`, using the base directory this skill was loaded from (forward or backward slashes both work). It takes a few seconds. It installs the app to `%LOCALAPPDATA%\Buddy\Buddy.exe`, replacing an older Buddy but never another program, and starts it.
2. If the build fails, show the person the error lines and stop. Don't work around the script.
3. When it worked, tell the person briefly:
   - Buddy sits in the bottom-right corner of the screen, above the taskbar. Click it to chat, drag it anywhere, right-click it for more.
   - The little tab at the screen edge hides and shows Buddy. `/buddy bye` quits it and `/buddy` brings it back.
   - Say "look" in the chat, or press the eye, and Buddy describes the screen. Windows doesn't ask for a permission first.

## On anything else

There is no desktop pet for this computer yet. Tell the person that `/buddy panel` opens Buddy in a side panel inside Claude, where it shows what Claude is doing and chats the same way. Stop there.
