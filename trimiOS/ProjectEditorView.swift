import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

private struct HistoryEntry {
	let project: EditingProject
	let action: String
}

private enum ProjectSheet: Identifiable {
	case settings
	case export(ProjectExport)
	var id: String {
		switch self {
		case .settings: "settings"
		case .export: "export"
		}
	}
}

struct ProjectEditorView: View {
	@Binding var project: EditingProject
	let close: () -> Void
	@ObservedObject var playback: ProjectPlayback
	@Binding var board: ProjectBoard?
	@Binding var revision: Int
	let preparedRevision: Int?
	@State private var activeTrack = TimelineTrack.primaryVideo.id
	@State private var marked: Set<UUID> = []
	@State private var dropAnchor: UUID?
	@State private var dropAfter = false
	@State private var dragging: Set<UUID> = []
	@State private var effects: TimelineTrack?
	@FocusState private var keyboardClip: String?
	@State private var expanded = true
	@State private var pickingFile = false
	@State private var pickingPhoto = false
	@State private var photo: PhotosPickerItem?
	@State private var renaming: ProjectMediaSource?
	@State private var clipName = ""
	@State private var reconnect: UUID?
	@State private var busy = false
	@State private var projectSheet: ProjectSheet?
	@State private var undo: [HistoryEntry] = []
	@State private var redo: [HistoryEntry] = []
	@State private var error: String?
	@State private var previewTrigger = "fullScreenPreview"
	@State private var fullScreenPreview: PreviewPlayback?
	@State private var jumping = false
	@State private var jumpText = ""
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@AccessibilityFocusState private var focus: String?
	@State private var trigger: String?

	var body: some View {
		ProjectEditorKeyboard(enabled: projectSheet == nil && renaming == nil && fullScreenPreview == nil && board == nil && effects == nil && !jumping && error == nil && !busy && !pickingPhoto && !pickingFile,
			undoShake: {
				guard !undo.isEmpty else { return false }
				history(back: true)
				return true
			}, perform: projectKey) { editor }
	}

	private var editor: some View {
		NavigationStack {
			GeometryReader { geometry in
				let hasVideo = project.placements.contains { $0.track == .video }
				let wide = geometry.size.width > geometry.size.height && geometry.size.width > 550
				HStack(spacing: 0) {
					if hasVideo && wide {
						preview.frame(width: geometry.size.width * 0.45)
					}
					List {
						if hasVideo && !wide {
							preview.frame(maxWidth: .infinity)
								.frame(height: min(geometry.size.height * 0.4, geometry.size.width / pictureAspect))
								.listRowInsets(EdgeInsets())
						}
						projectRows
							.listRowInsets(EdgeInsets())
					}
					.editorListMargins()
				}
			}
			.disabled(busy)
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle(project.name)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Close", action: close).disabled(busy) }
				ToolbarItem(placement: .principal) {
					Text(project.name).font(.headline).accessibilityAddTraits(.isHeader)
				}
				ToolbarItem(placement: .topBarTrailing) {
					let actions = projectActions
					Menu("Project Actions") { EditorMenuAction.buttons(actions) }
						.editorMenuActions("Project Actions", actions)
						.accessibilityFocused($focus, equals: "projectActions")
						.disabled(busy)
				}
			}
			.sheet(item: $projectSheet, onDismiss: { focus = "projectActions" }) { sheet in
				switch sheet {
				case .settings:
					NavigationStack {
						Form {
							ProjectSettingsForm(project: project, saving: true) { updated in
								if updated != project { try save(updated, action: "Project Settings") }
								projectSheet = nil
							}
						}
						.editorListMargins()
						.scrollContentBackground(.hidden)
						.background(EditorTheme.workspace)
						.navigationTitle("Project Settings")
						.navigationBarTitleDisplayMode(.inline)
						.toolbar {
							ToolbarItem(placement: .topBarLeading) { Button("Cancel") { projectSheet = nil } }
						}
					}
					.editorAppearance()
				case .export(let timeline):
					ProjectExportView(timeline: timeline)
				}
			}
			.sheet(item: $effects, onDismiss: { focus = trigger }) { track in
				TrackEffectsSheet(track: track, volume: project.trackVolumes?[track.id] ?? 1) { volume in
					var next = project
					var levels = next.trackVolumes ?? [:]
					levels[track.id] = volume
					next.trackVolumes = levels
					do { try save(next, action: "Track Effects"); effects = nil; return nil }
					catch { return error.localizedDescription }
				}
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
			.sheet(item: $renaming, onDismiss: { focus = trigger }) { source in
				NavigationStack {
					Form { TextField("Clip Name", text: $clipName) }
						.editorListMargins()
						.scrollContentBackground(.hidden)
						.background(EditorTheme.workspace)
						.navigationTitle("Rename Clip")
						.navigationBarTitleDisplayMode(.inline)
						.toolbar {
							ToolbarItem(placement: .cancellationAction) {
								Button("Cancel") { renaming = nil }
							}
							ToolbarItem(placement: .confirmationAction) {
								Button("Save") { rename(source) }
									.disabled(clipName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
							}
						}
				}
				.editorAppearance()
			}
			.fullScreenCover(item: $fullScreenPreview, onDismiss: { focus = previewTrigger }) { preview in
				FullScreenPreview(playback: preview)
			}
			.fullScreenCover(item: $board, onDismiss: { focus = trigger }) { editing in
				CuttingBoardKeyboard(session: editing.session, projectActions: boardActions(editing)) { board = nil }
			}
			.alert("Jump to Time", isPresented: $jumping) {
				TextField(format == .frames ? "Frame" : "Time", text: $jumpText)
				Button("Cancel", role: .cancel) { focus = "jump" }
				Button("Jump") {
					if format == .frames, let index = Int32(jumpText), index >= 0 {
						playback.seek(CMTimeMultiply(project.frame, multiplier: index))
					} else if format != .frames, let time = CuttingBoardSession.parse(jumpText) { playback.seek(time) }
					else { error = "Enter a valid playhead position and choose Jump." }
					focus = "jump"
				}
			}
			.alert("Project", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK") { error = nil }
			} message: { Text(error ?? "") }
		}
		.accessibilityAction(.magicTap) { playback.toggle() }
		.onChange(of: dragging) { _, ids in if ids.isEmpty { dropAnchor = nil } }
		.onChange(of: playback.failure) { _, message in
			if let message { error = message; playback.failure = nil }
		}
	}

	private var projectActions: [EditorMenuAction] {
		var actions = [EditorMenuAction("Project Settings") { playback.pause(); projectSheet = .settings }]
		if !project.placements.isEmpty {
			actions.append(EditorMenuAction("Export") {
				guard preparedRevision == revision, let timeline = playback.exportTimeline(named: project.name) else {
					error = playback.player.currentItem?.status == .failed || playback.player.currentItem == nil && preparedRevision == revision
						? "Could not open the timeline. Reconnect its clips in Project Media and choose Export again."
						: "The timeline is loading. Choose Export again when Play is available."
					return
				}
				projectSheet = .export(timeline)
			})
		}
		return actions
	}

	private var pictureAspect: CGFloat {
		CGFloat(project.picture?.width ?? 16) / CGFloat(max(1, project.picture?.height ?? 9))
	}

	private var preview: some View {
		Button {
			previewTrigger = "projectPreview"
			fullScreenPreview = playback.makePreview()
		} label: {
			ProjectPreview(player: playback.player)
				.allowsHitTesting(false)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Project Preview")
		.accessibilityFocused($focus, equals: "projectPreview")
		.disabled(!playback.ready)
	}

	@ViewBuilder private var projectRows: some View {
		transport
		DisclosureGroup("Project Media", isExpanded: $expanded) {
			sourcePicker("Import Clip", source: nil)
			ForEach(project.sources) { source in
				let actions = [
					EditorMenuAction("Open Cutting Board") { openBoard(source, placement: nil) },
					EditorMenuAction("Rename Clip") { beginRename(source) },
					EditorMenuAction("Reconnect from Files") { pick(source.id, files: true) },
					EditorMenuAction("Reconnect from Photos") { pick(source.id, files: false) }
				]
				Menu { EditorMenuAction.buttons(actions) } label: {
					Text(source.displayName)
						.frame(maxWidth: .infinity, alignment: .leading)
						.contentShape(Rectangle())
				}
				.editorMenuActions(source.displayName, actions)
				.accessibilityFocused($focus, equals: source.id.uuidString)
			}
		}
		ForEach(project.tracks) { track in
			Section {
				let clips = project.displayedClips(on: track)
				if clips.isEmpty {
					Text("No clips").editorTouchRow(alignment: .leading)
						.accessibilityDropPoint(.center, description: Text("Drop on " + track.title))
						.dropDestination(for: String.self) { items, _ in drop(items, on: track, beside: nil, after: false) }
				} else {
					ScrollView(.horizontal) {
						HStack(spacing: 0) {
							ForEach(clips) { clip in
								if let source = project.sources.first(where: { $0.id == clip.sourceID }) {
									clipButton(clip, source: source, track: track, count: clips.count)
								}
							}
						}
					}
				}
			} header: {
				let actions = trackActions(track)
				Menu { EditorMenuAction.buttons(actions) } label: {
					HStack {
						Text(track.title)
						if activeTrack == track.id { Image(systemName: "checkmark").accessibilityHidden(true) }
						Image(systemName: "chevron.down").accessibilityHidden(true)
					}
					.padding(.horizontal, 12)
					.editorTouchRow(alignment: .leading)
				}
					.accessibilityValue(activeTrack == track.id ? "Selected" : "")
					.accessibilityAddTraits(.isHeader)
					.contextMenu { EditorMenuAction.buttons(actions) }
					.accessibilityFocused($focus, equals: track.id)
					.dropDestination(for: String.self) { items, _ in drop(items, on: track, beside: nil, after: true) }
					.editorMenuActions(track.title, actions)
			}
		}
		if let seconds = project.targetSeconds { LabeledContent("Project Duration", value: time(CMTime(seconds: seconds, preferredTimescale: 60000))) }
		if busy { ProgressView("Opening clip") }
	}

	private var transport: some View {
		Group {
			ProjectTimelineSlider(playhead: playback.playhead, duration: project.duration, frame: project.frame,
				formatTime: time, scrub: playback.scrub, editingChanged: playback.setScrubbing, step: step, focus: $focus)
				.disabled(!playback.ready)
			Button("Jump to Time", action: openJump)
				.buttonStyle(EditorButtonStyle())
				.accessibilityFocused($focus, equals: "jump")
				.disabled(!playback.ready)
			HStack(spacing: 0) {
				stepButton(forward: false)
				shuttleButton(forward: false)
				Button { playback.toggle() } label: { Label(playback.playing ? "Pause" : "Play", systemImage: playback.playing ? "pause.fill" : "play.fill") }
				shuttleButton(forward: true)
				stepButton(forward: true)
				if project.placements.contains(where: { $0.track == .video }) {
					Button { previewTrigger = "fullScreenPreview"; fullScreenPreview = playback.makePreview() } label: {
						Label("Full Screen Preview", systemImage: "arrow.up.left.and.arrow.down.right")
					}
					.disabled(!playback.ready)
					.accessibilityFocused($focus, equals: "fullScreenPreview")
				}
			}
			.disabled(!playback.ready)
			.labelStyle(.iconOnly)
			.buttonStyle(EditorButtonStyle(square: true))
			.fixedSize(horizontal: false, vertical: true)
			EditorCommandRow {
				ForEach([true, false], id: \.self) { isIn in
					let point = isIn ? project.markIn : project.markOut
					Button {
						playback.pause()
						setMarker(isIn, to: point?.time == playback.position ? nil : ProjectTime(playback.position))
					} label: { Text(isIn ? "Mark In" : "Mark Out") }
					.accessibilityActions {
						if let point {
							Button(isIn ? "Go to In" : "Go to Out") { playback.seek(point.time) }
							Button(isIn ? "Clear In" : "Clear Out") { setMarker(isIn, to: nil) }
						}
					}
					.accessibilityValue(point.map { time($0.time) } ?? "")
					.disabled(project.placements.isEmpty)
				}
				Menu {
					Button("Undo") { history(back: true) }.disabled(undo.isEmpty)
					Button("Redo") { history(back: false) }.disabled(redo.isEmpty)
				} label: { Text("Undo") }
				.editorMenuActions("Undo", historyActions)
				.disabled(undo.isEmpty && redo.isEmpty)
			}
			.buttonStyle(EditorButtonStyle())
			.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func openJump() {
		playback.pause()
		jumpText = ""
		jumping = true
	}

	private func step(_ count: Int32) {
		playback.seek(playback.position + CMTimeMultiply(project.frame, multiplier: count))
	}

	private func stepButton(forward: Bool) -> some View {
		let direction = forward ? "Step Forward" : "Step Back"
		let count: Int32 = forward ? 1 : -1
		return Button { step(count) } label: {
			Label(direction + " One Frame", systemImage: forward ? "forward.frame" : "backward.frame")
		}
		.accessibilityActions {
			Button(direction + " 10 Frames") { step(count * 10) }
			Button(forward ? "Next Edit Point" : "Previous Edit Point") {
				if let track = project.tracks.first(where: { $0.id == activeTrack }) {
					navigate(forward: forward, clips: project.displayedClips(on: track))
				}
			}
		}
	}

	private func navigate(forward: Bool, clips: [ProjectPlacement]) {
		let points = [CMTime.zero, project.duration] + clips.flatMap { [$0.start.time, $0.end] } +
			[project.markIn?.time, project.markOut?.time].compactMap { $0 }
		let position = playback.position
		let destination = forward ? points.filter { $0 > position }.min() ?? project.duration :
			points.filter { $0 < position }.max() ?? .zero
		playback.seek(destination)
		UIAccessibility.post(notification: .announcement, argument: "Edit Point, " + time(destination))
	}

	private func shuttleButton(forward: Bool) -> some View {
		let rate = playback.shuttleRate
		let active = forward ? rate > 0 : rate < 0
		return Button { playback.shuttle(forward: forward) } label: {
			Label(forward ? "Fast Forward" : "Rewind", systemImage: forward ? "forward.fill" : "backward.fill")
		}
		.buttonStyle(EditorButtonStyle(square: true, badge: active ? abs(rate).formatted() + "x" : nil))
	}

	private func setMarker(_ isIn: Bool, to point: ProjectTime?) {
		var next = project
		if isIn { next.markIn = point } else { next.markOut = point }
		commit(next, action: (point == nil ? "Clear " : "Mark ") + (isIn ? "In" : "Out"))
	}

	private var historyActions: [EditorMenuAction] {
		var actions: [EditorMenuAction] = []
		if !undo.isEmpty { actions.append(EditorMenuAction("Undo") { history(back: true) }) }
		if !redo.isEmpty { actions.append(EditorMenuAction("Redo") { history(back: false) }) }
		return actions
	}

	private func clipButton(_ clip: ProjectPlacement, source: ProjectMediaSource, track: TimelineTrack, count: Int) -> some View {
		let name = clip.displayName(for: source)
		let linked = track.id != clip.trackID
		let rowID = (linked ? "linked/" : "") + clip.id.uuidString
		let actions = clipActions(clip, source: source, rowID: rowID, linked: linked)
		return Menu {
			EditorMenuAction.buttons(actions)
		} label: {
			HStack {
				if marked.contains(clip.id) { Image(systemName: "checkmark").accessibilityHidden(true) }
				Text(name)
			}
			.padding(.horizontal, 6)
			.frame(minHeight: 48)
			.containerRelativeFrame(.horizontal) { width, _ in max(120, width / CGFloat(count)) }
			.background(.quaternary, in: RoundedRectangle(cornerRadius: 8).inset(by: 2))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityValue((linked ? "Linked audio, " : "") + (marked.contains(clip.id) ? "Marked, " : "") + "Start " + time(clip.start.time) + ", duration " + time(clip.duration))
		.contextMenu { EditorMenuAction.buttons(actions) }
		.focused($keyboardClip, equals: rowID)
		.accessibilityFocused($focus, equals: rowID)
		.draggable(payload(for: clip))
		.accessibilityDragPoint(.center, description: Text(name))
		.modifier(ClipDropTarget(name: name) { items, after in
			drop(items, on: linked ? .primaryVideo : track, beside: clip.id, after: after)
		})
		.editorMenuActions(name, actions)
	}

	private func trackActions(_ track: TimelineTrack) -> [EditorMenuAction] {
		var actions = [
			EditorMenuAction("Select Track") { keyboardClip = nil; activeTrack = track.id; focus = track.id },
			EditorMenuAction("Track Effects") { trigger = track.id; playback.pause(); effects = track }
		]
		if !dragging.isEmpty && project.displayedClips(on: track).isEmpty && project.placements.filter({ dragging.contains($0.id) }).allSatisfy({ $0.track == track.kind }) {
			actions.append(EditorMenuAction("Drop on Track") { move(dragging, on: track, beside: nil, after: false) })
		}
		return actions
	}

	private func payload(for clip: ProjectPlacement) -> String {
		let ids = marked.contains(clip.id) ? marked : [clip.id]
		return ([project.id.uuidString] + ids.map(\.uuidString)).joined(separator: "/")
	}

	private func drop(_ items: [String], on track: TimelineTrack, beside clip: UUID?, after: Bool) -> Bool {
		var ids: Set<UUID> = []
		for item in items {
			let fields = item.components(separatedBy: "/")
			guard fields.first == project.id.uuidString else { return false }
			for field in fields.dropFirst() {
				guard let id = UUID(uuidString: field) else { return false }
				ids.insert(id)
			}
		}
		return move(ids, on: track, beside: clip, after: after)
	}

	@discardableResult private func move(_ ids: Set<UUID>, on track: TimelineTrack, beside clip: UUID?, after: Bool) -> Bool {
		var next = project
		do {
			let subject = ids.count == 1 ? ids.first.flatMap(clipName(for:)) ?? "Clip" : "Clips"
			let destination = clip.flatMap(clipName(for:)).map { (after ? "after " : "before ") + $0 } ?? ("on " + track.title)
			try next.move(ids, to: track, beside: clip, after: after)
			try save(next, action: ids.count == 1 ? "Move Clip" : "Move Clips")
			dragging.removeAll()
			activeTrack = track.id
			UIAccessibility.post(notification: .announcement, argument: subject + " dropped " + destination)
			return true
		} catch { self.error = error.localizedDescription; return false }
	}

	private func toggleMark(_ id: UUID) {
		if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
	}

	private func clipName(for id: UUID) -> String? {
		guard let clip = project.placements.first(where: { $0.id == id }),
			let source = project.sources.first(where: { $0.id == clip.sourceID }) else { return nil }
		return clip.displayName(for: source)
	}

	private func startDrag(_ clip: ProjectPlacement) {
		dragging = marked.contains(clip.id) ? marked : [clip.id]
		announceDrag()
	}

	private func addToDrag(_ clip: ProjectPlacement) {
		if dragging.insert(clip.id).inserted { announceDrag() }
	}

	private func announceDrag() {
		let subject = dragging.count == 1 ? dragging.first.flatMap(clipName(for:)) : nil
		UIAccessibility.post(notification: .announcement, argument: "Dragging " + (subject ?? "\(dragging.count) clips"))
	}

	private func clipActions(_ clip: ProjectPlacement, source: ProjectMediaSource, rowID: String, linked: Bool) -> [EditorMenuAction] {
		let name = clip.displayName(for: source)
		var actions = [
			EditorMenuAction("Open Cutting Board") { openBoard(source, placement: clip, rowID: rowID) },
			EditorMenuAction(marked.contains(clip.id) ? "Unmark for Editing" : "Mark for Editing") { toggleMark(clip.id) }
		]
		if dragging.isEmpty {
			actions.append(EditorMenuAction("Start Drag") { startDrag(clip) })
		} else {
			if !dragging.contains(clip.id), let track = project.tracks.first(where: { $0.id == clip.trackID }),
				project.placements.filter({ dragging.contains($0.id) }).allSatisfy({ $0.track == clip.track }) {
				actions.append(EditorMenuAction("Add to Drag") { addToDrag(clip) })
				actions.append(EditorMenuAction("Drop Before " + name) { move(dragging, on: track, beside: clip.id, after: false) })
				actions.append(EditorMenuAction("Drop After " + name) { move(dragging, on: track, beside: clip.id, after: true) })
			}
			actions.append(EditorMenuAction("Cancel Drag") { dragging.removeAll() })
		}
		actions.append(EditorMenuAction("Go to Start") { playback.seek(clip.start.time) })
		actions.append(EditorMenuAction("Go to End") { playback.seek(clip.end) })
		actions.append(EditorMenuAction(linked ? "Remove Linked Clip Pair" : "Remove from Track") {
			var next = project
			next.placements.removeAll { $0.id == clip.id }
			commit(next, action: "Remove Clip")
		})
		return actions
	}

	private func beginRename(_ source: ProjectMediaSource) {
		trigger = source.id.uuidString
		clipName = source.displayName
		renaming = source
	}

	private func rename(_ source: ProjectMediaSource) {
		var next = project
		guard let index = next.sources.firstIndex(where: { $0.id == source.id }) else { return }
		let name = clipName.trimmingCharacters(in: .whitespacesAndNewlines)
		next.sources[index].projectName = name == source.name ? nil : name
		renaming = nil
		if project != next { commit(next, action: "Rename Clip") }
	}

	private func sourcePicker(_ title: String, source: UUID?) -> some View {
		Menu {
			Button("Photo Library") { pick(source, files: false) }
			Button("Files") { pick(source, files: true) }
		} label: { Text(title).editorTouchRow(alignment: .leading) }
		.accessibilityAction(named: "Photo Library") { pick(source, files: false) }
		.accessibilityAction(named: "Files") { pick(source, files: true) }
		.accessibilityFocused($focus, equals: "import")
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
					source.projectName = original.projectName
					next.sources[index] = source
				} else { next.sources.append(source) }
				commit(next, action: replacing == nil ? "Import Clip" : "Reconnect Clip")
			} catch { self.error = error.localizedDescription }
		}
	}

	private func openBoard(_ source: ProjectMediaSource, placement: ProjectPlacement?, rowID: String? = nil) {
		playback.pause()
		trigger = rowID ?? (placement?.id ?? source.id).uuidString
		busy = true
		Task {
			defer { busy = false }
			do {
				let access = try await source.open()
				let session = try await CuttingBoardSession.openReferenced(asset: access.asset, title: placement?.displayName(for: source) ?? source.displayName, access: access, ranges: placement?.ranges.map(\.range))
				board = ProjectBoard(source: source, placement: placement, session: session)
			} catch { self.error = "Could not open " + source.displayName + ". Reconnect the clip in Project Media." }
		}
	}

	private func boardActions(_ board: ProjectBoard) -> BoardProjectActions {
		let kind: ProjectTrack = board.source.picture == nil ? .audio : .video
		func destination() -> TimelineTrack {
			project.tracks.first { $0.id == (board.placement?.trackID ?? activeTrack) && $0.kind == kind }
				?? (kind == .video ? .primaryVideo : .primaryAudio)
		}
		func quick(_ mode: PlacementMode) {
			do { try place(board, mode: mode, track: destination()) }
			catch { board.session.message = error.localizedDescription }
		}
		return BoardProjectActions(append: { quick(.append) }, split: { quick(.split) }, overwrite: { quick(.overwrite) },
			update: board.placement == nil ? nil : { quick(.update) }, placementSheet: {
				AnyView(PlacementSheet(tracks: project.tracks.filter { $0.kind == kind }, destination: destination(),
					offersAudio: kind == .video && board.source.hasAudio) { track, name, mode, omitAudio in
					do {
						try place(board, mode: mode, track: track, newName: name, omitAudio: omitAudio)
						board.session.choosingPlacement = false
						return nil
					} catch { return error.localizedDescription }
				})
			})
	}

	private func place(_ editing: ProjectBoard, mode: PlacementMode, track: TimelineTrack, newName: String? = nil, omitAudio: Bool = false) throws {
		let session = editing.session
		session.releaseAudio()
		var next = project
		let destination = try newName.map { try next.createTrack($0, kind: track.kind) } ?? track
		let updating = mode == .update
		if !updating, session.state.markIn != nil, session.state.markOut != nil, session.selection == nil {
			throw ClipEditError.invalidSelection
		}
		let ranges = session.state.timeline.sourceRanges(in: updating ? nil : session.selection)
		let start: CMTime
		switch mode {
		case .append: start = next.clips(on: destination).last?.end ?? .zero
		case .update: start = editing.placement?.start.time ?? .zero
		default: start = playback.position
		}
		try next.place(editing.source, ranges: ranges, at: start, on: destination, mode: mode,
			replacing: updating ? editing.placement?.id : nil, omitAudio: updating ? editing.placement?.omitAudio == true : omitAudio)
		let action: String = switch mode {
		case .append: "Append"
		case .update: "Save Clip Changes"
		case .overwrite: "Overwrite"
		case .split: "Insert Clip"
		}
		try save(next, action: action)
		activeTrack = destination.id
		if updating { board = nil }
		else { UIAccessibility.post(notification: .announcement, argument: (mode == .append ? "Appended to " : "Added to ") + destination.title) }
	}

	private func commit(_ next: EditingProject, action: String) {
		do { try save(next, action: action) } catch { self.error = error.localizedDescription }
	}

	private func save(_ next: EditingProject, action: String) throws {
		guard next != project else { return }
		var next = next
		if let point = next.markIn, point.time > next.duration { next.markIn = nil }
		if let point = next.markOut, point.time > next.duration { next.markOut = nil }
		next.version = 2
		try ProjectLibrary.save(next, replacing: project)
		undo.append(HistoryEntry(project: project, action: action))
		redo.removeAll()
		update(next)
	}

	private func history(back: Bool) {
		guard let entry = back ? undo.last : redo.last else { return }
		do {
			try ProjectLibrary.save(entry.project, replacing: project)
			let inverse = HistoryEntry(project: project, action: entry.action)
			if back { undo.removeLast(); redo.append(inverse) }
			else { redo.removeLast(); undo.append(inverse) }
			dragging.removeAll()
			update(entry.project)
			UIAccessibility.post(notification: .announcement, argument: (back ? "Undo " : "Redo ") + entry.action)
		} catch { self.error = error.localizedDescription }
	}

	private func update(_ next: EditingProject) {
		let usedSources = Set(next.placements.map(\.sourceID))
		func timelineReferences(_ model: EditingProject) -> [UUID: ProjectMediaSource.Reference] {
			Dictionary(uniqueKeysWithValues: model.sources.filter { usedSources.contains($0.id) }.map { ($0.id, $0.reference) })
		}
		let rebuild = project.picture != next.picture || project.placements != next.placements || timelineReferences(project) != timelineReferences(next) || project.tracks != next.tracks || project.trackVolumes != next.trackVolumes
		project = next
		let valid = Set(next.placements.map(\.id))
		marked.formIntersection(valid)
		dragging.formIntersection(valid)
		if !next.tracks.contains(where: { $0.id == activeTrack }) { activeTrack = TimelineTrack.primaryVideo.id }
		if rebuild { revision += 1 }
	}

	private func projectKey(_ key: String, flags: UIKeyModifierFlags) {
		let focusedRow = keyboardClip ?? focus
		let focusedID = focusedRow?.split(separator: "/").last.flatMap { UUID(uuidString: String($0)) }
		let focusedClip = project.placements.first { $0.id == focusedID }
		let trackID = focusedRow?.hasPrefix("linked/") == true ? TimelineTrack.primaryAudio.id : focusedClip?.trackID ?? activeTrack
		guard let track = project.tracks.first(where: { $0.id == trackID }) else { return }
		let clips = project.displayedClips(on: track)
		let position = playback.position
		let clip = focusedClip ?? clips.first { $0.end > position }
		let destinationTrack = clip?.track == .video && track == .primaryAudio ? TimelineTrack.primaryVideo : track
		var next = project
		switch key {
		case " " where !dragging.isEmpty && dropAnchor != nil:
			if let anchor = project.placements.first(where: { $0.id == dropAnchor }),
				let destination = project.tracks.first(where: { $0.id == anchor.trackID }) {
				move(dragging, on: destination, beside: anchor.id, after: dropAfter)
			}
		case " " where focusedClip != nil:
			if dragging.isEmpty, let clip { startDrag(clip) }
			else if let clip, !dragging.contains(clip.id) { move(dragging, on: destinationTrack, beside: clip.id, after: true) }
			else { dragging.removeAll() }
		case " ", "k": playback.toggle()
		case "j", "l": playback.shuttle(forward: key == "l")
		case "s":
			if let clip {
				if flags.contains(.shift), !dragging.isEmpty {
					if project.placements.filter({ dragging.contains($0.id) }).allSatisfy({ $0.track == clip.track }) { addToDrag(clip) }
				} else { toggleMark(clip.id) }
			}
		case UIKeyCommand.inputEscape: dragging.removeAll(); dropAnchor = nil
		case "v": if !dragging.isEmpty { move(dragging, on: destinationTrack, beside: clip?.id, after: true) }
		case "c", "\r":
			if let clip, let source = project.sources.first(where: { $0.id == clip.sourceID }) { openBoard(source, placement: clip, rowID: focusedClip == nil ? nil : focusedRow) }
		case "z": history(back: !flags.contains(.shift))
		case "t": UIAccessibility.post(notification: .announcement, argument: time(position))
		case "i", "o":
			playback.pause()
			setMarker(key == "i", to: flags.contains(.alternate) ? nil : ProjectTime(playback.position))
		case UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow:
			if flags.contains(.alternate), let index = project.tracks.firstIndex(of: track) {
				let target = index + (key == UIKeyCommand.inputUpArrow ? -1 : 1)
				if project.tracks.indices.contains(target) {
					activeTrack = project.tracks[target].id
					keyboardClip = nil
					focus = activeTrack
				}
			} else { playback.seek(key == UIKeyCommand.inputUpArrow ? .zero : project.duration) }
		case UIKeyCommand.inputHome: playback.seek(.zero)
		case UIKeyCommand.inputEnd: playback.seek(project.duration)
		case ";", "'", UIKeyCommand.inputRightArrow, UIKeyCommand.inputLeftArrow:
			let forward = key == "'" || key == UIKeyCommand.inputRightArrow
			if let clip, (!dragging.isEmpty && !flags.contains(.command)) || flags.contains([.alternate, .command]) {
				let group = dragging.isEmpty ? (marked.contains(clip.id) ? marked : [clip.id]) : dragging
				let current = clips.firstIndex { $0.id == (dropAnchor ?? clip.id) } ?? 0
				let indices = forward ? Array(clips.indices.dropFirst(current + 1)) : Array(clips.indices.prefix(current).reversed())
				if let index = indices.first(where: { !group.contains(clips[$0].id) && clips[$0].track == clip.track }) {
					if dragging.isEmpty { move(group, on: destinationTrack, beside: clips[index].id, after: forward) }
					else {
						dropAnchor = clips[index].id
						dropAfter = forward
						let rowID = (clips[index].trackID == track.id ? "" : "linked/") + clips[index].id.uuidString
						focus = rowID
						keyboardClip = rowID
					}
				}
			} else if flags.contains(.command) || key == "'" || key == ";" {
				navigate(forward: forward, clips: clips)
			} else {
				let count: Int32 = flags.contains(.shift) ? 10 : 1
				step(forward ? count : -count)
			}
		case "[", "]", "b":
			guard let clip, clip.start.time < position, position < clip.end,
				let left = clip.slice(from: clip.start.time, to: position),
				var right = clip.slice(from: position, to: clip.end) else { return }
			next.placements.removeAll { $0.id == clip.id }
			if key != "[" { next.placements.append(left) }
			if key != "]" {
				if key == "b" {
					right.id = UUID()
					right.labelIndex = nil
				}
				next.placements.append(right)
			}
			next.assignPlacementLabels()
			commit(next, action: key == "b" ? "Split Clip" : "Trim Clip")
		case "\u{8}", UIKeyCommand.inputDelete:
			if let clip {
				let ids: Set<UUID> = marked.contains(clip.id) ? marked : [clip.id]
				next.placements.removeAll { ids.contains($0.id) }
				commit(next, action: ids.count == 1 ? "Remove Clip" : "Remove Clips")
			}
		default: break
		}
	}

	private func time(_ value: CMTime) -> String {
		if format == .frames {
			let frame = project.frame
			let ticks = CMTimeConvertScale(value, timescale: frame.timescale, method: .roundTowardZero).value
			return "Frame " + String(ticks / frame.value)
		}
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

private struct ClipDropTarget: ViewModifier {
	let name: String
	let perform: ([String], Bool) -> Bool
	@State private var width: CGFloat = 0

	func body(content: Content) -> some View {
		content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
			.dropDestination(for: String.self) { items, location in perform(items, location.x >= width / 2) }
			.accessibilityDropPoint(.leading, description: Text("Drop Before " + name))
			.accessibilityDropPoint(.trailing, description: Text("Drop After " + name))
	}
}

private struct TrackEffectsSheet: View {
	let track: TimelineTrack
	@State var volume: Float
	let save: (Float) -> String?
	@State private var error: String?
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Slider(value: $volume, in: 0...1, step: 0.01) { Text("Volume") }
						.accessibilityValue(volume.formatted(.percent))
					LabeledContent("Volume", value: volume.formatted(.percent))
				} header: { Text(track.title).accessibilityAddTraits(.isHeader) }
				if let error { Text(error) }
			}
			.editorListMargins()
			.navigationTitle("Track Effects")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .topBarTrailing) { Button("Save") { error = save(volume) } }
			}
		}.editorAppearance()
	}
}

private struct PlacementSheet: View {
	let tracks: [TimelineTrack]
	@State var destination: TimelineTrack
	let offersAudio: Bool
	let save: (TimelineTrack, String?, PlacementMode, Bool) -> String?
	@State private var method = "New Track"
	@State private var name = ""
	@State private var includeAudio = true
	@State private var error: String?
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			Form {
				Picker("Placement", selection: $method) {
					ForEach(["New Track", "Overwrite", "Split"], id: \.self) { Text($0) }
				}
				if method == "New Track" { TextField("Track Name", text: $name) }
				else {
					Picker("Destination Track", selection: Binding(get: { destination.id }, set: { id in if let track = tracks.first(where: { $0.id == id }) { destination = track } })) {
						ForEach(tracks) { Text($0.title).tag($0.id) }
					}
				}
				if offersAudio { Toggle("Include Clip Audio", isOn: $includeAudio) }
				if let error { Text(error) }
			}
			.editorListMargins()
			.navigationTitle("Add at Playhead")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .topBarTrailing) {
					Button("Add") {
						error = save(destination, method == "New Track" ? name : nil, method == "Split" ? .split : .overwrite, !includeAudio)
					}.disabled(method == "New Track" && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				}
			}
		}.editorAppearance()
	}
}

private struct ProjectExportView: View {
	let timeline: ProjectExport
	@Environment(\.dismiss) private var dismiss
	@State private var destination: Destination?
	@State private var output: ExportFile?
	@State private var failure: String?
	@State private var savingToPhotos = false
	private enum Destination { case files, photos }

	var body: some View {
		NavigationStack {
			List {
				if destination != nil {
					ProgressView("Exporting")
				} else {
					if timeline.hasVideo { Button("Photos") { destination = .photos } }
					Button("Files") { destination = .files }
				}
			}
			.scrollContentBackground(.hidden)
			.editorListMargins()
			.background(EditorTheme.workspace)
			.navigationTitle("Export")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Cancel") { dismiss() }.disabled(savingToPhotos)
				}
			}
		}
		.editorAppearance()
		.interactiveDismissDisabled(savingToPhotos)
		.sheet(item: $output, onDismiss: { dismiss() }) { file in
			FileSavePicker(file: file.url) { output = nil }
		}
		.task(id: destination) {
			guard let destination else { return }
			do {
				if destination == .photos {
					let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
					guard status == .authorized || status == .limited else {
						throw ProjectFailure("Allow Photos access in Settings or choose Files.")
					}
				}
				try Task.checkCancellation()
				let file = try await timeline.render()
				if destination == .files {
					output = file
				} else {
					savingToPhotos = true
					defer { savingToPhotos = false }
					try await PHPhotoLibrary.shared().performChanges {
						let options = PHAssetResourceCreationOptions()
						options.originalFilename = file.url.lastPathComponent
						PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file.url, options: options)
					}
					dismiss()
				}
			} catch {
				guard !Task.isCancelled else { return }
				failure = (error as? ProjectFailure)?.message ?? "Could not export the project. Check available storage and access to the source clips, then try again."
				self.destination = nil
			}
		}
		.alert("Could Not Export Project", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("OK") { failure = nil }
		} message: { Text(failure ?? "") }
	}
}

private struct ProjectTimelineSlider: View {
	@ObservedObject var playhead: ProjectPlayhead
	let duration: CMTime
	let frame: CMTime
	let formatTime: (CMTime) -> String
	let scrub: (CMTime) -> Void
	let editingChanged: (Bool) -> Void
	let step: (Int32) -> Void
	let focus: AccessibilityFocusState<String?>.Binding

	var body: some View {
		let value = formatTime(playhead.position)
		VStack(spacing: 0) {
			Text("Playhead, " + value)
				.monospacedDigit()
				.accessibilityHidden(true)
			Slider(value: Binding(get: { playhead.position.seconds }, set: { seconds in
				if seconds >= duration.seconds { scrub(duration) }
				else {
					let frames = (seconds / frame.seconds).rounded()
					scrub(CMTimeMultiplyByFloat64(frame, multiplier: frames))
				}
			}), in: 0...max(duration.seconds, frame.seconds)) {
				Text("Playhead")
			} onEditingChanged: { editing in
				editingChanged(editing)
			}
			.accessibilityValue(value)
			.accessibilityAdjustableAction { direction in
				switch direction {
				case .increment: step(1)
				case .decrement: step(-1)
				@unknown default: break
				}
			}
			.frame(minHeight: 44)
			.accessibilityFocused(focus, equals: "playhead")
		}
	}
}
