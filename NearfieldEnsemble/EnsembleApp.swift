import SwiftUI

@main
struct EnsembleApp: App {
    @StateObject private var hub = HubClient()
    @StateObject private var voice = VoiceEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(hub)
                .environmentObject(voice)
                .preferredColorScheme(.dark)
        }
    }
}
