// QuickChat: Option+Space shows a floating ChatGPT window rendered by the owner's own Brave session.
import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var terminationSignal: DispatchSourceSignal?
    private var busy = false
    private var shuttingDown = false

    func applicationDidFinishLaunching(_ note: Notification) {
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            log("QuickChat is already running")
            exit(0)
        }
        guard registerHotKey() else {
            report(LauncherError("⌥Space is taken by another app. Free that shortcut, then start QuickChat again."))
            exit(1)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "QuickChat")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show or Hide (⌥Space)", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit QuickChat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        registerLoginItem()

        // `kill` and logout go through the same shutdown as Quit, so the ChatGPT tab is closed.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // terminate(_:) waits in a nested run loop for the shutdown task, which runs on the main queue. Called from
        // inside a main-queue block it would wait forever, so it is handed to the run loop instead.
        source.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
        source.resume()
        terminationSignal = source

        // Have ChatGPT loaded before the first press, now or as soon as Brave is up. This never starts Brave.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [overlay] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == BraveEndpoint.bundleId else { return }
            Task { await overlay.preload(waitingUpTo: 30) }
        }
        Task { await overlay.preload(waitingUpTo: 0) }
    }

    /// Opening QuickChat again while it runs does the same as the shortcut.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        toggle()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shuttingDown { return .terminateLater }
        shuttingDown = true
        Task {
            await overlay.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func toggle() {
        run { try await self.overlay.toggle() }
    }

    @objc func newChat() {
        run { try await self.overlay.newChat() }
    }

    /// One action at a time; presses that arrive while one is in flight are dropped.
    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy, !shuttingDown else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        log("error: \(error)")
        let alert = NSAlert()
        alert.messageText = "QuickChat"
        alert.informativeText = "\(error)"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func registerHotKey() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x5143_4854), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        log("⌥Space registration status \(status)")
        return status == noErr
    }

    /// Starts QuickChat at Mac login. macOS lists it under System Settings, General, Login Items.
    private func registerLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status != .enabled { try service.register() }
            log("login item status \(service.status.rawValue)")
        } catch {
            log("login item registration failed: \(error)")
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
