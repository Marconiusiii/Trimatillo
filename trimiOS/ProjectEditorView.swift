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
	@State private var activeTrack = TimelineTrack.primaryVideo.id
	@State private var marked: Set<UUID> = []
	@State private var dropAnchor: UUID?
	@State private var dropAfter = false
	@State private var dragging: Set<UUID> = []
	@State private var effects: TimelineTrack?
	@FocusState private var keyboardClip: UUID?
	@State private var expanded = true
	@State private var board: ProjectBoard?
	@State private var pickingFile = false
	@State private var pickingPhoto = false
	@State private var photo: PhotosPickerItem?
	@State private var renaming: ProjectMediaSource?
	@State private var clipName = ""
	@State private var reconnect: UUID?
	@State private var busy = false
	@State private var revision = 0
	@State private var undo: [EditingProject] = []
	@State private var redo: [EditingProject] = []
	@State private var error: String?
	@State private var fullScreenPreview: PreviewPlayback?
	@State private var jumping = false
	@State private var jumpText = ""
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@AccessibilityFocusState private var focus: String?
	@State private var trigger: String?
	@Environment(\.scenePhase) private var phase

	var body: some View {
		ProjectEditorKeyboard(enabled: renaming == nil && fullScreenPreview == nil && board == nil && effects == nil && !jumping && error == nil && !busy && !pickingPhoto && !pickingFile,
			perform: projectKey) { editor }
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
						}
						projectRows
					}
				}
			}
			.disabled(busy)
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle(project.name)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Close") { playback.pause(); close() }.disabled(busy) }
			}
			.sheet(item: $effects, onDismiss: { focus = trigger }) { track in
				TrackEffectsSheet(track: track, volume: project.trackVolumes?[track.id] ?? 1) { volume in
					var next = project
					var levels = next.trackVolumes ?? [:]
					levels[track.id] = volume
					next.trackVolumes = levels
					do { try save(next); effects = nil; return nil }
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
			.fullScreenCover(item: $fullScreenPreview, onDismiss: { focus = "fullScreenPreview" }) { preview in
				FullScreenPreview(playback: preview)
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
		.task(id: board == nil ? revision : nil) {
			guard board == nil else { return }
			await playback.prepare(project)
		}
		.onChange(of: dragging) { _, ids in if ids.isEmpty { dropAnchor = nil } }
		.onChange(of: playback.failure) { _, message in
			if let message { error = message; playback.failure = nil }
		}
		.onChange(of: phase) { _, phase in if phase != .active { playback.pause() } }
		.onDisappear { playback.pause() }
	}

	private var pictureAspect: CGFloat {
		CGFloat(project.picture?.width ?? 16) / CGFloat(max(1, project.picture?.height ?? 9))
	}

	private var preview: some View {
		ProjectPreview(player: playback.player)
			.aspectRatio(pictureAspect, contentMode: .fit)
			.accessibilityHidden(true)
	}

	@ViewBuilder private var projectRows: some View {
		transport
		DisclosureGroup("Project Media", isExpanded: $expanded) {
			sourcePicker("Import Clip", source: nil)
			ForEach(project.sources) { source in
				Menu(source.displayName) {
					Button("Open Cutting Board") { openBoard(source, placement: nil) }
					Button("Rename Clip") { beginRename(source) }
					Button("Reconnect from Files") { pick(source.id, files: true) }
					Button("Reconnect from Photos") { pick(source.id, files: false) }
				}
				.accessibilityAction(named: "Rename Clip") { beginRename(source) }
				.accessibilityFocused($focus, equals: source.id.uuidString)
			}
		}
		ForEach(project.tracks) { track in
			Section {
				let clips = project.clips(on: track)
				if clips.isEmpty {
					Text("No clips")
						.accessibilityDropPoint(.center, description: Text("Drop on " + track.title))
						.dropDestination(for: String.self) { items, _ in drop(items, on: track, beside: nil, after: false) }
				} else {
					ScrollView(.horizontal) {
						HStack {
							ForEach(clips) { clip in
								if let source = project.sources.first(where: { $0.id == clip.sourceID }) {
									clipButton(clip, source: source, track: track)
								}
							}
						}
					}
				}
			} header: {
				Menu { trackActions(track) } label: {
					HStack {
						Text(track.title)
						if activeTrack == track.id { Image(systemName: "checkmark").accessibilityHidden(true) }
						Image(systemName: "chevron.down").accessibilityHidden(true)
					}
				}
					.accessibilityValue(activeTrack == track.id ? "Selected" : "")
					.accessibilityAddTraits(.isHeader)
					.accessibilityActions { trackActions(track) }
					.contextMenu { trackActions(track) }
					.accessibilityFocused($focus, equals: track.id)
					.dropDestination(for: String.self) { items, _ in drop(items, on: track, beside: nil, after: true) }
			}
		}
		if let seconds = project.targetSeconds { LabeledContent("Project Duration", value: time(CMTime(seconds: seconds, preferredTimescale: 60000))) }
		if busy { ProgressView("Opening clip") }
	}

	private var transport: some View {
		Group {
			Button { playback.pause(); jumpText = ""; jumping = true } label: {
				LabeledContent("Playhead", value: time(playback.position))
			}
			.accessibilityFocused($focus, equals: "playhead")
			HStack {
				Button { playback.seek(playback.position - project.frame) } label: { Label("Step Back", systemImage: "backward.frame") }
				Button { playback.toggle() } label: { Label(playback.playing ? "Pause" : "Play", systemImage: playback.playing ? "pause.fill" : "play.fill") }.disabled(!playback.ready)
				Button { playback.seek(playback.position + project.frame) } label: { Label("Step Forward", systemImage: "forward.frame") }
				if project.placements.contains(where: { $0.track == .video }) {
					Button { fullScreenPreview = playback.makePreview() } label: {
						Label("Full Screen Preview", systemImage: "arrow.up.left.and.arrow.down.right")
					}
					.disabled(!playback.ready)
					.accessibilityFocused($focus, equals: "fullScreenPreview")
				}
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
					.disabled(project.placements.isEmpty)
				}
				Menu("Undo") {
					Button("Undo") { history(back: true) }.disabled(undo.isEmpty)
					Button("Redo") { history(back: false) }.disabled(redo.isEmpty)
				}.disabled(undo.isEmpty && redo.isEmpty)
			}.buttonStyle(.bordered)
		}
	}

	private func clipButton(_ clip: ProjectPlacement, source: ProjectMediaSource, track: TimelineTrack) -> some View {
		let name = clip.displayName(for: source)
		return Menu {
			clipActions(clip, source: source)
		} label: {
			HStack {
				if marked.contains(clip.id) { Image(systemName: "checkmark").accessibilityHidden(true) }
				Text(name)
			}
		}
		.buttonStyle(.bordered)
		.accessibilityLabel(name)
		.accessibilityValue((marked.contains(clip.id) ? "Marked, " : "") + "Start " + time(clip.start.time) + ", duration " + time(clip.duration))
		.accessibilityActions { clipActions(clip, source: source) }
		.contextMenu { clipActions(clip, source: source) }
		.focused($keyboardClip, equals: clip.id)
		.accessibilityFocused($focus, equals: clip.id.uuidString)
		.draggable(payload(for: clip))
		.accessibilityDragPoint(.center, description: Text(name))
		.modifier(ClipDropTarget { items, after in drop(items, on: track, beside: clip.id, after: after) })
	}

	@ViewBuilder private func trackActions(_ track: TimelineTrack) -> some View {
		Button("Select Track") { keyboardClip = nil; activeTrack = track.id; focus = track.id }
		Button("Track Effects") { trigger = track.id; playback.pause(); effects = track }
		if !dragging.isEmpty && project.clips(on: track).isEmpty && project.placements.filter({ dragging.contains($0.id) }).allSatisfy({ $0.track == track.kind }) {
			Button("Drop on Track") { move(dragging, on: track, beside: nil, after: false) }
		}
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
			try next.move(ids, to: track, beside: clip, after: after)
			try save(next)
			dragging.removeAll()
			activeTrack = track.id
			return true
		} catch { self.error = error.localizedDescription; return false }
	}

	private func toggleMark(_ id: UUID) {
		if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
	}

	@ViewBuilder private func clipActions(_ clip: ProjectPlacement, source: ProjectMediaSource) -> some View {
		Button("Open Cutting Board") { openBoard(source, placement: clip) }
		Button(marked.contains(clip.id) ? "Unmark for Editing" : "Mark for Editing") { toggleMark(clip.id) }
		if dragging.isEmpty {
			Button("Start Drag") { dragging = marked.contains(clip.id) ? marked : [clip.id] }
		} else {
			if !dragging.contains(clip.id), let track = project.tracks.first(where: { $0.id == clip.trackID }),
				project.placements.filter({ dragging.contains($0.id) }).allSatisfy({ $0.track == clip.track }) {
				Button("Add to Drag") { dragging.insert(clip.id) }
				Button("Drop Before") { move(dragging, on: track, beside: clip.id, after: false) }
				Button("Drop After") { move(dragging, on: track, beside: clip.id, after: true) }
			}
			Button("Cancel Drag") { dragging.removeAll() }
		}
		Button("Go to Start") { playback.seek(clip.start.time) }
		Button("Go to End") { playback.seek(clip.end) }
		Button("Remove from Track") {
			var next = project
			next.placements.removeAll { $0.id == clip.id }
			commit(next)
		}
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
		if project != next { commit(next) }
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
					source.projectName = original.projectName
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
		try save(next)
		activeTrack = destination.id
		if updating { board = nil }
		else { UIAccessibility.post(notification: .announcement, argument: (mode == .append ? "Appended to " : "Added to ") + destination.title) }
	}

	private func commit(_ next: EditingProject) {
		do { try save(next) } catch { self.error = error.localizedDescription }
	}

	private func save(_ next: EditingProject) throws {
		var next = next
		if let point = next.markIn, point.time > next.duration { next.markIn = nil }
		if let point = next.markOut, point.time > next.duration { next.markOut = nil }
		next.version = 2
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
		let rebuild = project.placements != next.placements || project.sources.map(\.reference) != next.sources.map(\.reference) || project.tracks != next.tracks || project.trackVolumes != next.trackVolumes
		project = next
		let valid = Set(next.placements.map(\.id))
		marked.formIntersection(valid)
		dragging.formIntersection(valid)
		if !next.tracks.contains(where: { $0.id == activeTrack }) { activeTrack = TimelineTrack.primaryVideo.id }
		if rebuild { revision += 1 }
	}

	private func projectKey(_ key: String, flags: UIKeyModifierFlags) {
		let focusedID = keyboardClip ?? focus.flatMap(UUID.init(uuidString:))
		let focusedClip = project.placements.first { $0.id == focusedID }
		let trackID = focusedClip?.trackID ?? activeTrack
		guard let track = project.tracks.first(where: { $0.id == trackID }) else { return }
		let clips = project.clips(on: track)
		let position = playback.position
		let clip = focusedClip ?? clips.first { $0.end > position }
		var next = project
		switch key {
		case " " where !dragging.isEmpty && dropAnchor != nil:
			if let anchor = project.placements.first(where: { $0.id == dropAnchor }),
				let destination = project.tracks.first(where: { $0.id == anchor.trackID }) {
				move(dragging, on: destination, beside: anchor.id, after: dropAfter)
			}
		case " " where focusedClip != nil:
			if dragging.isEmpty, let clip { dragging = marked.contains(clip.id) ? marked : [clip.id] }
			else if let clip, !dragging.contains(clip.id) { move(dragging, on: track, beside: clip.id, after: true) }
			else { dragging.removeAll() }
		case " ", "k": playback.toggle()
		case "j", "l": playback.shuttle(forward: key == "l")
		case "s":
			if let clip {
				if flags.contains(.shift), !dragging.isEmpty {
					if project.placements.filter({ dragging.contains($0.id) }).allSatisfy({ $0.track == clip.track }) { dragging.insert(clip.id) }
				} else { toggleMark(clip.id) }
			}
		case UIKeyCommand.inputEscape: dragging.removeAll(); dropAnchor = nil
		case "v": if !dragging.isEmpty { move(dragging, on: track, beside: clip?.id, after: true) }
		case "c", "\r":
			if let clip, let source = project.sources.first(where: { $0.id == clip.sourceID }) { openBoard(source, placement: clip) }
		case "z": history(back: !flags.contains(.shift))
		case "t": UIAccessibility.post(notification: .announcement, argument: time(position))
		case "i", "o":
			playback.pause()
			let point = flags.contains(.alternate) ? nil : ProjectTime(playback.position)
			if key == "i" { next.markIn = point } else { next.markOut = point }
			commit(next)
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
				if let index = indices.first(where: { !group.contains(clips[$0].id) }) {
					if dragging.isEmpty { move(group, on: track, beside: clips[index].id, after: forward) }
					else {
						dropAnchor = clips[index].id
						dropAfter = forward
						focus = clips[index].id.uuidString
						keyboardClip = clips[index].id
					}
				}
			} else if flags.contains(.command) || key == "'" || key == ";" {
				let points = ([CMTime.zero, project.duration] + clips.flatMap { [$0.start.time, $0.end] } +
					[project.markIn?.time, project.markOut?.time].compactMap { $0 }).sorted()
				playback.seek(forward ? points.first(where: { $0 > position }) ?? project.duration : points.last(where: { $0 < position }) ?? .zero)
			} else {
				let count: Int32 = flags.contains(.shift) ? 10 : 1
				playback.seek(position + CMTimeMultiply(project.frame, multiplier: forward ? count : -count))
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
			commit(next)
		case "\u{8}", UIKeyCommand.inputDelete:
			if let clip {
				let ids: Set<UUID> = marked.contains(clip.id) ? marked : [clip.id]
				next.placements.removeAll { ids.contains($0.id) }
				commit(next)
			}
		default: break
		}
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

private struct ClipDropTarget: ViewModifier {
	let perform: ([String], Bool) -> Bool
	@State private var width: CGFloat = 0

	func body(content: Content) -> some View {
		content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
			.dropDestination(for: String.self) { items, location in perform(items, location.x >= width / 2) }
			.accessibilityDropPoint(.leading, description: Text("Drop Before"))
			.accessibilityDropPoint(.trailing, description: Text("Drop After"))
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
