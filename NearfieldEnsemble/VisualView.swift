import SwiftUI
import WebKit

// §14.3: the interference-topography shader runs in a WKWebView visual layer;
// sound never routes through it. The Conductor pushes state at 5 Hz; the JS
// side smooths per frame and drifts fringes at the audible beat rate.
final class VisualBridge: NSObject, ObservableObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    private var initialized = false
    private var pendingInit: String?
    private var pageLoaded = false

    func initialize(seedString: String, ink: Double = 1) {
        let js = "nf.init({seedString: '\(seedString)', ink: \(ink)});"
        if pageLoaded {
            webView?.evaluateJavaScript(js)
            initialized = true
        } else {
            pendingInit = js // page still loading; fire in didFinish
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        if let js = pendingInit {
            webView.evaluateJavaScript(js)
            initialized = true
            pendingInit = nil
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
