import SwiftUI
import WebKit

// §14.3: the interference-topography shader runs in a WKWebView visual layer;
// sound never routes through it. The Conductor pushes state at 5 Hz; the JS
// side smooths per frame and drifts fringes at the audible beat rate.
final class VisualBridge: NSObject, ObservableObject, WKNavigationDelegate {
    // A hub switch unmounts the VisualView, so a NEW webview (loading a fresh
    // page) can arrive at any time — reset the load state or we'd fire init
    // at a half-loaded page and never again (blank field after REJOIN).
    weak var webView: WKWebView? {
        didSet { if webView !== oldValue { pageLoaded = false; initialized = false } }
    }
    private var initialized = false
    private var initJS: String? // survives webview swaps; re-applied on load
    private var pageLoaded = false

    func initialize(seedString: String, ink: Double = 1) {
        initJS = "nf.init({seedString: '\(seedString)', ink: \(ink)});"
        if pageLoaded, let js = initJS {
            webView?.evaluateJavaScript(js)
            initialized = true
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        if let js = initJS {
            webView.evaluateJavaScript(js)
            initialized = true
        }
    }

    func push(pitch: Double, cents: Double, gains: [Double], W: Double,
              fpAmp: Double, breathPhase: Double, ratios: [Double],
              peers: [(id: Int, e: Double, freq: Double)]) {
        guard initialized else { return }
        let peersJson = peers.map { "{id:\($0.id),e:\($0.e),freq:\($0.freq)}" }.joined(separator: ",")
        let gainsJson = gains.map { String(format: "%.4f", $0) }.joined(separator: ",")
        let ratiosJson = ratios.map { String(format: "%.5f", $0) }.joined(separator: ",")
        let js = """
        nf.update({pitch:\(pitch),cents:\(String(format: "%.2f", cents)),gains:[\(gainsJson)],\
        W:\(String(format: "%.3f", W)),fpAmp:\(String(format: "%.3f", fpAmp)),\
        breathPhase:\(String(format: "%.3f", breathPhase)),ratios:[\(ratiosJson)],peers:[\(peersJson)]});
        """
        webView?.evaluateJavaScript(js)
    }
}

struct VisualView: UIViewRepresentable {
    @ObservedObject var bridge: VisualBridge

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = bridge
        if let url = Bundle.main.url(forResource: "visual", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        bridge.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
