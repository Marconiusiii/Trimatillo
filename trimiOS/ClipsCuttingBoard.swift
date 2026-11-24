import AVFoundation
import SwiftUI

struct ClipsBoardRequest: Identifiable {
	let id = UUID()
	let project: EditingProject
	let track: TimelineTrack
	let ids: Set<UUID>
}

struct ClipsBoardModel {
	struct Member {
		let clip: ProjectPlacement
		let start: CMTime
		var end: CMTime { start + clip.duration }
	}
	let request: ClipsBoardRequest
	let members: [Member]
	let original: ClipEditTimeline

	init(_ request: ClipsBoardRequest) throws {
		let clips = request.project.displayedClips(on: request.track).filter { request.ids.contains($0.id) }
		guard clips.count == request.ids.count, clips.count > 1 else {
			throw ProjectFailure("Select at least two clips on the same track.")
		}
		var cursor = CMTime.zero
		members = clips.map { clip in
			defer { cursor = cursor + clip.duration }
			return Member(clip: clip, start: cursor)
		}
		original = ClipEditTimeline(sourceRanges: members.map { CMTimeRange(start: $0.start, end: $0.end) })
		self.request = request
	}

	func ranges(for member: Member, timeline: ClipEditTimeline) -> [ProjectRange] {
		let source = ClipEditTimeline(sourceRanges: member.clip.ranges.map(\.range))
		return timeline.sourceRanges.flatMap { range -> [ProjectRange] in
			let overlap = range.intersection(CMTimeRange(start: member.start, end: member.end))
			guard overlap.isValid, overlap.duration > .zero else { return [] }
			return source.sourceRanges(in: CMTimeRange(start: overlap.start - member.start, duration: overlap.duration)).map(ProjectRange.init)
		}
	}

	func project(timeline: ClipEditTimeline, settings: EditingProject, preview: Bool) -> EditingProject {
		var result = settings
		var updated: [UUID: ProjectPlacement] = [:]
		var cursor = CMTime.zero
		for member in members {
			var clip = settings.placements.first { $0.id == member.clip.id } ?? member.clip
			clip.ranges = ranges(for: member, timeline: timeline)
			guard !clip.ranges.isEmpty else { continue }
			if preview { clip.start = ProjectTime(cursor); cursor = cursor + clip.duration }
			updated[clip.id] = clip
		}
		if preview {
			result.placements = members.compactMap { updated[$0.clip.id] }
			result.audioDescriptions = nil
			result.descriptiveTranscript = nil
			result.captions = nil
			result.markIn = nil
			result.markOut = nil
		} else {
			result.placements = settings.placements.compactMap { clip in
				var value: ProjectPlacement
				if request.ids.contains(clip.id) {
					guard let replacement = updated[clip.id] else { return nil }
					value = replacement
				} else { value = clip }
				if let track = settings.tracks.first(where: { $0.id == value.trackID }), settings.isMagnetic(track) {
					let removed = members.filter { $0.clip.trackID == value.trackID && $0.clip.start.time < clip.start.time }
						.reduce(CMTime.zero) { $0 + $1.clip.duration - (updated[$1.clip.id]?.duration ?? .zero) }
					value.start = ProjectTime(clip.start.time - removed)
				}
				return value
			}
		}
		result.cleanTransitions()
		return result
	}
}

struct ClipsCuttingBoardView: View {
	let model: ClipsBoardModel
	let save: (EditingProject) throws -> Void
	@Environment(\.dismiss) private var dismiss
	@StateObject private var playback = ProjectPlayback()
	@State private var timeline: ClipEditTimeline
	@State private var settings: EditingProject
	@State private var undo: [(ClipEditTimeline, EditingProject, String, CMTime?, CMTime?)] = []
	@State private var redo: [(ClipEditTimeline, EditingProject, String, CMTime?, CMTime?)] = []
	@State private var markIn: CMTime?
	@State private var markOut: CMTime?
	@State private var revision = 0
	@State private var loading = true
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@State private var error: String?
	@State private var direct = false
	@State private var compositing = false
	@State private var fade: ProjectTransitionRequest?
	@State private var jump = false
	@State private var join: GroupJoinRequest?
	@State private var closeConfirmation = false
	@AccessibilityFocusState private var focus: String?
	@AppStorage("directTouchScrubbing", store: EditorPreferences.shared) private var scrubMode = DirectTouchScrubbing.absolute

	init(model: ClipsBoardModel, save: @escaping (EditingProject) throws -> Void) {
		self.model = model; self.save = save
		_timeline = State(initialValue: model.original)
		_settings = State(initialValue: model.request.project)
	}
	private var preview: EditingProject { model.project(timeline: timeline, settings: settings, preview: true) }
	private var selection: CMTimeRange? {
		guard let markIn, let markOut, markOut > markIn else { return nil }
		return CMTimeRange(start: markIn, end: markOut)
	}
	private func time(_ value: CMTime) -> String {
		if format == .frames {
			let frame = preview.frame
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
	private var enabled: Bool { !loading && fade == nil && !compositing && !jump && join == nil && error == nil && !direct }

	var body: some View {
		ProjectEditorKeyboard(playback: playback, enabled: enabled, groupEditing: true,
			undoShake: { history(back: true); return true }, perform: key) {
			NavigationStack {
				Group {
					if loading { LoadingStatusView("Preparing Clips Cutting Board") }
					else {
						List {
							if model.request.track.kind == .video {
								ProjectPreview(player: playback.player).aspectRatio(CGFloat(settings.picture?.width ?? 16) / CGFloat(settings.picture?.height ?? 9), contentMode: .fit)
							}
							ProjectTimelineSlider(playhead: playback.playhead, playback: playback, duration: preview.duration, points: points, frame: preview.frame, format: format, formatTime: time)
							LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 0)], spacing: 0) {
								transport("Previous Edit Point", "backward.end") { navigate(false) }
								transport("Step Back", "backward.frame") { playback.stepWithAudio(forward: false, frame: preview.frame) }
									.accessibilityAction(named: "Step Back 10 Frames") { playback.stepWithAudio(forward: false, frame: preview.frame, count: 10) }
									.accessibilityAction(named: "Previous Edit Point") { navigate(false) }
								transport("Rewind", "backward.fill") { playback.shuttle(forward: false) }.accessibilityAction(named: "Go to Start") { playback.seek(.zero) }
								transport(playback.transport.playing ? "Pause" : "Play", playback.transport.playing ? "pause.fill" : "play.fill") { playback.toggle() }
								transport("Fast Forward", "forward.fill") { playback.shuttle(forward: true) }.accessibilityAction(named: "Go to End") { playback.seek(preview.duration) }
								transport("Step Forward", "forward.frame") { playback.stepWithAudio(forward: true, frame: preview.frame) }
									.accessibilityAction(named: "Step Forward 10 Frames") { playback.stepWithAudio(forward: true, frame: preview.frame, count: 10) }
									.accessibilityAction(named: "Next Edit Point") { navigate(true) }
								transport("Next Edit Point", "forward.end") { navigate(true) }
							}
							Button("Mark In") { marker(true) }.accessibilityValue(markIn.map(time) ?? "Not set")
							Button("Mark Out") { marker(false) }.accessibilityValue(markOut.map(time) ?? "Not set")
							Button("Jump to Time") { jump = true }.accessibilityFocused($focus, equals: "jump")
							Button("Direct Touch Editor") { direct = true }.accessibilityFocused($focus, equals: "direct")
							Menu("Edit Actions") { EditorMenuAction.buttons(editActions) }
								.editorMenuActions("Edit Actions", editActions).accessibilityFocused($focus, equals: "edit")
							Menu("Effects") { EditorMenuAction.buttons(effectActions) }
								.editorMenuActions("Effects", effectActions).accessibilityFocused($focus, equals: "effects")
							Button("Undo") { history(back: true) }.accessibilityAction(named: "Redo") { history(back: false) }
							Button("Save Changes", action: commit)
						}.editorListMargins()
					}
				}
				.toolbar {
					ToolbarItem(placement: .cancellationAction) { Button("Close") { if undo.isEmpty { dismiss() } else { closeConfirmation = true } } }
					ToolbarItem(placement: .principal) { Text("Clips Cutting Board").accessibilityAddTraits(.isHeader) }
				}
				.alert("Close Clips Cutting Board?", isPresented: $closeConfirmation) {
					Button("Discard Changes", role: .destructive) { dismiss() }
					Button("Cancel", role: .cancel) {}
				} message: { Text("Close without applying these edits to the selected clips?") }
			}.editorAppearance()
		}
		.accessibilityAction(.magicTap) { if !loading { playback.toggle() } }
		.task(id: revision) {
			loading = true
			await playback.prepare(preview, audition: model.request.track)
			for _ in 0..<300 {
				guard !Task.isCancelled else { return }
				if playback.ready || playback.failure != nil { break }
				try? await Task.sleep(for: .milliseconds(100))
			}
			guard !Task.isCancelled else { return }
			if !playback.ready && playback.failure == nil {
				playback.cancelPreparation()
				error = "Could not prepare the selected clips. Close and reopen Clips Cutting Board."
				loading = false
			}
			if let failure = playback.failure { error = failure; loading = false }
		}
		.onChange(of: playback.ready) { if playback.ready { loading = false } }
		.onChange(of: playback.failure) { if let failure = playback.failure { error = failure; loading = false } }
		.onDisappear { playback.cancelPreparation(); playback.releaseAudio() }
		.alert("Clips Cutting Board", isPresented: Binding(get: { error != nil && !direct }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
		.sheet(isPresented: $jump, onDismiss: { focus = "jump" }) {
			ProjectJumpSheet(format: format, frame: preview.frame, seek: playback.seek)
		}
		.sheet(item: Binding(get: { direct ? nil : join }, set: { if !direct { join = $0 } }), onDismiss: { focus = "edit" }, content: joinSheet)
		.sheet(item: $fade, onDismiss: { focus = "effects" }) { request in
			TransitionEditorView(project: preview, request: request, format: format, formatTime: time) { edited, action in
				var next = settings
				next.transitions = (settings.transitions ?? []).filter { effect in
					![effect.incoming, effect.outgoing].compactMap { $0 }.allSatisfy { model.request.ids.contains($0) }
				} + (edited.transitions ?? [])
				change(timeline, next, action)
			}
		}
		.sheet(isPresented: $compositing, onDismiss: { focus = "effects" }) {
			if let clip = preview.placements.first {
				ClipCompositingSheet(project: preview, clip: clip, selectedIDs: model.request.ids) { edited, action in
					var next = settings
					for i in next.placements.indices where model.request.ids.contains(next.placements[i].id) {
						next.placements[i].compositing = edited.placements.first { $0.id == next.placements[i].id }?.compositing
					}
					change(timeline, next, action)
				}
			}
		}
		.fullScreenCover(isPresented: $direct, onDismiss: { focus = "direct" }) {
			NavigationStack {
				ProjectTouchSurface(playhead: playback.playhead, playback: playback, formatTime: time, transitions: nil,
					duration: preview.duration, captioning: false, editDescription: openJoin, trackName: "Clips Cutting Board", mode: scrubMode,
					close: { direct = false }, swipe: swipe, clipEditing: true)
				.toolbar {
					ToolbarItem(placement: .cancellationAction) { Button("Close") { direct = false } }
					ToolbarItem(placement: .principal) { Text("Clips Cutting Board").accessibilityAddTraits(.isHeader) }
				}
			}
			.sheet(item: $join, onDismiss: { announce("In Direct Touch Editor") }, content: joinSheet)
			.alert("Clips Cutting Board", isPresented: Binding(get: { error != nil && direct }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
			.editorAppearance()
		}
	}

	private var editActions: [EditorMenuAction] {
		[EditorMenuAction("Trim Head to Playhead") { cut(.head) },
		EditorMenuAction("Trim Tail to Playhead") { cut(.tail) },
		EditorMenuAction("Delete Marked Range") { cut(.range) },
		EditorMenuAction("Adjust Edit Point", openJoin),
		EditorMenuAction("Clear In") { clearMarker(true) },
		EditorMenuAction("Clear Out") { clearMarker(false) }]
	}
	private var effectActions: [EditorMenuAction] {
		var actions = [EditorMenuAction("Quick Fade", openFade)]
		if model.request.track.kind == .video { actions.append(EditorMenuAction("Compositing") { playback.pause(); compositing = true }) }
		return actions
	}
	private func joinSheet(_ request: GroupJoinRequest) -> some View {
		GroupJoinView(point: request.point, frame: preview.frame, format: format, formatTime: time) { incoming, outgoing in
			if incoming == request.point.inTime && outgoing == request.point.outTime { return }
			guard incoming > request.point.precedingStart, outgoing < request.point.followingEnd, incoming <= outgoing else { throw ClipEditError.invalidSelection }
			var ranges = timeline.sourceRanges
			ranges[request.point.index] = CMTimeRange(start: request.point.precedingStart, end: incoming)
			ranges[request.point.index + 1] = CMTimeRange(start: outgoing, end: request.point.followingEnd)
			let changed = ClipEditTimeline(sourceRanges: ranges)
			change(changed, settings, "Adjust Edit Point")
		}
	}

	private var points: [CMTime] { [.zero, preview.duration] + preview.placements.flatMap { [$0.start.time, $0.end] } + timeline.editPoints.map(\.time) + [markIn, markOut].compactMap { $0 } }
	private func transport(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
		Button(action: action) { Label(title, systemImage: icon).labelStyle(.iconOnly).frame(minWidth: 44, maxWidth: .infinity, minHeight: 44) }
	}
	private func announce(_ message: String) { UIAccessibility.post(notification: .announcement, argument: message) }
	private func marker(_ incoming: Bool) {
		let position = playback.position
		undo.append((timeline, settings, incoming ? "Mark In" : "Mark Out", markIn, markOut)); redo.removeAll()
		let remove = (incoming ? markIn : markOut) == position
		if incoming { markIn = remove ? nil : position } else { markOut = remove ? nil : position }
		announce(remove ? (incoming ? "In Removed" : "Out Removed") : (incoming ? "Marked In" : "Marked Out"))
	}
	private func clearMarker(_ incoming: Bool) {
		guard (incoming ? markIn : markOut) != nil else { return }
		undo.append((timeline, settings, incoming ? "Clear In" : "Clear Out", markIn, markOut)); redo.removeAll()
		if incoming { markIn = nil } else { markOut = nil }
	}
	private func navigate(_ forward: Bool) {
		let target = forward ? points.filter { $0 > playback.position }.min() ?? preview.duration : points.filter { $0 < playback.position }.max() ?? .zero
		playback.seek(target)
		let clip = preview.placements.first { $0.start.time == target }
		let name = clip.flatMap { clip in settings.sources.first { $0.id == clip.sourceID }.map { clip.displayName(for: $0) } }
		announce(target == .zero ? "Start" : target == preview.duration ? "End" : (name ?? "Edit Point") + ", " + time(target))
	}
	private enum Cut { case head, tail, range }
	private func cut(_ kind: Cut) {
		do {
			let range: CMTimeRange
			let action: String
			switch kind {
			case .head: range = CMTimeRange(start: .zero, end: playback.position); action = "Trim Head"
			case .tail: range = CMTimeRange(start: playback.position, end: timeline.duration); action = "Trim Tail"
			case .range:
				guard let selection else { throw ClipEditError.invalidSelection }
				range = selection; action = "Delete Marked Range"
			}
			var changed = timeline
			try changed.delete(editedRange: range)
			change(changed, settings, action)
			announce(kind == .head ? "Head Trimmed to Playhead" : kind == .tail ? "Tail Trimmed to Playhead" : "Content Deleted")
		} catch { self.error = error.localizedDescription }
	}
	private func change(_ next: ClipEditTimeline, _ settings: EditingProject, _ action: String) {
		playback.pause()
		undo.append((timeline, self.settings, action, markIn, markOut)); redo.removeAll()
		timeline = next; self.settings = settings
		markIn = nil; markOut = nil; revision += 1
	}
	private func history(back: Bool) {
		guard let entry = back ? undo.popLast() : redo.popLast() else { return }
		let current = (timeline, settings, entry.2, markIn, markOut)
		let rebuild = timeline != entry.0 || settings != entry.1
		if back { redo.append(current) } else { undo.append(current) }
		timeline = entry.0; settings = entry.1; markIn = entry.3; markOut = entry.4
		if rebuild { revision += 1 }
		announce((back ? "Undo " : "Redo ") + entry.2)
	}
	private func commit() {
		do { try save(model.project(timeline: timeline, settings: settings, preview: false)); dismiss() }
		catch { self.error = error.localizedDescription }
	}
	private func openFade() {
		playback.pause()
		guard let clip = preview.placements.first else { return }
		fade = ProjectTransitionRequest(track: model.request.track, clip: clip.id, outgoing: nil, incoming: nil, quickFade: true, returnTime: playback.position, clips: Set(preview.placements.map(\.id)))
	}
	private func openJoin() {
		guard let point = timeline.editPoints.first(where: { abs(($0.time - playback.position).seconds) < preview.frame.seconds / 2 }) else {
			error = "Move to an edit point before adjusting it."; return
		}
		join = GroupJoinRequest(point: point)
	}
	private func swipe(_ count: Int, _ direction: UISwipeGestureRecognizer.Direction) {
		guard !loading else { return }
		switch (count, direction) {
		case (1, .left), (1, .right): playback.stepWithAudio(forward: direction == .right, frame: preview.frame)
		case (1, .down): marker(true)
		case (1, .up): marker(false)
		case (2, .left), (2, .right): playback.shuttle(forward: direction == .right)
		case (2, .down): cut(.range)
		case (3, .left), (3, .right): navigate(direction == .right)
		case (3, .down): history(back: true)
		case (3, .up): history(back: false)
		case (4, .right): cut(.head)
		case (4, .left): cut(.tail)
		default: break
		}
	}
	private func key(_ key: String, _ flags: UIKeyModifierFlags) {
		switch key {
		case " ", "k": playback.toggle()
		case "j": playback.shuttle(forward: false)
		case "l": playback.shuttle(forward: true)
		case "i": if flags.contains(.alternate) { clearMarker(true) } else { marker(true) }
		case "o": if flags.contains(.alternate) { clearMarker(false) } else { marker(false) }
		case "t": announce(time(playback.position))
		case "z": history(back: !flags.contains(.shift))
		case "u" where flags.contains(.command): commit()
		case "[": cut(.head)
		case "]": cut(.tail)
		case "\u{8}", UIKeyCommand.inputDelete: cut(.range)
		case ";": navigate(false)
		case "'": navigate(true)
		case UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow:
			if flags.contains(.command) { navigate(key == UIKeyCommand.inputRightArrow) }
			else { playback.stepWithAudio(forward: key == UIKeyCommand.inputRightArrow, frame: preview.frame, count: flags.contains(.shift) ? 10 : 1) }
		case UIKeyCommand.inputHome, UIKeyCommand.inputUpArrow: playback.seek(.zero)
		case UIKeyCommand.inputEnd, UIKeyCommand.inputDownArrow: playback.seek(preview.duration)
		case "\r": openJoin()
		default: break
		}
	}
}

private struct GroupJoinRequest: Identifiable {
	let id = UUID()
	let point: ClipEditTimeline.EditPoint
}
private struct GroupJoinView: View {
	let point: ClipEditTimeline.EditPoint
	let frame: CMTime
	let format: TimecodeFormat
	let formatTime: (CMTime) -> String
	let apply: (CMTime, CMTime) throws -> Void
	@Environment(\.dismiss) private var dismiss
	private final class Draft {
		var outgoing: CMTime
		var incoming: CMTime
		init(_ point: ClipEditTimeline.EditPoint) { outgoing = point.inTime; incoming = point.outTime }
	}
	@State private var draft: Draft
	@State private var editingOutgoing: Bool?
	@State private var entry = ""
	@State private var error: String?
	@FocusState private var typing: Bool
	init(point: ClipEditTimeline.EditPoint, frame: CMTime, format: TimecodeFormat, formatTime: @escaping (CMTime) -> String, apply: @escaping (CMTime, CMTime) throws -> Void) {
		self.point = point; self.frame = frame; self.format = format; self.formatTime = formatTime; self.apply = apply
		_draft = State(initialValue: Draft(point))
	}
	var body: some View {
		NavigationStack {
			Form {
				boundary(true)
				boundary(false)
				Button("Save") {
					do { try apply(draft.outgoing, draft.incoming); dismiss() }
					catch { self.error = error.localizedDescription }
				}
			}
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .principal) { Text("Adjust Edit Point").accessibilityAddTraits(.isHeader) }
			}
			.alert("Could Not Adjust Edit Point", isPresented: Binding(get: { error != nil && editingOutgoing == nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
		}.editorAppearance()
		.sheet(isPresented: Binding(get: { editingOutgoing != nil }, set: { if !$0 { editingOutgoing = nil } })) {
			NavigationStack {
				Form {
					TextField("", text: $entry).focused($typing)
						.editorFieldLabel(format == .frames ? "Frame" : "Time")
					Button("Save") {
						let parsed: CMTime?
						if format == .frames, let index = Int32(entry), index >= 0 { parsed = CMTimeMultiply(frame, multiplier: index) }
						else { parsed = format == .frames ? nil : CuttingBoardSession.parse(entry) }
						guard let time = parsed else { error = "Enter a valid edit-point time."; return }
						guard valid(time, outgoing: editingOutgoing == true) else { error = "Enter a time within this section. The outgoing point must not follow the incoming point."; return }
						if editingOutgoing == true { draft.outgoing = time } else { draft.incoming = time }
						editingOutgoing = nil
					}
				}.dismissKeyboardToolbar(while: typing) { typing = false }
				.toolbar {
					ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingOutgoing = nil } }
					ToolbarItem(placement: .principal) { Text(editingOutgoing == true ? "Outgoing Out Point" : "Incoming In Point").accessibilityAddTraits(.isHeader) }
				}
				.alert("Could Not Set Time", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
			}.editorAppearance()
		}
	}
	private func valid(_ value: CMTime, outgoing: Bool) -> Bool {
		outgoing ? value > point.precedingStart && value <= draft.incoming : value >= draft.outgoing && value < point.followingEnd
	}
	private func boundary(_ outgoing: Bool) -> some View {
		EditPointButton(name: outgoing ? "Outgoing Out Point" : "Incoming In Point",
			value: formatTime(outgoing ? draft.outgoing : draft.incoming), longestValue: formatTime(point.followingEnd), adjust: { direction in
				let value = (outgoing ? draft.outgoing : draft.incoming) + CMTimeMultiply(frame, multiplier: Int32(direction))
				if valid(value, outgoing: outgoing) {
					if outgoing { draft.outgoing = value } else { draft.incoming = value }
				}
				return formatTime(outgoing ? draft.outgoing : draft.incoming)
			}, activate: { _ in
				entry = formatTime(outgoing ? draft.outgoing : draft.incoming).replacingOccurrences(of: "Frame ", with: "")
				editingOutgoing = outgoing
			})
	}
}
