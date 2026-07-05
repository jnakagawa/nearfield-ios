import SwiftUI

// Hum-phase status screen. The §14 interference-topography visual replaces
// this as the main screen in the Piece phase; keep this monochrome and quiet.
struct ContentView: View {
    @EnvironmentObject var hub: HubClient
    @EnvironmentObject var voice: VoiceEngine
    @State private var muted = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("NEARFIELD")
                .font(.system(size: 22, weight: .semibold))
                .tracking(6)

            Group {
                switch hub.state {
                case .idle:
                    Text("not connected").foregroundStyle(.secondary)
                case .connecting:
                    Text("connecting…").foregroundStyle(.secondary)
                case .connected:
                    Text("joined — waiting for assignment").foregroundStyle(.secondary)
                case .assigned:
                    assignmentView
                case .failed(let reason):
                    Text("reconnecting… (\(reason))")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(minHeight: 120)

            Spacer()

            if case .assigned = hub.state {
                Button(muted ? "UNMUTE" : "MUTE") {
                    muted.toggle()
                    voice.setMuted(muted)
                }
                .font(.system(size: 15, weight: .medium))
                .tracking(3)
                .padding(.vertical, 14).padding(.horizontal, 44)
                .overlay(Capsule().stroke(.primary, lineWidth: 1))
            } else {
                VStack(spacing: 10) {
                    TextField("hub host:port", text: $hub.host)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(maxWidth: 260)
                    Button("JOIN") { hub.connect() }
                        .font(.system(size: 15, weight: .medium))
                        .tracking(3)
                        .padding(.vertical, 12).padding(.horizontal, 40)
                        .overlay(Capsule().stroke(.primary, lineWidth: 1))
                }
            }

            Spacer().frame(height: 40)
        }
        .padding()
        .onChange(of: hub.assignment?.participantId) { _ in
            startVoiceIfAssigned()
        }
        .onAppear {
            hub.connect() // silent auto-(re)join; hub keys assignments by device_id
        }
    }

    private var assignmentView: some View {
        VStack(spacing: 8) {
            if let a = hub.assignment {
                Text(a.role.uppercased())
                    .font(.system(size: 13, weight: .medium)).tracking(4)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f Hz", a.pitchHz))
                    .font(.system(size: 34, weight: .light, design: .rounded))
                Text("participant #\(a.participantId) · degree \(a.degreeIndex) · performance \(a.performanceId)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func startVoiceIfAssigned() {
        guard let a = hub.assignment else { return }
        voice.setVoice(pitchHz: a.pitchHz, scale: a.scale, params: a.params, role: a.role)
        do { try voice.start() } catch {
            print("voice start failed: \(error)")
        }
    }
}
