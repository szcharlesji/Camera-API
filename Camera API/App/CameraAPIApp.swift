import SwiftUI

@main
struct CameraAPIApp: App {
    @State private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(services)
                .task { services.start() }
                // A capture rig is watched, not read; the dark UI keeps stray
                // light off the scene and the preview honest.
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends AVCaptureSession in the background, so the app has to
            // stay foreground. Nothing is torn down here — the session recovers
            // on its own via the interruption notifications — but the transition
            // is worth surfacing to clients watching /events.
            if phase == .background {
                services.capture.stopSession()
            } else if phase == .active {
                services.capture.startSession()
            }
        }
    }
}
