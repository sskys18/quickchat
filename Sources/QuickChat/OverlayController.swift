// Shows and hides the floating ChatGPT overlay and keeps the one ChatGPT tab behind it loaded.
import AppKit

@MainActor
final class OverlayController {
    private var page: BravePage?
    private var preparing: Task<BravePage, Error>?
    private var stopped = false
    /// The app the owner was in when the overlay was shown; it gets focus back when the overlay is dismissed.
    private var previousApp: NSRunningApplication?

    /// Loads ChatGPT ahead of the first press so opening is immediate. Never starts Brave: it waits up to
    /// `seconds` for Brave's debugging endpoint and does nothing if it does not appear.
    func preload(waitingUpTo seconds: Int) async {
        for remaining in stride(from: seconds, through: 0, by: -1) {
            if stopped { return }
            if await BraveEndpoint.isReachable() {
                do { _ = try await readyPage() } catch { log("preload: \(error)") }
                return
            }
            if remaining > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
    }

    func toggle() async throws {
        // Hiding must work whatever state the page is in, so it comes before any readiness check.
        if let page, !page.isClosed, try await page.evaluate(PageScripts.hideIfShown) as? Bool == true { return }
        try await BraveEndpoint.ensureAvailable()
        try await show(on: try await readyPage())
    }

    /// Starts a new conversation with ChatGPT's own control, then shows the overlay if it is hidden.
    func newChat() async throws {
        try await BraveEndpoint.ensureAvailable()
        let page = try await readyPage()
        _ = try await page.evaluate(PageScripts.newChat)
        try await show(on: page)
    }

    /// Closes the tab QuickChat created, including one that is still being created. Called when the launcher quits.
    /// A window Brave does not confirm closed is found by its name and closed on the next start.
    func shutdown() async {
        stopped = true
        let creating = preparing
        let current = page
        page = nil
        _ = await current?.close()
        // A creation in flight sees `stopped` and closes its own tab; wait for it so nothing is left behind.
        _ = try? await creating?.value
    }

    private func show(on page: BravePage) async throws {
        // Typing needs Brave to be the active app; the overlay window itself already floats above other apps.
        // Brave is activated before the overlay opens so the overlay gets keyboard focus as it appears.
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.bundleIdentifier == BraveEndpoint.bundleId ? nil : frontmost
        NSRunningApplication.runningApplications(withBundleIdentifier: BraveEndpoint.bundleId).first?.activate()
        let started = Date()
        do {
            guard try await page.evaluate(PageScripts.show) as? String == "shown" else {
                throw LauncherError("ChatGPT page did not show the overlay.")
            }
        } catch {
            // If the page already reported the overlay hidden, focus has been handed back and this is nil.
            previousApp?.activate()
            previousApp = nil
            throw error
        }
        log("overlay shown in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    private func overlayHidden(_ reason: HideReason) {
        log("overlay hidden (\(reason.rawValue))")
        let app = previousApp
        previousApp = nil
        guard reason.restoresPreviousApp,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == BraveEndpoint.bundleId
        else { return }
        app?.activate()
    }

    /// The launcher's tab, loaded, signed in, in Chat mode with Instant effort.
    private func readyPage() async throws -> BravePage {
        let page = try await ownedPage()
        for _ in 0..<120 {
            let state: PageState
            do {
                state = PageState(reported: try await page.evaluate(PageScripts.prepare))
            } catch {
                // A navigation in flight makes one evaluation fail; a closed connection will not recover.
                if page.isClosed { throw error }
                state = .loading
            }
            switch state {
            case .ready: return page
            case .signIn: throw LauncherError.signInNeeded
            case .loading: try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw LauncherError("ChatGPT did not finish loading in Brave.")
    }

    private func ownedPage() async throws -> BravePage {
        if stopped { throw LauncherError("QuickChat is quitting.") }
        if let page, !page.isClosed { return page }
        let creation = preparing ?? Task { try await createAndAdopt() }
        preparing = creation
        let adopted = try await creation.value
        // Every caller that waited on the same creation checks again: the launcher may have begun quitting, or the
        // tab may have been lost, while it waited.
        if stopped || adopted.isClosed { throw LauncherError("The ChatGPT tab is no longer available.") }
        return adopted
    }

    /// Creates the tab and takes ownership of it, or closes it if it cannot be used.
    private func createAndAdopt() async throws -> BravePage {
        defer { preparing = nil }
        let created = try await BravePage.create()
        if stopped || created.isClosed {
            _ = await created.close()
            throw LauncherError("The ChatGPT tab was closed while it was loading.")
        }
        log("created tab \(created.targetId)")
        created.onGone = { [weak self, weak created] in
            guard let self, let created, self.page === created else { return }
            log("lost tab \(created.targetId)")
            self.page = nil
            self.previousApp = nil
            Task {
                // The connection can drop while the tab lives on. Only open another once Brave confirms this one
                // is gone; otherwise its named window is closed before the next tab is created.
                guard await created.close() else { return }
                // Reload right away while Brave is still there, so the next press does not wait for it.
                await self.preload(waitingUpTo: 0)
            }
        }
        created.onHidden = { [weak self] reason in self?.overlayHidden(reason) }
        page = created
        return created
    }
}
