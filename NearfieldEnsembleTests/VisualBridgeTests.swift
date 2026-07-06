import XCTest
import WebKit
@testable import NearfieldEnsemble

private final class RecordingWebView: WKWebView {
    var scripts: [String] = []
    override func evaluateJavaScript(_ javaScriptString: String,
                                     completionHandler: ((Any?, Error?) -> Void)? = nil) {
        scripts.append(javaScriptString)
    }
}

final class VisualBridgeTests: XCTestCase {
    // A hub switch (debug-panel REJOIN) unmounts the VisualView and hands the
    // bridge a NEW webview loading a fresh page. The init must wait for that
    // page and then re-fire — regression: blank field after switching hubs.
    @MainActor
    func testInitReappliesAfterWebViewSwap() {
        let bridge = VisualBridge()
        let a = RecordingWebView(frame: .zero)
        bridge.webView = a
        bridge.webView(a, didFinish: nil)
        bridge.initialize(seedString: "1|100|visual")
        XCTAssertEqual(a.scripts.count, 1)
        XCTAssertTrue(a.scripts[0].contains("nf.init"))
        XCTAssertTrue(a.scripts[0].contains("1|100|visual"))

        let b = RecordingWebView(frame: .zero)
        bridge.webView = b // fresh page starts loading
        bridge.initialize(seedString: "1|200|visual") // conductor re-inits early
        XCTAssertTrue(b.scripts.isEmpty, "must not fire into a half-loaded page")
        bridge.webView(b, didFinish: nil)
        XCTAssertEqual(b.scripts.count, 1)
        XCTAssertTrue(b.scripts[0].contains("1|200|visual"))
    }

    // Pushes before the page is initialized must be dropped, not error.
    @MainActor
    func testPushDroppedUntilInitialized() {
        let bridge = VisualBridge()
        let a = RecordingWebView(frame: .zero)
        bridge.webView = a
        bridge.push(pitch: 220, cents: 0, gains: [1, 0, 0, 0], W: 0, fpAmp: 1,
                    breathPhase: 0, ratios: [1, 2.07, 3.2, 4.4], peers: [])
        XCTAssertTrue(a.scripts.isEmpty)
    }
}
