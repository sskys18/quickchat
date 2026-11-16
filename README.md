# QuickChat

Option+Space shows a small floating ChatGPT window, rendered by your own Brave with the session you are already signed in to. Press it again, press Escape, or click elsewhere to hide it. The conversation and any unsent text stay as they were.

## How it works

- QuickChat opens one ChatGPT tab in its own hidden Brave window and keeps it loaded, so it never sits among your tabs. It only ever acts on that tab, which it identifies by the id Brave returned when the tab was created.
- Showing the overlay moves that page into a Brave always-on-top window (Document Picture-in-Picture). Hiding moves it back. Nothing is reloaded, so opening takes about a tenth of a second.
- No cookie, password or token leaves Brave. QuickChat writes one cookie, `codex_composer_mode=chat`, so ChatGPT opens in Chat. Other ChatGPT tabs in Brave will also open in Chat on their next load.
- Thinking effort is set to Instant in QuickChat's tab only. ChatGPT normally saves that choice to your account; QuickChat answers that one request itself, so your other tabs keep their setting.

## Requirements

- macOS 13 or later, Brave Browser.
- Brave must run with `--remote-debugging-address=127.0.0.1 --remote-debugging-port=9333`. If Brave is closed, QuickChat starts it that way. If Brave is running without the port, QuickChat says so and does not restart it: quit Brave yourself and press Option+Space again.
- Option+Space must be free. The ChatGPT desktop app uses the same shortcut; quit it or change its shortcut.

## Build and run

    ./build.sh
    open build/QuickChat.app

`swift test --scratch-path .build --filter LauncherTests` runs the tests.

A chat-bubble icon appears in the menu bar with Show or Hide, New Chat and Quit. Quitting closes QuickChat's tab.

## Start at login

QuickChat registers itself as a login item the first time it runs. To stop that, turn it off under System Settings, General, Login Items. Keep `build/QuickChat.app` where it is; the login item points at that path.

## The tab in Brave

QuickChat's ChatGPT tab lives alone in a hidden Brave window: not in your tab strips, the Dock or Stage Manager (Brave's Window menu still lists it). Closing it is harmless: QuickChat opens a new one within a few seconds. The window is named `QuickChat ChatGPT`; before opening its window, QuickChat closes every Brave window with that name, so windows Brave restores on reopening never pile up. If ChatGPT is signed out, sign in in that window and press Option+Space again.

A fully hidden tab (no window at all) was tried: Brave refuses to open the overlay window from one, so it cannot be used.

## Known limits

- The overlay has Brave's own small title bar.
- For a few seconds after QuickChat's tab loads, thinking effort can still show your account's setting before QuickChat puts it back to Instant. Opening the overlay waits for Instant.
- While the overlay is open, Brave is the active app. On Escape or Option+Space, focus returns to the app you were in.

Test records are in `evidence/mac-chatgpt-launcher/` (not committed).
