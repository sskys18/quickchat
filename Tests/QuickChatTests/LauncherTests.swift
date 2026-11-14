import XCTest
@testable import QuickChat

final class LauncherTests: XCTestCase {
    func testBrowserSocketIsAcceptedOnlyOnTheLoopbackDebuggingPort() throws {
        let good = "ws://127.0.0.1:9333/devtools/browser/abc"
        XCTAssertEqual(try BraveEndpoint.validatedSocketURL(good).absoluteString, good)
        for bad in [
            "ws://127.0.0.1:9222/devtools/browser/abc",  // another port
            "ws://localhost:9333/devtools/browser/abc",  // a name that could resolve elsewhere
            "ws://192.168.0.5:9333/devtools/browser/abc",  // another machine
            "wss://127.0.0.1:9333/devtools/browser/abc",  // unexpected scheme
            "http://127.0.0.1:9333/json/version",
            "ws://127.0.0.1.evil.example:9333/x",
            "",
        ] {
            XCTAssertThrowsError(try BraveEndpoint.validatedSocketURL(bad), bad)
        }
    }

    func testPageSocketIsBuiltOnlyFromAHexTabId() throws {
        XCTAssertEqual(
            try BraveEndpoint.pageSocketURL(targetId: "9CB3181713506236F2DE6CBFCD857D95").absoluteString,
            "ws://127.0.0.1:9333/devtools/page/9CB3181713506236F2DE6CBFCD857D95")
        for bad in ["", "../browser/x", "ABC@evil.example/x", "AB CD", "AB/CD"] {
            XCTAssertThrowsError(try BraveEndpoint.pageSocketURL(targetId: bad), bad)
        }
    }

    func testOnlyTheAccountEffortSaveIsAnsweredLocally() {
        let save = "https://chatgpt.com/backend-api/settings/user_last_used_model_config"
        XCTAssertTrue(BraveEndpoint.isAccountSave(method: "PATCH", url: save))
        XCTAssertTrue(BraveEndpoint.isAccountSave(method: "PATCH", url: save + "?x=1"))
        XCTAssertTrue(BraveEndpoint.isAccountSave(method: "PATCH", url: "https://chatgpt.com:443/backend-api/settings/user_last_used_model_config"))
        // Reading the setting, or any other method, must reach the server.
        for method in ["GET", "OPTIONS", "POST", "patch", ""] {
            XCTAssertFalse(BraveEndpoint.isAccountSave(method: method, url: save), method)
        }
        for other in [
            "http://chatgpt.com/backend-api/settings/user_last_used_model_config",
            "https://chatgpt.com:8443/backend-api/settings/user_last_used_model_config",  // another origin
            "https://chatgpt.com/backend-api/conversation",
            "https://chatgpt.com/backend-api/settings/user",
            "https://chatgpt.com/backend-api/settings/user_last_used_model_config/extra",
            "https://example.com/backend-api/settings/user_last_used_model_config",
            "https://chatgpt.com.evil.example/backend-api/settings/user_last_used_model_config",
            "not a url",
        ] {
            XCTAssertFalse(BraveEndpoint.isAccountSave(method: "PATCH", url: other), other)
        }
    }

    func testUnexpectedPageReportsCountAsLoading() {
        XCTAssertEqual(PageState(reported: "ready"), .ready)
        XCTAssertEqual(PageState(reported: "signin"), .signIn)
        XCTAssertEqual(PageState(reported: "loading"), .loading)
        XCTAssertEqual(PageState(reported: nil), .loading)
        XCTAssertEqual(PageState(reported: true), .loading)
        XCTAssertEqual(PageState(reported: "Ready"), .loading)
    }

    func testFocusReturnsToThePreviousAppExceptAfterAClickAway() {
        XCTAssertTrue(HideReason.escape.restoresPreviousApp)
        XCTAssertTrue(HideReason.toggle.restoresPreviousApp)
        XCTAssertTrue(HideReason.closed.restoresPreviousApp)
        XCTAssertFalse(HideReason.blur.restoresPreviousApp)
        XCTAssertNil(HideReason(rawValue: "anything else"))
    }
}
