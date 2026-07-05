import Foundation
import UIKit

// WebSocket client for the hub (spec §6.1). Joins after the socket reports
// open (URLSessionWebSocketDelegate — sending during the handshake races and
// can abort the connection on real-RTT links), receives the assignment (which
// carries every config the phone needs — it can free-run afterwards), and
// reconnects with backoff. Rejoining returns the same slot (hub keys by
// device_id).
@MainActor
final class HubClient: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, connecting, connected, assigned
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var assignment: AssignMessage?
    @Published var host: String = UserDefaults.standard.string(forKey: "hubHost") ?? "127.0.0.1:8770"

    private lazy var session: URLSession = URLSession(
        configuration: .default, delegate: SocketDelegate(client: self), delegateQueue: .main)
    private var task: URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 1
    private var shouldRun = false

    var deviceId: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }

    func connect() {
        UserDefaults.standard.set(host, forKey: "hubHost")
        shouldRun = true
        reconnectDelay = 1
        open()
    }

    func disconnect() {
        shouldRun = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    private func open() {
        // iOS keyboards love to sneak in spaces; be forgiving
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard shouldRun, !cleaned.isEmpty, let url = URL(string: "ws://\(cleaned)") else {
            state = .failed("bad host")
            return
        }
        state = .connecting
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop()
    }

    // called by the delegate once the handshake has actually completed
    func socketDidOpen() {
        state = .connected
        sendJoin()
    }

    func socketDidClose(_ reason: String) {
        handleDrop(reason)
    }

    private func sendJoin() {
        let join: [String: Any] = [
            "type": "join",
            "device_id": deviceId,
            "name": UIDevice.current.name,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: join),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.handleDrop("join failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.handleDrop(error.localizedDescription)
                case .success(let message):
                    if case .string(let text) = message, let data = text.data(using: .utf8) {
                        self.handle(data)
                    }
                    self.receiveLoop()
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "assign":
            if let assign = try? JSONDecoder().decode(AssignMessage.self, from: data) {
                assignment = assign
                state = .assigned
                reconnectDelay = 1
            }
        default:
            break // score_position / params_update arrive in later phases
        }
    }

    private func handleDrop(_ reason: String) {
        guard shouldRun else { return }
        if case .assigned = state { /* keep humming; free-run (spec §8) */ } else {
            state = .failed(reason)
        }
        task = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 15)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if self.shouldRun { self.open() }
        }
    }
}

// URLSession delegates are nonisolated; bounce socket lifecycle onto the actor.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
    weak var client: HubClient?
    init(client: HubClient) { self.client = client }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak client] in client?.socketDidOpen() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak client] in client?.socketDidClose("closed (\(closeCode.rawValue))") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            Task { @MainActor [weak client] in client?.socketDidClose(error.localizedDescription) }
        }
    }
}
