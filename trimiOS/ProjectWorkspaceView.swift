import SwiftUI

struct ProjectBoard: Identifiable {
	let id = UUID()
	let source: ProjectMediaSource
	let placement: ProjectPlacement?
	let session: CuttingBoardSession
}

struct ProjectWorkspaceView: View {
	@State var project: EditingProject
	let close: () -> Void
	@StateObject private var playback = ProjectPlayback()
	@State private var board: ProjectBoard?
	@State private var revision = 0
	@State private var preparedRevision: Int?
	@Environment(\.scenePhase) private var phase

	var body: some View {
		ProjectEditorView(project: $project, close: closeProject, playback: playback,
			board: $board, revision: $revision, preparedRevision: preparedRevision)
			.task(id: board == nil ? revision : nil) {
				guard board == nil else { return }
				let preparing = revision
				do {
					try await prepareNarration()
					try Task.checkCancellation()
					await playback.prepare(project)
				} catch {
					guard !Task.isCancelled else { return }
					playback.failPreparation(error)
				}
				if !Task.isCancelled { preparedRevision = preparing }
			}
			.onChange(of: phase) { _, phase in
				if phase != .active { playback.pause() }
			}
			.onDisappear { playback.pause() }
	}

	private func prepareNarration() async throws {
		let original = project
		guard var takes = original.audioDescriptions else { return }
		for index in takes.indices where takes[index].fit == .speed && takes[index].narrationLength == nil {
			let take = takes[index]
			let url = try ProjectStorage.recording(take.recording, project: original.id)
			let length = try await ClipSilenceTrimming.narrationLength(url: url, length: take.length.time)
			takes[index].narrationLength = ProjectTime(length)
		}
		try Task.checkCancellation()
		guard takes != original.audioDescriptions else { return }
		guard project == original else { throw ProjectFailure("The project changed while preparing narration. Reopen the project.") }
		var updated = original
		updated.audioDescriptions = takes
		try ProjectLibrary.save(updated, replacing: original)
		project = updated
	}

	private func closeProject() {
		playback.cancelPreparation()
		playback.pause()
		close()
	}
}

enum ProjectTool: String, CaseIterable {
	case editor = "Editor"
	case captioner = "Captioner"
	case describer = "Describer"

	var symbol: String {
		switch self {
		case .editor: "film"
		case .captioner: "captions.bubble"
		case .describer: "mic"
		}
	}
}

struct ProjectWorkspaceTabs<Content: View>: View {
	@Binding var selection: ProjectTool
	@Environment(\.horizontalSizeClass) private var sizeClass
	@ViewBuilder let content: () -> Content

	var body: some View {
		TabView(selection: $selection) {
			ForEach(ProjectTool.allCases, id: \.self) { tool in
				Tab(tool.rawValue, systemImage: tool.symbol, value: tool) {
					if selection == tool { content().environment(\.horizontalSizeClass, sizeClass) }
				}
			}
		}
		.tabViewStyle(.tabBarOnly)
		.environment(\.horizontalSizeClass, .compact)
	}
}
