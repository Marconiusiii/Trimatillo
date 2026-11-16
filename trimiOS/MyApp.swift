import SwiftUI

@main struct MyApp: App {
	@Environment(\.scenePhase) private var phase
	@State private var checkedStorage = false

	var body: some Scene {
		WindowGroup {
			ContentView()
				.task(id: phase) {
					guard phase == .active else { return }
					let defaults = UserDefaults.standard
					let requested = defaults.bool(forKey: ProjectStorage.clearRequestKey)
					guard requested || !checkedStorage else { return }
					do {
						try await ProjectStorage.clearTemporaryFiles()
						checkedStorage = true
						NotificationCenter.default.post(name: ProjectStorage.didClean, object: nil)
						if requested { defaults.set(false, forKey: ProjectStorage.clearRequestKey) }
					} catch {
						checkedStorage = false
					}
				}
		}
	}
}
