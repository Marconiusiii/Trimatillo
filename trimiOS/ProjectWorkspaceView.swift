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
				await playback.prepare(project)
				if !Task.isCancelled { preparedRevision = preparing }
			}
			.onChange(of: phase) { _, phase in
				if phase != .active { playback.pause() }
			}
			.onDisappear { playback.pause() }
	}

	private func closeProject() {
		playback.pause()
		close()
	}
}

enum ProjectTool: String, CaseIterable {
	case editor = "Editor"
	case captioner = "Captioner"

	var symbol: String { self == .editor ? "film" : "captions.bubble" }
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
