import Foundation
import UIKit

// WebSocket client for the hub (spec §6.1). Joins, receives the assignment
// (which carries every config the phone needs — it can free-run afterwards),
// and reconnects with backoff. Rejoining returns the same slot (hub keys by
// device_id).
@MainActor
final class HubClient: ObservableObject {
    enum State: Equatable {
        case idle, connecting, connected, assigned
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var assignment: AssignMessage?
    @Published var host: String = UserDefaults.standard.string(forKey: "hubHost") ?? "127.0.0.1:8770"

    private var task: URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 1
    private var shouldRun = false

    var deviceId: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }

    func connect() {
        UserDefaults.standard.set(host, forKey: "hubHost")
        shouldRun = true
        open()
    }

    func disconnect() {
        shouldRun = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    private func open() {
        guard shouldRun, let url = URL(string: "ws://\(host)") else {
            state = .failed("bad host")
            return
        }
        state = .connecting
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        sendJoin()
        receiveLoop()
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
                } else {
                    self?.state = .connected
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
        // dispatch on "type" cheaply before full decode
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
        state = .failed(reason)
        task = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 15)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if self.shouldRun { self.open() }
        }
    }
}
