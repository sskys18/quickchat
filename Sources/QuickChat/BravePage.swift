// The launcher's connection to the owner's running Brave: one fixed loopback debugging endpoint and one tab that
// QuickChat created itself. Nothing here reads cookies, lists other tabs, or acts on a tab it did not create.
import AppKit

struct LauncherError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }

    static let signInNeeded = LauncherError(
        "ChatGPT is signed out in Brave. Sign in at chatgpt.com in any Brave tab, then press ⌥Space again.")
}

/// Brave answered and refused the request, as opposed to not answering at all.
struct BraveRejected: Error, CustomStringConvertible {
    let description: String
}

func log(_ line: String) {
    let time = Date().formatted(date: .omitted, time: .standard)
    FileHandle.standardError.write(Data("\(time) \(line)\n".utf8))
}

enum BraveEndpoint {
    static let host = "127.0.0.1"
    static let port = 9333
    static let bundleId = "com.brave.Browser"
    /// ChatGPT saves the chosen thinking effort to the account through this request.
    static let accountSavePath = "/backend-api/settings/user_last_used_model_config"

    /// Refuses redirects, so discovery can never be sent to another host.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    /// The browser socket Brave reports must be on the fixed loopback endpoint.
    static func validatedSocketURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "ws", url.host == host, url.port == port else {
            throw LauncherError("Brave reported a debugging socket outside \(host):\(port); refusing to connect.")
        }
        return url
    }

    static func pageSocketURL(targetId: String) throws -> URL {
        guard !targetId.isEmpty, targetId.allSatisfy(\.isHexDigit) else {
            throw LauncherError("Brave returned an unexpected tab id; refusing to connect.")
        }
        return URL(string: "ws://\(host):\(port)/devtools/page/\(targetId)")!
    }

    static func isAccountSave(method: String, url urlText: String) -> Bool {
        guard method == "PATCH", let url = URL(string: urlText) else { return false }
        return url.scheme == "https" && url.host == "chatgpt.com" && (url.port ?? 443) == 443
            && url.path == accountSavePath
    }

    /// The browser socket. Its path carries an id that is new for every Brave process.
    static func browserSocketURL() async throws -> URL {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/json/version")!)
        request.timeoutInterval = 5
        let (data, _) = try await session.data(for: request)
        guard let version = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = version["webSocketDebuggerUrl"] as? String
        else { throw LauncherError("Brave's debugging endpoint returned no browser socket.") }
        return try validatedSocketURL(text)
    }

    static func isReachable() async -> Bool {
        (try? await browserSocketURL()) != nil
    }

    static var braveIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// Makes the endpoint available. Starts Brave only when it is not running; a running Brave is never restarted.
    static func ensureAvailable() async throws {
        if await isReachable() { return }
        if braveIsRunning {
            throw LauncherError(
                "Brave is running without its debugging port (\(host):\(port)). Quit Brave yourself, then press ⌥Space again and QuickChat will start it with the port.")
        }
        guard let brave = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw LauncherError("Brave Browser is not installed.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--remote-debugging-address=\(host)", "--remote-debugging-port=\(port)"]
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: brave, configuration: configuration)
        log("started Brave")
        for _ in 0..<60 {
            if await isReachable() { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LauncherError("Brave started but its debugging port (\(host):\(port)) did not come up.")
    }

    /// One browser-level call on its own short connection. Gives up after 5 seconds without an answer.
    /// Throws `BraveRejected` when Brave answers with an error.
    static func browserCall(_ method: String, _ params: [String: Any], on browser: URL) async throws -> [String: Any] {
        let socket = session.webSocketTask(with: browser)
        socket.resume()
        let deadline = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            deadline.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
        let body = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        try await socket.send(.string(String(decoding: body, as: UTF8.self)))
        while true {
            guard case .string(let text) = try await socket.receive(),
                  let reply = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  reply["id"] as? Int == 1
            else { continue }
            if let error = reply["error"] { throw BraveRejected(description: "\(method) failed: \(error)") }
            return reply["result"] as? [String: Any] ?? [:]
        }
    }
}

/// QuickChat's window in Brave, named so it can be found again. Brave saves a window's name with its session, so a
/// window that comes back when Brave reopens or restores after a crash still carries it and is closed before a new
/// one is made. Only windows carrying this exact name are ever closed by name.
enum OwnedTab {
    static let windowName = "QuickChat ChatGPT"

    /// Names the window the new tab lives alone in and hides it, so it is in no tab strip, the Dock or Stage
    /// Manager. Brave ignores minimize requests for this window, but a hidden window still opens the overlay.
    static func label(targetId: String, on browser: URL) async throws {
        let windowId = try await windowId(of: targetId, on: browser)
        try await runBrave("set given name of (every window whose id is \(windowId)) to \"\(windowName)\"")
        try await runBrave("set visible of (every window whose id is \(windowId)) to false")
    }

    /// Closes that exact tab by closing the window it lives alone in. Returns true when it is confirmed closed or
    /// confirmed not to exist.
    /// Closing the tab itself would make Brave (with "close window with last tab" off) leave a New Tab window behind,
    /// so the window is closed through Brave's scripting interface, which never does that.
    static func close(targetId: String, on browser: URL) async -> Bool {
        do {
            let windowId = try await windowId(of: targetId, on: browser)
            try await runBrave("close (every window whose id is \(windowId))")
            log("closed tab \(targetId)")
        } catch let rejected as BraveRejected where rejected.description.contains("No target with given id") {
            log("tab \(targetId) no longer exists")
        } catch {
            log("could not confirm tab \(targetId) is closed: \(error)")
            return false
        }
        return true
    }

    /// Closes every window QuickChat named: ones Brave restored on reopening and ones a previous QuickChat left.
    static func closeLeftovers() async throws {
        try await runBrave("close (every window whose given name is \"\(windowName)\")")
    }

    private static func windowId(of targetId: String, on browser: URL) async throws -> Int {
        let window = try await BraveEndpoint.browserCall("Browser.getWindowForTarget", ["targetId": targetId], on: browser)
        guard let windowId = window["windowId"] as? Int else { throw LauncherError("Brave reported no window for the tab.") }
        return windowId
    }

    /// Runs in `osascript` rather than in-process: QuickChat closes its window while quitting, inside AppKit's
    /// termination run loop, where an in-process Apple event does not complete.
    private static func runBrave(_ command: String) async throws {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = ["-e", "tell application id \"\(BraveEndpoint.bundleId)\" to \(command)"]
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            script.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try script.run() } catch { done.resume(throwing: error) }
        }
        if status != 0 { throw LauncherError("Brave did not run \"\(command)\" (osascript status \(status)).") }
    }
}

/// The long-lived connection to the tab QuickChat created. The tab is identified only by the id Brave returned
/// when it was created, never by URL or title.
@MainActor
final class BravePage {
    private static let callTimeoutSeconds: UInt64 = 20

    let targetId: String
    private let browser: URL
    private let socket: URLSessionWebSocketTask
    private var nextId = 0
    private var pending: [Int: (waiter: CheckedContinuation<[String: Any], Error>, deadline: Task<Void, Never>)] = [:]
    private(set) var isClosed = false
    private var closedByLauncher = false
    /// Called once when the connection is lost without the launcher closing it.
    var onGone: (() -> Void)?
    /// Called when the page reports that the overlay was hidden.
    var onHidden: ((HideReason) -> Void)?

    /// Creates the tab in its own hidden Brave window, away from the owner's tab strips, and loads ChatGPT in
    /// it, in Chat mode. A hidden tab would be invisible too, but Brave cannot open the overlay from one.
    static func create() async throws -> BravePage {
        let browser = try await BraveEndpoint.browserSocketURL()
        try await OwnedTab.closeLeftovers()
        let created = try await BraveEndpoint.browserCall(
            "Target.createTarget",
            ["url": "about:blank", "newWindow": true, "background": true, "windowState": "minimized"], on: browser)
        guard let targetId = created["targetId"] as? String else { throw LauncherError("Brave did not create a tab.") }
        let page: BravePage
        do {
            // An unnamed window could not be found again after Brave reopens, so it is not kept.
            try await OwnedTab.label(targetId: targetId, on: browser)
            page = BravePage(targetId: targetId, browser: browser, socketURL: try BraveEndpoint.pageSocketURL(targetId: targetId))
        } catch {
            _ = await OwnedTab.close(targetId: targetId, on: browser)
            throw error
        }
        do {
            // Instant is chosen in this tab only: the request that would save it to the account is answered here.
            _ = try await page.call("Fetch.enable", ["patterns": [["urlPattern": "*\(BraveEndpoint.accountSavePath)*"]]])
            _ = try await page.call("Runtime.enable", [:])
            _ = try await page.call("Runtime.addBinding", ["name": PageScripts.hiddenBinding])
            // The only cookie QuickChat ever writes. ChatGPT picks Chat or Work from it at load time.
            _ = try await page.call("Network.setCookie", [
                "url": "https://chatgpt.com/", "name": "codex_composer_mode", "value": "chat", "path": "/", "secure": true,
                "expires": Date().timeIntervalSince1970 + 31_536_000,
            ])
            _ = try await page.call("Page.navigate", ["url": "https://chatgpt.com/"])
        } catch {
            // The tab exists but nobody owns it yet; close it rather than leave it behind.
            _ = await page.close()
            throw error
        }
        return page
    }

    private init(targetId: String, browser: URL, socketURL: URL) {
        self.targetId = targetId
        self.browser = browser
        socket = BraveEndpoint.session.webSocketTask(with: socketURL)
        socket.resume()
        Task { await readLoop() }
    }

    private func readLoop() async {
        do {
            while true {
                guard case .string(let text) = try await socket.receive(),
                      let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                else { continue }
                if let id = message["id"] as? Int, let entry = pending.removeValue(forKey: id) {
                    entry.deadline.cancel()
                    if let error = message["error"] {
                        entry.waiter.resume(throwing: BraveRejected(description: "Brave rejected a request: \(error)"))
                    } else {
                        entry.waiter.resume(returning: message["result"] as? [String: Any] ?? [:])
                    }
                } else if let method = message["method"] as? String, let params = message["params"] as? [String: Any] {
                    handleEvent(method, params)
                }
            }
        } catch {
            isClosed = true
            for entry in pending.values {
                entry.deadline.cancel()
                entry.waiter.resume(throwing: error)
            }
            pending = [:]
            if !closedByLauncher { onGone?() }
        }
    }

    private func handleEvent(_ method: String, _ params: [String: Any]) {
        switch method {
        case "Fetch.requestPaused":
            guard let requestId = params["requestId"] as? String else { return }
            let request = params["request"] as? [String: Any]
            let isSave = BraveEndpoint.isAccountSave(
                method: request?["method"] as? String ?? "", url: request?["url"] as? String ?? "")
            Task {
                do {
                    if isSave {
                        _ = try await call("Fetch.fulfillRequest", [
                            "requestId": requestId, "responseCode": 200,
                            "responseHeaders": [["name": "content-type", "value": "application/json"]],
                            "body": Data("{}".utf8).base64EncodedString(),
                        ])
                    } else {
                        _ = try await call("Fetch.continueRequest", ["requestId": requestId])
                    }
                } catch {
                    // A request left paused would hang the page. Give the tab up; the launcher closes and replaces it.
                    log("could not answer a paused request: \(error)")
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
        case "Runtime.bindingCalled":
            guard params["name"] as? String == PageScripts.hiddenBinding,
                  let reason = (params["payload"] as? String).flatMap(HideReason.init(rawValue:))
            else { return }
            onHidden?(reason)
        default:
            break
        }
    }


    /// One call on the tab's connection. Fails after 20 seconds without an answer.
    func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if isClosed { throw LauncherError("The connection to the ChatGPT tab is closed.") }
        nextId += 1
        let id = nextId
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { waiter in
            let deadline = Task {
                try? await Task.sleep(nanoseconds: Self.callTimeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.pending.removeValue(forKey: id)?.waiter.resume(
                    throwing: LauncherError("Brave did not answer \(method) in \(Self.callTimeoutSeconds) seconds."))
            }
            pending[id] = (waiter, deadline)
            socket.send(.string(String(decoding: body, as: UTF8.self))) { error in
                guard let error else { return }
                Task { @MainActor in
                    guard let entry = self.pending.removeValue(forKey: id) else { return }
                    entry.deadline.cancel()
                    entry.waiter.resume(throwing: error)
                }
            }
        }
    }

    /// Runs a script in the tab as if the owner had acted (opening the overlay needs a user gesture).
    func evaluate(_ script: String) async throws -> Any? {
        let result = try await call(
            "Runtime.evaluate",
            ["expression": script, "userGesture": true, "awaitPromise": true, "returnByValue": true])
        if let details = result["exceptionDetails"] as? [String: Any] {
            let text = (details["exception"] as? [String: Any])?["description"] as? String ?? details["text"] as? String
            throw LauncherError("ChatGPT page error: \(text ?? "unknown")")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// Closes the tab QuickChat created. Returns true when Brave confirmed it is closed or does not exist.
    /// When it cannot be confirmed, its named window is closed the next time a tab is created.
    func close() async -> Bool {
        closedByLauncher = true
        socket.cancel(with: .normalClosure, reason: nil)
        return await OwnedTab.close(targetId: targetId, on: browser)
    }
}
