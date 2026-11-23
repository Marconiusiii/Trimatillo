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
	@StateObject private var saves = ProjectSaveQueue()
	@State private var savingError: String?
	@State private var closing = false
	@StateObject private var playback = ProjectPlayback()
	@State private var board: ProjectBoard?
	@State private var revision = 0
	@State private var preparedRevision: Int?
	@Environment(\.scenePhase) private var phase

	var body: some View {
		ProjectEditorView(project: $project, close: closeProject, playback: playback,
			board: $board, revision: $revision, preparedRevision: preparedRevision, saves: saves)
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
			.onChange(of: saves.failure) { _, failure in savingError = failure }
			.alert("Could Not Save Project", isPresented: Binding(get: { savingError != nil }, set: { if !$0 { savingError = nil } })) {
				Button("Retry") { saves.retry() }
				Button("Close Without Saving", role: .destructive) {
					saves.discardFailedSaves()
					playback.cancelPreparation()
					playback.pause()
					close()
				}
				Button("Cancel", role: .cancel) { }
			} message: { Text(savingError ?? "") }
			.disabled(closing)
			.accessibilityHidden(closing)
			.overlay {
				if closing { LoadingStatusView("Saving project") }
			}
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
		try saves.enqueue(updated, replacing: original)
		try await saves.flush()
		project = updated
	}

	private func closeProject() {
		playback.cancelPreparation()
		playback.pause()
		guard !closing else { return }
		if !saves.hasPendingSaves { close(); return }
		closing = true
		Task {
			do {
				try await saves.flush()
				close()
			} catch { savingError = error.localizedDescription }
			closing = false
		}
	}
}

enum ProjectTool: String, CaseIterable {
	case editor = "Editor"
	case captioner = "Captioner"
	case describer = "Describer"
	case voicer = "Voicer"
	case mixer = "Mixer"

	var symbol: String {
		switch self {
		case .editor: "film"
		case .captioner: "captions.bubble"
		case .describer: "mic"
		case .voicer: "waveform"
		case .mixer: "slider.horizontal.3"
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
