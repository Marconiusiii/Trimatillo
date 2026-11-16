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
	@State private var tool = ProjectTool.editor
	@State private var captionEntry: CaptionEntry?
	@State private var captionTrigger = "newCaption"
	@State private var captionCreated = false
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
	@State private var confirmedPhoto: SelectedPhotoClip?
	@State private var renaming: ProjectMediaSource?
	@State private var clipName = ""
	@State private var reconnect: UUID?
	@State private var clipTask: Task<Void, Never>?
	@State private var projectSheet: ProjectSheet?
	@State private var undo: [HistoryEntry] = []
	@State private var redo: [HistoryEntry] = []
	@State private var error: String?
	@State private var fullScreenPreview: PreviewPlayback?
	@State private var directTouch = false
	@AccessibilityFocusState(for: .voiceOver) private var surfaceFocused: Bool
	@AppStorage("directTouchScrubbing", store: EditorPreferences.shared) private var scrubMode = DirectTouchScrubbing.absolute
	@State private var jumping = false
	@FocusState private var renamingClip: Bool
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@AccessibilityFocusState private var focus: String?
	@State private var trigger: String?

	private var preparingTimeline: Bool {
		board == nil && !project.placements.isEmpty && (preparedRevision != revision || playback.preparing)
	}

	private var loading: Bool { clipTask != nil || preparingTimeline }

	var body: some View {
		ProjectWorkspaceTabs(selection: $tool) {
			workspacePage
		}
		.onChange(of: tool) {
			playback.playhead.navigationLabel = nil
			keyboardClip = nil
		}
	}

	private var workspacePage: some View {
		ProjectEditorKeyboard(enabled: captionEntry == nil && !directTouch && projectSheet == nil && renaming == nil && fullScreenPreview == nil && board == nil && effects == nil && !jumping && error == nil && !loading && !pickingPhoto && !pickingFile,
			captioning: tool == .captioner, undoShake: {
				guard !undo.isEmpty else { return false }
				history(back: true)
				return true
			}, perform: projectKey) { editor }
	}

	private var editor: some View {
		NavigationStack {
			Group {
				if clipTask != nil {
					LoadingStatusView("Opening clip", cancel: cancelClipLoad)
				} else if preparingTimeline {
					LoadingStatusView("Preparing timeline", cancel: close)
				} else {
					editorLayout
				}
			}
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle(tool == .captioner ? "Captioner" : project.name)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar(loading ? .hidden : .visible, for: .navigationBar)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Close", action: close) }
				ToolbarItem(placement: .principal) {
					Text(tool == .captioner ? "Captioner" : project.name).font(.headline).accessibilityAddTraits(.isHeader)
				}
				ToolbarItem(placement: .topBarTrailing) {
					let actions = projectActions
					Menu("Project Actions") { EditorMenuAction.buttons(actions) }
						.editorMenuActions("Project Actions", actions)
						.accessibilityFocused($focus, equals: "projectActions")
				}
			}
			.sheet(item: $projectSheet, onDismiss: { focus = "projectActions" }) { sheet in
				switch sheet {
				case .settings:
					NavigationStack {
						ProjectSettingsForm(project: project, saving: true) { updated in
							if updated != project { try save(updated, action: "Project Settings") }
							projectSheet = nil
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
			.sheet(isPresented: $pickingPhoto, onDismiss: {
				if let clip = confirmedPhoto {
					confirmedPhoto = nil
					importSource {
						guard let id = clip.item.itemIdentifier else { throw ProjectFailure("Choose the original video in Photo Library.") }
						return try await ProjectMediaSource.photo(id, asset: clip.asset)
					}
				} else { focus = trigger }
			}) {
				PhotoClipPickerView { confirmedPhoto = $0 }
			}
			.onChange(of: pickingFile) { _, presented in if !presented { focus = trigger } }
			.sheet(item: $renaming, onDismiss: { focus = trigger }) { source in
				NavigationStack {
					Form { TextField("Clip Name", text: $clipName).focused($renamingClip) }
						.dismissKeyboardToolbar(while: renamingClip) { renamingClip = false }
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
			.sheet(item: captionBinding(direct: false), onDismiss: { finishCaption(direct: false) }, content: captionSheet)
			.fullScreenCover(isPresented: $directTouch, onDismiss: { focus = "projectDirectTouch" }) {
				directTouchEditor
			}
			.fullScreenCover(item: $fullScreenPreview, onDismiss: { focus = "fullScreenPreview" }) { preview in
				if let cues = project.captions, !cues.isEmpty {
					CaptionedProjectPreview(playback: preview, cues: cues, aspect: pictureAspect)
				} else { FullScreenPreview(playback: preview) }
			}
			.fullScreenCover(item: $board, onDismiss: { focus = trigger }) { editing in
				CuttingBoardKeyboard(session: editing.session, projectActions: boardActions(editing)) { board = nil }
			}
			.sheet(isPresented: $jumping, onDismiss: { focus = "jump" }) {
				ProjectJumpSheet(format: format, frame: project.frame) { playback.seek($0) }
			}
			.alert("Project", isPresented: Binding(get: { !directTouch && error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK") { error = nil }
			} message: { Text(error ?? "") }
		}
		.onChange(of: dragging) { _, ids in if ids.isEmpty { dropAnchor = nil } }
		.onChange(of: playback.failure) { _, message in
			if let message { error = message; playback.failure = nil }
		}
	}

	private var editorLayout: some View {
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
					Group {
						if tool == .editor { projectRows }
						else {
							transport
							CaptionerView(project: $project, playback: playback, focus: $focus, keyboardFocus: $keyboardClip, time: time,
								newCaption: { openCaption(nil) }, edit: { openCaption($0) }, save: save)
						}
					}
					.listRowInsets(EdgeInsets())
				}
				.editorListMargins()
			}
		}
		.accessibilityAction(.magicTap) { playback.toggle() }
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
		ProjectPreview(player: playback.player)
			.overlay {
				if let cues = project.captions, !cues.isEmpty {
					CaptionOverlay(cues: cues, playhead: playback.playhead, aspect: pictureAspect)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
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
	}

	private var transport: some View {
		Group {
			Button("Direct Touch Editor") {
				directTouch = true
			}
			.buttonStyle(EditorButtonStyle())
			.accessibilityFocused($focus, equals: "projectDirectTouch")
			.disabled(!playback.ready)
			ProjectTimelineSlider(playhead: playback.playhead, playback: playback, duration: project.duration,
				frame: project.frame, format: format, formatTime: time)
				.disabled(!playback.ready)
			Button("Jump to Time", action: openJump)
				.buttonStyle(EditorButtonStyle())
				.accessibilityFocused($focus, equals: "jump")
				.disabled(!playback.ready)
			HStack(spacing: 0) {
				stepButton(forward: false)
				ProjectShuttleButton(playback: playback, forward: false)
				ProjectPlayButton(playback: playback)
				ProjectShuttleButton(playback: playback, forward: true)
				stepButton(forward: true)
				if project.placements.contains(where: { $0.track == .video }) {
					Button { fullScreenPreview = playback.makePreview() } label: {
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

	private var selectedTrack: TimelineTrack {
		project.tracks.first { $0.id == activeTrack } ?? .primaryVideo
	}

	private var directTouchEditor: some View {
		VStack(spacing: 0) {
			HStack(spacing: 0) {
				Button("Close") { directTouch = false }
					.buttonStyle(EditorButtonStyle())
					.fixedSize()
				VStack(alignment: .leading) {
					Text("Direct Touch Editor").font(.headline).accessibilityAddTraits(.isHeader)
					Text(tool == .captioner ? "Captioner" : selectedTrack.title).accessibilityHidden(true)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			if preparingTimeline {
				LoadingStatusView("Preparing timeline", cancel: { directTouch = false })
			} else {
				ProjectTouchSurface(playhead: playback.playhead, playback: playback, duration: project.duration,
					captioning: tool == .captioner, trackName: tool == .captioner ? "Captioner" : selectedTrack.title, mode: scrubMode, close: { directTouch = false }, swipe: projectSwipe)
					.overlay {
						if let cues = project.captions, !cues.isEmpty {
							CaptionOverlay(cues: cues, playhead: playback.playhead, aspect: pictureAspect)
						}
					}
					.accessibilityFocused($surfaceFocused)
					.onAppear {
						playback.primeScrubAudio()
						surfaceFocused = true
					}
			}
		}
		.background(EditorTheme.workspace)
		.editorAppearance()
		.accessibilityAction(.magicTap) { playback.toggle() }
		.sheet(item: captionBinding(direct: true), onDismiss: { finishCaption(direct: true) }, content: captionSheet)
		.alert("Project", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button("OK") { error = nil }
		} message: { Text(error ?? "") }
	}

	private func projectSwipe(_ fingers: Int, _ direction: UISwipeGestureRecognizer.Direction) {
		let forward = direction == .right
		let down = direction == .down
		switch (fingers, direction) {
		case (2, .down) where tool == .captioner:
			openCaption(nil)
		case (2, .up) where tool == .captioner:
			break
		case (2, .up), (2, .down):
			let tracks = project.tracks
			guard let index = tracks.firstIndex(of: selectedTrack) else { return }
			let next = index + (down ? 1 : -1)
			guard tracks.indices.contains(next) else { return }
			activeTrack = tracks[next].id
			keyboardClip = nil
			playback.playhead.navigationLabel = nil
			UIAccessibility.post(notification: .announcement, argument: tracks[next].title)
		case (3, .up), (3, .down):
			history(back: down)
		case (1, .left), (1, .right):
			playback.stepWithAudio(forward: forward, frame: project.frame)
		case (1, .up), (1, .down):
			guard playback.ready else { return }
			playback.pause()
			let point = ProjectTime(playback.position)
			let remove = (down ? project.markIn : project.markOut)?.time == point.time
			setMarker(down, to: remove ? nil : point)
			if error == nil {
				let name = down ? "In" : "Out"
				UIAccessibility.post(notification: .announcement, argument: remove ? name + " Removed" : "Marked " + name)
			}
		case (2, .left), (2, .right):
			playback.shuttle(forward: forward)
		case (3, .left), (3, .right):
			if playback.ready { navigate(forward: forward, track: selectedTrack) }
		default: break
		}
	}

	private func openJump() {
		playback.pause()
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
			Button(tool == .captioner ? (forward ? "Next Caption Point" : "Previous Caption Point") : (forward ? "Next Edit Point" : "Previous Edit Point")) {
				if let track = project.tracks.first(where: { $0.id == activeTrack }) {
					navigate(forward: forward, track: track)
				}
			}
		}
	}

	private func navigate(forward: Bool, track: TimelineTrack) {
		let point = tool == .captioner ? project.captionPoint(from: playback.position, forward: forward) :
			project.navigationPoint(from: playback.position, forward: forward, on: track)
		let label = point.name + ", " + time(point.time)
		playback.seek(point.time)
		playback.playhead.navigationLabel = label
		UIAccessibility.post(notification: .announcement, argument: label)
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
			guard let destination = project.tracks.first(where: { $0.id == clip.trackID }) else { return false }
			return drop(items, on: destination, beside: clip.id, after: after)
		})
		.editorMenuActions(name, actions)
	}

	private func trackActions(_ track: TimelineTrack) -> [EditorMenuAction] {
		var actions = [
			EditorMenuAction("Select Track") { keyboardClip = nil; activeTrack = track.id; playback.playhead.navigationLabel = nil; focus = track.id },
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

	private func cancelClipLoad() {
		clipTask?.cancel()
		clipTask = nil
		focus = trigger
	}

	private func importSource(_ load: @escaping () async throws -> ProjectMediaSource) {
		let replacing = reconnect
		clipTask = Task {
			defer { if !Task.isCancelled { clipTask = nil; focus = trigger } }
			do {
				var source = try await load()
				try Task.checkCancellation()
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
			} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
		}
	}

	private func openBoard(_ source: ProjectMediaSource, placement: ProjectPlacement?, rowID: String? = nil) {
		playback.pause()
		trigger = rowID ?? (placement?.id ?? source.id).uuidString
		clipTask = Task {
			defer { if !Task.isCancelled { clipTask = nil } }
			do {
				let access = try await source.open()
				try Task.checkCancellation()
				let session = try await CuttingBoardSession.openReferenced(asset: access.asset, title: placement?.displayName(for: source) ?? source.displayName, access: access, ranges: placement?.ranges.map(\.range))
				try await session.waitForOpeningPlayback()
				try Task.checkCancellation()
				board = ProjectBoard(source: source, placement: placement, session: session)
			} catch { if !Task.isCancelled { self.error = "Could not open " + source.displayName + ". Reconnect the clip in Project Media." } }
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
			update: board.placement == nil ? nil : { quick(.update) }, placementSheet: { directTouch in
				AnyView(PlacementSheet(tracks: project.tracks.filter { $0.kind == kind }, destination: destination(),
					offersAudio: kind == .video && board.source.hasAudio, directTouch: directTouch) { track, name, mode, omitAudio in
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
		next.version = max(next.version, next.captions != nil ? 4 : (next.additionalTracks?.contains(where: { $0.linkedVideoID != nil }) == true ? 3 : 2))
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
		if playback.playhead.navigationLabel != nil { playback.playhead.navigationLabel = nil }
		project = next
		let valid = Set(next.placements.map(\.id))
		marked.formIntersection(valid)
		dragging.formIntersection(valid)
		if !next.tracks.contains(where: { $0.id == activeTrack }) { activeTrack = TimelineTrack.primaryVideo.id }
		if rebuild { revision += 1 }
	}

	private func captionBinding(direct: Bool) -> Binding<CaptionEntry?> {
		Binding(get: { directTouch == direct ? captionEntry : nil }, set: {
			if directTouch == direct { captionEntry = $0 }
		})
	}

	private func openCaption(_ existing: CaptionCue?) {
		guard playback.ready, captionEntry == nil else { return }
		let cue: CaptionCue
		if let existing { cue = existing }
		else if let range = project.captionRange {
			cue = CaptionCue(start: ProjectTime(range.start), end: ProjectTime(range.end), text: "")
		} else {
			error = "Mark In and Out around the passage, then choose New Caption."
			return
		}
		playback.pause()
		captionTrigger = existing?.id.uuidString ?? "newCaption"
		captionCreated = false
		captionEntry = CaptionEntry(cue: cue, editing: existing != nil, returnTime: playback.position)
	}

	private func captionSheet(_ entry: CaptionEntry) -> some View {
		CaptionEntryView(entry: entry, playback: playback, markedRange: project.captionRange, time: time) { cue in
			guard cue.end.time <= project.duration else { throw ProjectFailure("Mark a range within the project and choose Use Marked Range.") }
			var next = project
			var cues = next.captions ?? []
			if entry.editing {
				guard let index = cues.firstIndex(where: { $0.id == cue.id }) else { throw ProjectFailure("Reopen the caption from the timeline.") }
				cues[index] = cue
			} else { cues.append(cue) }
			next.captions = cues.sorted { $0.start.time < $1.start.time }
			try save(next, action: entry.editing ? "Update Caption" : "Create Caption")
			captionCreated = !entry.editing
		}
	}

	private func finishCaption(direct: Bool) {
		if direct { surfaceFocused = true } else { focus = captionTrigger }
		if captionCreated {
			captionCreated = false
			let message = NSAttributedString(string: "Caption Created", attributes: [.accessibilitySpeechQueueAnnouncement: true])
			UIAccessibility.post(notification: .announcement, argument: message)
		}
	}

	private func projectKey(_ key: String, flags: UIKeyModifierFlags) {
		if tool == .captioner {
			switch key {
			case "c": openCaption(nil)
			case "\r":
				if let cue = project.captions?.first(where: { ($0.id.uuidString == (keyboardClip ?? focus)) }) ??
					project.captions?.first(where: { $0.start.time <= playback.position && playback.position < $0.end.time }) { openCaption(cue) }
			case " ", "k": playback.toggle()
			case "j", "l": playback.shuttle(forward: key == "l")
			case ";", "'": navigate(forward: key == "'", track: selectedTrack)
			case UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow:
				let forward = key == UIKeyCommand.inputRightArrow
				if flags.contains(.command) { navigate(forward: forward, track: selectedTrack) }
				else { step((forward ? 1 : -1) * (flags.contains(.shift) ? 10 : 1)) }
			case UIKeyCommand.inputHome, UIKeyCommand.inputUpArrow: playback.seek(.zero)
			case UIKeyCommand.inputEnd, UIKeyCommand.inputDownArrow: playback.seek(project.duration)
			case "i", "o":
				playback.pause()
				setMarker(key == "i", to: flags.contains(.alternate) ? nil : ProjectTime(playback.position))
			case "z": history(back: !flags.contains(.shift))
			case "t": UIAccessibility.post(notification: .announcement, argument: time(playback.position))
			default: break
			}
			return
		}
		let focusedRow = keyboardClip ?? focus
		let focusedID = focusedRow?.split(separator: "/").last.flatMap { UUID(uuidString: String($0)) }
		let focusedClip = project.placements.first { $0.id == focusedID }
		var trackID = focusedClip?.trackID ?? activeTrack
		if focusedRow?.hasPrefix("linked/") == true, let partner = project.audioPartner(for: trackID) { trackID = partner.id }
		guard let track = project.tracks.first(where: { $0.id == trackID }) else { return }
		let clips = project.displayedClips(on: track)
		let position = playback.position
		let clip = focusedClip ?? clips.first { $0.end > position }
		let destinationTrack = clip.flatMap { placement in project.tracks.first { $0.id == placement.trackID } } ?? track
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
					playback.playhead.navigationLabel = nil
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
				navigate(forward: forward, track: track)
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

private struct ProjectShuttleButton: View {
	let playback: ProjectPlayback
	let forward: Bool

	var body: some View {
		let rate = playback.transport.shuttleRate
		let active = forward ? rate > 0 : rate < 0
		let name = forward ? "Fast Forward" : "Rewind"
		Button { playback.shuttle(forward: forward) } label: {
			Image(systemName: forward ? "forward.fill" : "backward.fill")
				.accessibilityHidden(true)
		}
		.accessibilityLabel(Text(name))
		.buttonStyle(EditorButtonStyle(square: true, badge: active ? abs(rate).formatted() + "x" : nil, reservesBadgeSpace: true))
	}
}

private struct ProjectPlayButton: View {
	let playback: ProjectPlayback

	var body: some View {
		let playing = playback.transport.playing
		Button(action: playback.toggle) {
			Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
		}
	}
}

private struct ProjectPreview: UIViewRepresentable {
	let player: AVPlayer

	final class FrameView: UIView {
		override class var layerClass: AnyClass { AVPlayerLayer.self }
	}

	func makeUIView(context: Context) -> FrameView {
		let view = FrameView()
		view.backgroundColor = .black
		view.isAccessibilityElement = true
		view.accessibilityLabel = "Video frame"
		view.accessibilityTraits = .image
		return view
	}

	func updateUIView(_ view: FrameView, context: Context) {
		let layer = view.layer as! AVPlayerLayer
		if layer.player !== player { layer.player = player }
	}
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

private struct ProjectJumpSheet: View {
	let format: TimecodeFormat
	let frame: CMTime
	let seek: (CMTime) -> Void
	@Environment(\.dismiss) private var dismiss
	@FocusState private var typing: Bool
	@State private var text = ""
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				TextField(format == .frames ? "Frame" : "Time", text: $text)
					.focused($typing)
					.autocorrectionDisabled()
					.onSubmit(jump)
				if let error { Text(error) }
			}
			.editorListMargins()
			.dismissKeyboardToolbar(while: typing) { typing = false }
			.navigationTitle("Jump to Time")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .principal) { Text("Jump to Time").font(.headline).accessibilityAddTraits(.isHeader) }
				ToolbarItem(placement: .confirmationAction) { Button("Jump", action: jump) }
			}
		}
		.editorAppearance()
		.task { typing = true }
	}

	private func jump() {
		if format == .frames, let index = Int32(text), index >= 0 {
			seek(CMTimeMultiply(frame, multiplier: index))
		} else if format != .frames, let time = CuttingBoardSession.parse(text) {
			seek(time)
		} else {
			error = "Enter a valid playhead position and choose Jump."
			return
		}
		dismiss()
	}
}

private struct PlacementSheet: View {
	@FocusState private var namingTrack: Bool
	let tracks: [TimelineTrack]
	@State var destination: TimelineTrack
	let offersAudio: Bool
	let directTouch: Bool
	let save: (TimelineTrack, String?, PlacementMode, Bool) -> String?
	@State private var method = "New Track"
	@State private var choseMethod = false
	@State private var name = ""
	@State private var includeAudio = true
	@State private var error: String?
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			Form {
				if directTouch && !choseMethod {
					Button("Append to Track") { error = save(destination, nil, .append, false) }
					placementChoice("Add to New Track", method: "New Track")
					placementChoice("Overwrite at Playhead", method: "Overwrite")
					placementChoice("Insert and Split at Playhead", method: "Split")
				} else {
					if !directTouch {
						Picker("Placement", selection: $method) {
							ForEach(["New Track", "Overwrite", "Split"], id: \.self) { Text($0) }
						}
					}
					if method == "New Track" { TextField("Track Name", text: $name).focused($namingTrack) }
					else {
						Picker("Destination Track", selection: Binding(get: { destination.id }, set: { id in if let track = tracks.first(where: { $0.id == id }) { destination = track } })) {
							ForEach(tracks) { Text($0.title).tag($0.id) }
						}
					}
					if offersAudio { Toggle("Include Clip Audio", isOn: $includeAudio) }
				}
				if let error { Text(error) }
			}
			.editorListMargins()
			.dismissKeyboardToolbar(while: namingTrack) { namingTrack = false }
			.navigationTitle(directTouch && !choseMethod ? "Clip Placement" : "Add at Playhead")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .topBarTrailing) {
					if !directTouch || choseMethod {
						Button("Add") {
							error = save(destination, method == "New Track" ? name : nil, method == "Split" ? .split : .overwrite, !includeAudio)
						}.disabled(method == "New Track" && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					}
				}
			}
		}.editorAppearance()
	}

	private func placementChoice(_ title: String, method: String) -> some View {
		Button(title) {
			self.method = method
			error = nil
			choseMethod = true
		}
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
	let playback: ProjectPlayback
	let duration: CMTime
	let frame: CMTime
	let format: TimecodeFormat
	let formatTime: (CMTime) -> String

	var body: some View {
		VStack(spacing: 0) {
			Text("Playhead, " + formatTime(playhead.position))
				.monospacedDigit()
				.accessibilityHidden(true)
			ProjectSliderControl(playback: playback, position: playhead.position, duration: duration,
				frame: frame, format: format, formatTime: formatTime)
				.frame(minHeight: 44)
		}
	}
}

private struct ProjectSliderControl: UIViewRepresentable {
	let playback: ProjectPlayback
	let position: CMTime
	let duration: CMTime
	let frame: CMTime
	let format: TimecodeFormat
	let formatTime: (CMTime) -> String

	func makeUIView(context: Context) -> TimelineSlider {
		let slider = TimelineSlider()
		slider.accessibilityLabel = "Playhead"
		slider.semanticContentAttribute = .playback
		return slider
	}

	func updateUIView(_ slider: TimelineSlider, context: Context) {
		slider.control = self
		slider.isEnabled = context.environment.isEnabled
		slider.display(position)
	}

	static func dismantleUIView(_ slider: TimelineSlider, coordinator: ()) {
		slider.finishDrag(announce: false)
	}

	final class TimelineSlider: UISlider {
		var control: ProjectSliderControl?
		private var draggingPlayhead = false
		private var feedback: Task<Void, Never>?
		private var spokenValue: String?

		func display(_ time: CMTime) {
			guard let control else { return }
			let seconds = control.duration.seconds
			value = seconds > 0 ? Float(time.seconds / seconds) : 0
			accessibilityValue = control.playback.playhead.navigationLabel ?? spokenTime(time, control: control)
		}

		private func spokenTime(_ time: CMTime, control: ProjectSliderControl) -> String {
			let label = control.formatTime(time)
			guard control.format == .standard, control.duration.seconds < 10 else { return label }
			let ticks = CMTimeConvertScale(time, timescale: 1000, method: .roundTowardZero).value
			return label + String(format: ".%03lld", ticks % 1000)
		}

		override func accessibilityIncrement() { adjust(forward: true) }
		override func accessibilityDecrement() { adjust(forward: false) }

		private func adjust(forward: Bool) {
			guard isEnabled, let control else { return }
			finishDrag(announce: false)
			let interval = min(5, control.duration.seconds / 10)
			let delta = CMTime(seconds: interval, preferredTimescale: 600000)
			let current = control.playback.position
			control.playback.seek(forward ? current + delta : current - delta)
			display(control.playback.position)
		}

		override func accessibilityPerformMagicTap() -> Bool {
			guard isEnabled, let control else { return false }
			finishDrag(announce: false)
			control.playback.toggle()
			return true
		}

		override func accessibilityElementDidBecomeFocused() {
			super.accessibilityElementDidBecomeFocused()
			control?.playback.primeScrubAudio()
		}

		override func accessibilityElementDidLoseFocus() {
			super.accessibilityElementDidLoseFocus()
			finishDrag(announce: false)
		}

		override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
			guard isEnabled, let control else { return false }
			_ = super.beginTracking(touch, with: event)
			control.playback.setScrubbing(true)
			draggingPlayhead = control.playback.scrubbing
			spokenValue = nil
			move(to: touch)
			return draggingPlayhead
		}

		override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
			guard draggingPlayhead else { return false }
			move(to: touch)
			return true
		}

		override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
			if let touch { move(to: touch) }
			super.endTracking(touch, with: event)
			finishDrag(announce: true)
		}

		override func cancelTracking(with event: UIEvent?) {
			super.cancelTracking(with: event)
			finishDrag(announce: false)
		}

		private func move(to touch: UITouch) {
			guard draggingPlayhead, let control, control.playback.scrubbing else { return }
			let track = trackRect(forBounds: bounds)
			let left = thumbRect(forBounds: bounds, trackRect: track, value: minimumValue).midX
			let right = thumbRect(forBounds: bounds, trackRect: track, value: maximumValue).midX
			guard left != right else { return }
			let fraction = min(1, max(0, (touch.location(in: self).x - left) / (right - left)))
			let frames = (fraction * control.duration.seconds / control.frame.seconds).rounded()
			let target = fraction == 1 ? control.duration : min(control.duration, CMTimeMultiplyByFloat64(control.frame, multiplier: frames))
			control.playback.scrub(to: target)
			display(target)
			feedback?.cancel()
			guard UIAccessibility.isVoiceOverRunning else { return }
			feedback = Task { [weak self] in
				do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
				guard control.playback.scrubbing else { return }
				self?.speakIfNeeded()
			}
		}

		private func speakIfNeeded() {
			guard let control, UIAccessibility.isVoiceOverRunning, accessibilityElementIsFocused(),
				control.playback.scrubbing, control.playback.audibleScrubPosition != control.playback.position else { return }
			let time = spokenTime(control.playback.position, control: control)
			if spokenValue != time {
				spokenValue = time
				UIAccessibility.post(notification: .announcement, argument: time)
			}
		}

		func finishDrag(announce: Bool) {
			feedback?.cancel()
			feedback = nil
			guard draggingPlayhead else { return }
			draggingPlayhead = false
			if announce { speakIfNeeded() }
			control?.playback.setScrubbing(false)
		}
	}
}

private struct ProjectTouchSurface: UIViewRepresentable {
	@ObservedObject var playhead: ProjectPlayhead
	let playback: ProjectPlayback
	let duration: CMTime
	let captioning: Bool
	let trackName: String
	let mode: DirectTouchScrubbing
	let close: () -> Void
	let swipe: (Int, UISwipeGestureRecognizer.Direction) -> Void

	func makeUIView(context: Context) -> Surface {
		let view = Surface()
		view.isAccessibilityElement = true
		view.accessibilityLabel = "Direct Touch Editor"
		view.accessibilityTraits = .allowsDirectInteraction
		view.installTimelineGestures(projectTimeline: true, captioning: captioning)
		view.backgroundColor = UIColor(EditorTheme.surface)
		view.video.videoGravity = .resizeAspect
		view.layer.addSublayer(view.cursor)
		return view
	}

	func updateUIView(_ view: Surface, context: Context) {
		view.control = self
		if view.accessibilityValue != trackName { view.accessibilityValue = trackName }
		if view.video.player !== playback.player { view.video.player = playback.player }
		view.setNeedsLayout()
	}

	static func dismantleUIView(_ view: Surface, coordinator: ()) {
		view.control?.playback.setScrubbing(false)
		view.video.player = nil
		view.control = nil
	}

	final class Surface: UIView, TimelineGestureHandling {
		override class var layerClass: AnyClass { AVPlayerLayer.self }
		var video: AVPlayerLayer { layer as! AVPlayerLayer }
		let cursor = CALayer()
		var control: ProjectTouchSurface?
		private var origin: CMTime = .zero
		private var startX: CGFloat = 0
		private var dragWidth: CGFloat = 0

		override func layoutSubviews() {
			super.layoutSubviews()
			guard let control else { return }
			let fraction = control.duration > .zero ? control.playhead.position.seconds / control.duration.seconds : 0
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			cursor.backgroundColor = UIColor(EditorTheme.playhead).resolvedColor(with: traitCollection).cgColor
			cursor.frame = CGRect(x: max(0, bounds.width - 3) * min(1, max(0, fraction)), y: 0, width: 3, height: bounds.height)
			CATransaction.commit()
		}

		@objc func closeEditor() { control?.close() }
		@objc func toggle() { control?.playback.toggle() }
		override func accessibilityPerformMagicTap() -> Bool { toggle(); return true }

		@objc func swipe(_ gesture: UISwipeGestureRecognizer) {
			control?.swipe(gesture.numberOfTouchesRequired, gesture.direction)
		}

		@objc func scrub(_ hold: UILongPressGestureRecognizer) {
			guard let control else { return }
			let playback = control.playback
			let x = hold.location(in: self).x
			if hold.state == .began {
				playback.setScrubbing(true)
				origin = playback.position
				startX = x
				dragWidth = bounds.width
			}
			guard playback.scrubbing else { return }
			if hold.state == .cancelled || hold.state == .failed || bounds.width != dragWidth {
				playback.setScrubbing(false)
				return
			}
			let target = control.mode.time(at: x, width: dragWidth, startX: startX, origin: origin, duration: control.duration)
			playback.scrub(to: target)
			if hold.state == .ended { playback.setScrubbing(false) }
		}
	}
}
