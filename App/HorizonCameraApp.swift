import SwiftUI

@main struct HorizonCameraApp: App {
    @StateObject private var camera = CameraModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            CameraView(model: camera)
                .preferredColorScheme(.dark)
                .task { await camera.start() }
                .onChange(of: phase) { _, phase in
                    if phase == .active { Task { await camera.start() } }
                    else { camera.suspend() }
                }
        }
    }
}
