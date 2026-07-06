import SwiftUI

// Hum-phase status screen. The §14 interference-topography visual replaces
// this as the main screen in the Piece phase; keep this monochrome and quiet.
struct ContentView: View {
    @EnvironmentObject var hub: HubClient
    @EnvironmentObject var voice: VoiceEngine
    @EnvironmentObject var conductor: Conductor
    @StateObject private var visual = VisualBridge()
    @State private var muted = false
    @State private var chromeVisible = true

    var body: some View {
        ZStack {
            // §14: the interference topography IS the main screen
            if case .assigned = hub.state {
                VisualView(bridge: visual)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { chromeVisible.toggle() } }
            }
            if chromeVisible { chrome }
        }
        .onAppear { conductor.visual = visual }
    }

    private var chrome: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("NEARFIELD")
                .font(.system(size: 22, weight: .semibold))
                .tracking(6)
            Text("build hum-2")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

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
                if let label = conductor.scoreLabel {
                    Text("\(label) · \(Int(conductor.scoreT) / 60):\(String(format: "%02d", Int(conductor.scoreT) % 60))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(a.role.uppercased())
                    .font(.system(size: 13, weight: .medium)).tracking(4)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f Hz", a.pitchHz))
                    .font(.system(size: 34, weight: .light, design: .rounded))
                Text("participant #\(a.participantId) · degree \(a.degreeIndex) · performance \(a.performanceId)")
                    .font(.footnote).foregroundStyle(.secondary)
                let o = conductor.lastOut
                Text(String(format: "W %.2f · B %.2f · %@ · %+.1f¢",
                            o.W, o.B,
                            o.focusId.map { "focus #\($0)" } ?? "solo",
                            o.detuneCents + conductor.fpCents))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                DisclosureGroup("debug injection") {
                    Toggle("fake sensors", isOn: $conductor.debugEnabled)
                    HStack {
                        Text("peer RSSI").font(.footnote)
                        Slider(value: $conductor.debugPeerRssi, in: -95 ... -35)
                        Text("\(Int(conductor.debugPeerRssi))").font(.footnote.monospaced())
                    }
                    HStack {
                        Text("motion").font(.footnote)
                        Slider(value: $conductor.debugMotion, in: 0...1)
                        Text(String(format: "%.2f", conductor.debugMotion)).font(.footnote.monospaced())
                    }
                }
                .font(.footnote)
                .frame(maxWidth: 300)
                .padding(.top, 10)
            }
        }
    }

    private func startVoiceIfAssigned() {
        guard let a = hub.assignment else { return }
        voice.setVoice(pitchHz: a.pitchHz, scale: a.scale, params: a.params, role: a.role)
        do { try voice.start() } catch {
            print("voice start failed: \(error)")
        }
        conductor.start(assignment: a, voice: voice, hub: hub)
    }
}
