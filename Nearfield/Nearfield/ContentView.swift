import SwiftUI
import WebKit
import NearbyInteraction
import MultipeerConnectivity
import CoreMotion

struct ContentView: View {
    @StateObject private var proximityManager = ProximityManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            WebViewContainer(proximityManager: proximityManager)
                .ignoresSafeArea()
        }
        .onAppear {
            proximityManager.start()
        }
    }
}

// MARK: - Peer Data with Direction
struct PeerData: Codable {
    var distance: Float
    var directionX: Float
    var directionY: Float
    var directionZ: Float
    var horizontalAngle: Float
}

// MARK: - WebView Container
struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var proximityManager: ProximityManager

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        config.userContentController.add(context.coordinator, name: "nativeHandler")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        if let htmlPath = Bundle.main.path(forResource: "nearfield", ofType: "html") {
            let htmlUrl = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlUrl, allowingReadAccessTo: htmlUrl.deletingLastPathComponent())
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Convert peers dictionary to JSON
        let peersJSON: String
        if let jsonData = try? JSONEncoder().encode(proximityManager.peersData),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            peersJSON = jsonString
        } else {
            peersJSON = "{}"
        }

        // Pass all data including tilt
        let js = """
        updateNativeData({
            nearestDistance: \(proximityManager.nearestDistance),
            peerCount: \(proximityManager.peerCount),
            peers: \(peersJSON),
            tiltX: \(proximityManager.tiltX),
            tiltY: \(proximityManager.tiltY)
        });
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: WebViewContainer
        weak var webView: WKWebView?

        init(_ parent: WebViewContainer) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] {
                print("Message from web: \(body)")
            }
        }
    }
}

// MARK: - Proximity Manager with Direction + Tilt
class ProximityManager: NSObject, ObservableObject {
    @Published var nearestDistance: Float = -1
    @Published var peerCount: Int = 0
    @Published var peersData: [String: PeerData] = [:]

    // Tilt data for detune
    @Published var tiltX: Float = 0
    @Published var tiltY: Float = 0

    private var niSession: NISession?
    private var mcSession: MCSession?
    private var mcAdvertiser: MCNearbyServiceAdvertiser?
    private var mcBrowser: MCNearbyServiceBrowser?
    private var peerID: MCPeerID!

    private let serviceType = "nearfield"  // Max 15 chars for Bonjour

    private var peerTokens: [MCPeerID: NIDiscoveryToken] = [:]
    private var tokenToPeer: [Data: MCPeerID] = [:]  // Map token data to peer

    // Motion manager for tilt
    private let motionManager = CMMotionManager()

    override init() {
        super.init()
        peerID = MCPeerID(displayName: UIDevice.current.name)
    }

    func start() {
        startMotionUpdates()

        guard NISession.isSupported else {
            print("Nearby Interaction not supported on this device")
            return
        }

        niSession = NISession()
        niSession?.delegate = self

        mcSession = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        mcSession?.delegate = self

        mcAdvertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        mcAdvertiser?.delegate = self
        mcAdvertiser?.startAdvertisingPeer()

        mcBrowser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        mcBrowser?.delegate = self
        mcBrowser?.startBrowsingForPeers()

        print("Proximity manager started")
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            print("Device motion not available")
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0  // 30 Hz
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let motion = motion, let self = self else { return }

            // Get device attitude (tilt)
            // Roll: side-to-side tilt, Pitch: forward-back tilt
            self.tiltX = Float(motion.attitude.roll)   // -π to π
            self.tiltY = Float(motion.attitude.pitch)  // -π/2 to π/2
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        niSession?.invalidate()
        mcAdvertiser?.stopAdvertisingPeer()
        mcBrowser?.stopBrowsingForPeers()
        mcSession?.disconnect()
    }

    private func shareDiscoveryToken(with peer: MCPeerID) {
        guard let token = niSession?.discoveryToken else { return }

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            try mcSession?.send(data, toPeers: [peer], with: .reliable)
            print("Sent discovery token to \(peer.displayName)")
        } catch {
            print("Failed to send discovery token: \(error)")
        }
    }

    private func updateNearestDistance() {
        if peersData.isEmpty {
            nearestDistance = -1
            peerCount = 0
        } else {
            nearestDistance = peersData.values.map { $0.distance }.min() ?? -1
            peerCount = peersData.count
        }
    }
}

// MARK: - NISessionDelegate
extension ProximityManager: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        for object in nearbyObjects {
            // Find which peer this object belongs to
            for (peer, token) in peerTokens {
                // Match by comparing discovery tokens
                if let tokenData = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true),
                   let objectTokenData = try? NSKeyedArchiver.archivedData(withRootObject: object.discoveryToken, requiringSecureCoding: true),
                   tokenData == objectTokenData {

                    let distance = object.distance ?? -1
                    let direction = object.direction ?? simd_float3(0, 0, 0)

                    // Get horizontal angle if available (iOS 16+)
                    var horizontalAngle: Float = 0
                    if #available(iOS 16.0, *) {
                        horizontalAngle = object.horizontalAngle ?? 0
                    }

                    DispatchQueue.main.async {
                        self.peersData[peer.displayName] = PeerData(
                            distance: distance,
                            directionX: direction.x,
                            directionY: direction.y,
                            directionZ: direction.z,
                            horizontalAngle: horizontalAngle
                        )
                        self.updateNearestDistance()
                    }
                    break
                }
            }
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        for object in nearbyObjects {
            for (peer, token) in peerTokens {
                if let tokenData = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true),
                   let objectTokenData = try? NSKeyedArchiver.archivedData(withRootObject: object.discoveryToken, requiringSecureCoding: true),
                   tokenData == objectTokenData {
                    DispatchQueue.main.async {
                        self.peersData.removeValue(forKey: peer.displayName)
                        self.updateNearestDistance()
                    }
                    break
                }
            }
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        print("NI Session suspended")
    }

    func sessionSuspensionEnded(_ session: NISession) {
        print("NI Session resumed")
        for (_, token) in peerTokens {
            let config = NINearbyPeerConfiguration(peerToken: token)
            session.run(config)
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        print("NI Session invalidated: \(error)")
    }
}

// MARK: - MCSessionDelegate
extension ProximityManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            print("Connected to \(peerID.displayName)")
            shareDiscoveryToken(with: peerID)
        case .notConnected:
            print("Disconnected from \(peerID.displayName)")
            DispatchQueue.main.async {
                self.peersData.removeValue(forKey: peerID.displayName)
                self.peerTokens.removeValue(forKey: peerID)
                self.updateNearestDistance()
            }
        case .connecting:
            print("Connecting to \(peerID.displayName)")
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            if let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) {
                peerTokens[peerID] = token

                let config = NINearbyPeerConfiguration(peerToken: token)
                niSession?.run(config)

                print("Configured NI with \(peerID.displayName)")
            }
        } catch {
            print("Failed to decode discovery token: \(error)")
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension ProximityManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, mcSession)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension ProximityManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("Found peer: \(peerID.displayName)")
        browser.invitePeer(peerID, to: mcSession!, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("Lost peer: \(peerID.displayName)")
    }
}

#Preview {
    ContentView()
}
