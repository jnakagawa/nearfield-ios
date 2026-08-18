import SwiftUI

@main
struct EnsembleApp: App {
    @StateObject private var hub = HubClient()
    @StateObject private var voice = VoiceEngine()
    @StateObject private var conductor = Conductor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(hub)
                .environmentObject(voice)
                .environmentObject(conductor)
                .preferredColorScheme(.dark)
        }
    }
}
