import Combine
import UIKit

/// Keeps disk work off the input path without letting newer snapshots overtake older ones.
@MainActor final class ProjectSaveQueue: ObservableObject {
	@Published private(set) var failure: String?
	private struct Save {
		let next: EditingProject
		let previous: EditingProject
	}
	private var pending: [Save] = []
	var hasPendingSaves: Bool { !pending.isEmpty }
	private var worker: Task<Void, Never>?
	private var backgroundTask = UIBackgroundTaskIdentifier.invalid

	func enqueue(_ next: EditingProject, replacing previous: EditingProject) throws {
		if let failure { throw ProjectFailure(failure) }
		pending.append(Save(next: next, previous: previous))
		start()
	}

	func flush() async throws {
		while let worker { await worker.value }
		if let failure { throw ProjectFailure(failure) }
	}

	func discardFailedSaves() {
		guard worker == nil, failure != nil else { return }
		pending.removeAll()
		failure = nil
	}

	func retry() {
		failure = nil
		start()
	}

	private func start() {
		guard worker == nil, failure == nil, !pending.isEmpty else { return }
		backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save project") { [weak self] in
			Task { @MainActor in self?.endBackgroundTask() }
		}
		worker = Task {
			defer {
				worker = nil
				endBackgroundTask()
			}
			while let save = pending.first {
				do {
					try await Task.detached(priority: .userInitiated) {
						try ProjectLibrary.save(save.next, replacing: save.previous)
					}.value
					pending.removeFirst()
				} catch {
					failure = "Could not save the project. " + error.localizedDescription
					return
				}
			}
		}
	}

	private func endBackgroundTask() {
		guard backgroundTask != .invalid else { return }
		UIApplication.shared.endBackgroundTask(backgroundTask)
		backgroundTask = .invalid
	}
}
