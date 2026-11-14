import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

private struct ProjectBoard: Identifiable {
	let id = UUID()
	let source: ProjectMediaSource
	let placement: ProjectPlacement?
	let session: CuttingBoardSession
}

struct ProjectEditorView: View {
	@State var project: EditingProject
	let close: () -> Void
	@StateObject private var playback = ProjectPlayback()
	@State private var expanded = true
	@State private var board: ProjectBoard?
	@State private var pickingFile = false
	@State private var pickingPhoto = false
	@State private var photo: PhotosPickerItem?
	@State private var reconnect: UUID?
	@State private var busy = false
	@State private var revision = 0
	@State private var undo: [EditingProject] = []
	@State private var redo: [EditingProject] = []
	@State private var error: String?
	@State private var jumping = false
	@State private var jumpText = ""
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@AccessibilityFocusState private var focus: String?
	@State private var trigger: String?
	@Environment(\.scenePhase) private var phase

	var body: some View {
		NavigationStack {
			List {
				if project.placements.contains(where: { $0.track == .video }) {
					ProjectPreview(player: playback.player)
						.aspectRatio(CGFloat(project.picture?.width ?? 16) / CGFloat(project.picture?.height ?? 9), contentMode: .fit)
						.frame(maxHeight: 260)
						.accessibilityHidden(true)
				}
				transport
				DisclosureGroup("Project Media", isExpanded: $expanded) {
					sourcePicker("Import Clip", source: nil)
					ForEach(project.sources) { source in
						Menu(source.name) {
							Button("Open Cutting Board") { openBoard(source, placement: nil) }
							Button("Reconnect from Files") { pick(source.id, files: true) }
							Button("Reconnect from Photos") { pick(source.id, files: false) }
						}
						.accessibilityFocused($focus, equals: source.id.uuidString)
					}
				}
				ForEach(ProjectTrack.allCases, id: \.self) { track in
					Section {
						let clips = project.clips(on: track)
						if clips.isEmpty { Text("No clips") }
						else {
							ScrollView(.horizontal) {
								HStack {
									ForEach(clips) { clip in
										if let source = project.sources.first(where: { $0.id == clip.sourceID }) {
											Menu(source.name) {
												clipActions(clip, source: source)
											}
											.buttonStyle(.bordered)
											.accessibilityValue("Start " + time(clip.start.time) + ", duration " + time(clip.duration))
											.accessibilityActions { clipActions(clip, source: source) }
											.accessibilityFocused($focus, equals: clip.id.uuidString)
										}
									}
								}
							}
						}
					} header: { Text(track.rawValue + " Track").accessibilityAddTraits(.isHeader) }
				}
				if let seconds = project.targetSeconds { LabeledContent("Target Duration", value: time(CMTime(seconds: seconds, preferredTimescale: 60000))) }
				if busy { ProgressView("Opening clip") }
			}
			.disabled(busy)
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle(project.name)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Close") { playback.pause(); close() }.disabled(busy) }
			}
			.fileImporter(isPresented: $pickingFile, allowedContentTypes: [.movie, .audio]) { result in
				if case .success(let url) = result { importSource { try await ProjectMediaSource.file(url) } }
				else if case .failure(let problem) = result, (problem as NSError).code != NSUserCancelledError { error = "Could not open the file. Choose it again in Files." }
				focus = trigger
			}
			.photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .videos, photoLibrary: .shared())
			.onChange(of: pickingPhoto) { _, presented in if !presented { focus = trigger } }
			.onChange(of: pickingFile) { _, presented in if !presented { focus = trigger } }
			.onChange(of: photo) { _, item in
				guard let item else { return }
				photo = nil
				importSource {
					guard let id = item.itemIdentifier else { throw ProjectFailure("Choose the original video in Photo Library.") }
					return try await ProjectMediaSource.photo(id)
				}
			}
			.fullScreenCover(item: $board, onDismiss: { focus = trigger }) { editing in
				CuttingBoardKeyboard(session: editing.session, projectActions: boardActions(editing)) { board = nil }
			}
			.alert("Jump to Time", isPresented: $jumping) {
				TextField(format == .frames ? "Frame" : "Time", text: $jumpText)
				Button("Cancel", role: .cancel) { focus = "playhead" }
				Button("Jump") {
					if format == .frames, let index = Int32(jumpText), index >= 0 {
						playback.seek(CMTimeMultiply(project.frame, multiplier: index))
					} else if format != .frames, let time = CuttingBoardSession.parse(jumpText) { playback.seek(time) }
					else { error = "Enter a valid playhead position and choose Jump." }
					focus = "playhead"
				}
			}
			.alert("Project", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK") { error = nil }
			} message: { Text(error ?? "") }
		}
		.accessibilityAction(.magicTap) { playback.toggle() }
		.task(id: revision) { await playback.prepare(project) }
		.onChange(of: playback.failure) { _, message in
			if let message { error = message; playback.failure = nil }
		}
		.onChange(of: phase) { _, phase in if phase != .active { playback.pause() } }
		.onDisappear { playback.pause() }
	}

	private var transport: some View {
		Group {
			Button { playback.pause(); jumpText = ""; jumping = true } label: {
				LabeledContent("Playhead", value: time(playback.position))
			}
			.accessibilityFocused($focus, equals: "playhead")
			HStack {
				Button { playback.seek(playback.position - project.frame) } label: { Label("Step Back", systemImage: "backward.frame") }
					.keyboardShortcut(.leftArrow, modifiers: [])
				Button { playback.toggle() } label: { Label(playback.playing ? "Pause" : "Play", systemImage: playback.playing ? "pause.fill" : "play.fill") }
					.keyboardShortcut(.space, modifiers: []).disabled(!playback.ready)
				Button { playback.seek(playback.position + project.frame) } label: { Label("Step Forward", systemImage: "forward.frame") }
					.keyboardShortcut(.rightArrow, modifiers: [])
			}
			.labelStyle(.iconOnly)
			.controlSize(.large)
			.buttonStyle(.bordered)
			HStack {
				ForEach([true, false], id: \.self) { isIn in
					let point = isIn ? project.markIn : project.markOut
					Button(isIn ? "Mark In" : "Mark Out") {
						playback.pause()
						var next = project
						let value = point?.time == playback.position ? nil : ProjectTime(playback.position)
						if isIn { next.markIn = value } else { next.markOut = value }
						commit(next)
					}
					.accessibilityValue(point.map { time($0.time) } ?? "")
					.keyboardShortcut(isIn ? "i" : "o", modifiers: [])
					.disabled(project.placements.isEmpty)
				}
				Menu("Undo") {
					Button("Undo") { history(back: true) }.disabled(undo.isEmpty).keyboardShortcut("z")
					Button("Redo") { history(back: false) }.disabled(redo.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift])
				}.disabled(undo.isEmpty && redo.isEmpty)
			}.buttonStyle(.bordered)
		}
	}

	@ViewBuilder private func clipActions(_ clip: ProjectPlacement, source: ProjectMediaSource) -> some View {
		Button("Open Cutting Board") { openBoard(source, placement: clip) }
		Button("Go to Start") { playback.seek(clip.start.time) }
		Button("Go to End") { playback.seek(clip.end) }
		Button("Remove from Track") {
			var next = project
			next.placements.removeAll { $0.id == clip.id }
			commit(next)
		}
	}

	private func sourcePicker(_ title: String, source: UUID?) -> some View {
		Menu(title) {
			Button("Photo Library") { pick(source, files: false) }
			Button("Files") { pick(source, files: true) }
		}.accessibilityFocused($focus, equals: "import")
	}

	private func pick(_ id: UUID?, files: Bool) {
		playback.pause()
		reconnect = id
		trigger = id?.uuidString ?? "import"
		if files { pickingFile = true } else { pickingPhoto = true }
	}

	private func importSource(_ load: @escaping () async throws -> ProjectMediaSource) {
		let replacing = reconnect
		busy = true
		Task {
			defer { busy = false; focus = trigger }
			do {
				var source = try await load()
				var next = project
				if let replacing, let index = next.sources.firstIndex(where: { $0.id == replacing }) {
					let original = next.sources[index]
					guard original.duration.time == source.duration.time, (original.picture == nil) == (source.picture == nil),
						original.hasAudio == source.hasAudio else { throw ProjectFailure("Choose the original clip with the same duration and media type.") }
					source.id = replacing
					next.sources[index] = source
				} else { next.sources.append(source) }
				commit(next)
			} catch { self.error = error.localizedDescription }
		}
	}

	private func openBoard(_ source: ProjectMediaSource, placement: ProjectPlacement?) {
		playback.pause()
		trigger = (placement?.id ?? source.id).uuidString
		busy = true
		Task {
			defer { busy = false }
			do {
				let access = try await source.open()
				let session = try await CuttingBoardSession.openReferenced(asset: access.asset, title: source.name, access: access, ranges: placement?.ranges.map(\.range))
				board = ProjectBoard(source: source, placement: placement, session: session)
			} catch { self.error = "Could not open " + source.name + ". Reconnect the clip in Project Media." }
		}
	}

	private func boardActions(_ board: ProjectBoard) -> [BoardProjectAction] {
		if let clip = board.placement {
			return [BoardProjectAction(title: "Save Changes") { place(board, at: clip.start.time) }]
		}
		let track: ProjectTrack = board.source.picture == nil ? .audio : .video
		return [BoardProjectAction(title: "Append") { place(board, at: project.clips(on: track).last?.end ?? .zero) },
			BoardProjectAction(title: "Place at Playhead") { place(board, at: playback.position) }]
	}

	private func place(_ editing: ProjectBoard, at start: CMTime) {
		do {
			var next = project
			try next.place(editing.source, ranges: editing.session.state.timeline.sourceRanges, at: start, replacing: editing.placement?.id)
			try save(next)
			board = nil
		} catch { editing.session.message = error.localizedDescription }
	}

	private func commit(_ next: EditingProject) {
		do { try save(next) } catch { self.error = error.localizedDescription }
	}

	private func save(_ next: EditingProject) throws {
		var next = next
		if let point = next.markIn, point.time > next.duration { next.markIn = nil }
		if let point = next.markOut, point.time > next.duration { next.markOut = nil }
		try ProjectLibrary.save(next, replacing: project)
		undo.append(project)
		redo.removeAll()
		update(next)
	}

	private func history(back: Bool) {
		guard let next = back ? undo.last : redo.last else { return }
		do {
			try ProjectLibrary.save(next, replacing: project)
			if back { undo.removeLast(); redo.append(project) }
			else { redo.removeLast(); undo.append(project) }
			update(next)
		} catch { self.error = error.localizedDescription }
	}

	private func update(_ next: EditingProject) {
		let rebuild = project.placements != next.placements || project.sources != next.sources
		project = next
		if rebuild { revision += 1 }
	}

	private func time(_ value: CMTime) -> String {
		if format == .frames { return "Frame " + String(Int64((value.seconds / project.frame.seconds).rounded(.towardZero))) }
		let milliseconds = format == .milliseconds
		let scale: Int32 = milliseconds ? 1000 : 1
		let ticks = CMTimeConvertScale(value, timescale: scale, method: .roundTowardZero).value
		let seconds = ticks / Int64(scale)
		let clock = String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
		return milliseconds ? clock + String(format: ".%03lld", ticks % 1000) : clock
	}
}

private struct ProjectPreview: UIViewControllerRepresentable {
	let player: AVPlayer

	func makeUIViewController(context: Context) -> AVPlayerViewController {
		let controller = AVPlayerViewController()
		controller.showsPlaybackControls = false
		controller.player = player
		return controller
	}

	func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}
