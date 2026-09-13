import SwiftUI

@main struct HorizonCameraApp: App {
    @StateObject private var camera = CameraModel()
    @Environment(\.scenePhase) private var phase
    private var runningTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
    var body: some Scene {
        WindowGroup {
            CameraView(model: camera)
                .task { if !runningTests { await camera.start() } }
                .onChange(of: phase) { _, phase in
                    guard !runningTests else { return }
                    if phase == .active { Task { await camera.start() } }
                    else { camera.suspend() }
                }
        }
    }
}
