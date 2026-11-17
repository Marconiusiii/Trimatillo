import AVFoundation
import SwiftUI

struct VoiceInsertion: Identifiable {
	let id = UUID()
	let time: CMTime
}

struct VoicerRecordingView: View {
	let project: EditingProject
	let position: CMTime
	let format: TimecodeFormat
	let initialTime: String
	let playback: ProjectPlayback
	let save: (EditingProject, String) throws -> Void
	@AppStorage(ProjectRecording.sourcePlaybackKey, store: EditorPreferences.shared) private var sourcePlayback = true
	@StateObject private var capture = ProjectRecording(voiceOver: true)
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var scene
	@State private var name: String
	@State private var insertion: String
	@State private var drafts: [URL] = []
	@State private var previewing = false
	@State private var busy = false
	@State private var discard = false
	@State private var choosingDraft = false
	@FocusState private var field: Field?
	private enum Field { case name, time }

	init(project: EditingProject, position: CMTime, format: TimecodeFormat, initialTime: String, playback: ProjectPlayback,
		save: @escaping (EditingProject, String) throws -> Void) {
		self.project = project
		self.position = position
		self.format = format
		self.initialTime = initialTime
		self.playback = playback
		self.save = save
		_insertion = State(initialValue: initialTime)
		let count = project.sources.filter { if case .recording = $0.reference { return true }; return false }.count
		_name = State(initialValue: "Voice Over " + String(count + 1))
	}

	var body: some View {
		NavigationStack {
			Form {
				if let picture = project.picture, project.placements.contains(where: { $0.track == .video }) {
					ProjectPreview(player: capture.player.currentItem == nil ? playback.player : capture.player)
						.aspectRatio(CGFloat(picture.width) / CGFloat(picture.height), contentMode: .fit)
						.frame(maxHeight: 200)
				}
				Group {
					TextField("", text: $name).focused($field, equals: .name).editorFieldLabel("Clip Name")
					TextField("", text: $insertion).focused($field, equals: .time)
						.keyboardType(format == .frames ? .numberPad : .numbersAndPunctuation)
						.editorFieldLabel(format == .frames ? "Insert at Frame" : "Insert at Time")
				}
				.disabled(capture.phase != .idle || busy)
				Toggle("Source Audio Playback", isOn: $sourcePlayback)
					.disabled(capture.phase != .idle || busy)
				Button(capture.phase == .recording ? "Stop Recording" : "Record") {
					field = nil
					if capture.phase == .recording { capture.stop() }
					else { record() }
				}
				.disabled(capture.phase == .preparing || busy)
				if capture.phase == .preparing { ProgressView("Preparing recording") }
				if capture.phase == .idle {
					if capture.draft != nil {
						if previewing { Button("Stop Playback") { stopPreview() } }
						else {
							Button("Play Take") { audition(mixed: false) }
							Button("Play with Primary Audio") { audition(mixed: true) }
						}
					}
					if !drafts.isEmpty {
						let actions = drafts.enumerated().map { index, url in
							let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
							let title = "Take " + String(index + 1) + (date.map { ", " + $0.formatted(date: .abbreviated, time: .standard) } ?? "")
							return EditorMenuAction(title) { recover(url) }
						}
						Button("Recover Take") {
							if actions.count == 1 { actions[0].perform() } else { choosingDraft = true }
						}
						.editorMenuActions("Recover Take", actions)
						.confirmationDialog("Recover Take", isPresented: $choosingDraft, titleVisibility: .visible) {
							EditorMenuAction.buttons(actions)
							Button("Cancel", role: .cancel) {}
						}
					}
				}
			}
			.editorListMargins()
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle("Record Voice Over")
			.navigationBarTitleDisplayMode(.inline)
			.dismissKeyboardToolbar(while: field != nil) { field = nil }
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") {
					if capture.draft != nil || capture.phase != .idle { discard = true } else { dismiss() }
				}.disabled(busy) }
				ToolbarItem(placement: .principal) { Text("Record Voice Over").font(.headline).accessibilityAddTraits(.isHeader) }
				ToolbarItem(placement: .confirmationAction) { Button("Add to Project") { add() }
					.disabled(busy || capture.draft == nil || capture.phase != .idle || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
			}
		}
		.editorAppearance()
		.interactiveDismissDisabled(busy || capture.draft != nil || capture.phase != .idle)
		.alert("Discard this take?", isPresented: $discard) {
			Button("Keep Editing", role: .cancel) {}
			Button("Discard Take", role: .destructive) { capture.interrupt(); removeDraft(); dismiss() }
		}
		.alert("Voicer", isPresented: Binding(get: { capture.failure != nil }, set: { if !$0 { capture.failure = nil } })) {
			Button("OK") {}
		} message: { Text(capture.failure ?? "") }
		.onAppear { refresh() }
		.onChange(of: capture.phase) { _, phase in if phase == .idle { refresh() } }
		.onChange(of: capture.failure) { if capture.failure != nil { previewing = false } }
		.onChange(of: scene) { if scene == .background { interrupt() } }
		.onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
			if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue { interrupt() }
		}
		.onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
			if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { interrupt() }
		}
		.onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
			if let item = note.object as? AVPlayerItem, item === capture.player.currentItem { previewing = false }
		}
		.onDisappear { interrupt(); capture.selectDraft(nil) }
	}

	private func recover(_ url: URL) {
		guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return }
		do {
			stopPreview()
			try capture.recover(id)
			refresh()
		} catch { capture.failure = error.localizedDescription }
	}

	private func refresh() { drafts = capture.availableDrafts(project: project.id) }
	private func interrupt() { capture.interrupt(); previewing = false }
	private func stopPreview() { previewing = false; capture.stopPreview() }

	private func startTime() throws -> CMTime {
		if insertion == initialTime { return position }
		let text = insertion.trimmingCharacters(in: .whitespacesAndNewlines)
		if format == .frames, let frame = Int32(text), frame >= 0 { return CMTimeMultiply(project.frame, multiplier: frame) }
		if format != .frames, let time = CuttingBoardSession.parse(text), time.isNumeric, time >= .zero,
			time.seconds * 48000 < Double(Int64.max) { return time }
		throw ProjectFailure(format == .frames ? "Enter a valid frame number." : "Enter a valid insertion time.")
	}

	private func record() {
		do {
			let start = try startTime()
			stopPreview()
			let range = CMTimeRange(start: start, duration: max(.zero, project.duration - start))
			Task { await capture.start(project: project, playback: playback, range: range, sourcePlayback: sourcePlayback) }
		} catch { capture.failure = error.localizedDescription }
	}

	private func removeDraft() {
		if let id = capture.draft, let url = try? ProjectStorage.recording(id, project: project.id, draft: true, voiceOver: true) {
			try? FileManager.default.removeItem(at: url)
		}
	}

	private func audition(mixed: Bool) {
		guard let id = capture.draft else { return }
		do {
			let url = try ProjectStorage.recording(id, project: project.id, draft: true, voiceOver: true)
			if !mixed { previewing = true; capture.playTake(url); return }
			let start = try startTime()
			busy = true
			Task {
				defer { busy = false }
				do {
					let length = try await AVURLAsset(url: url).load(.duration)
					let range = CMTimeRange(start: start, duration: length)
					let take = DescriptionTake(recording: id, name: name, start: ProjectTime(start), limit: ProjectTime(range.end),
						length: ProjectTime(length), fit: .trim)
					previewing = true
					await capture.preview(playback: playback, range: range, take: take, url: url, duck: false)
				} catch { capture.failure = error.localizedDescription }
			}
		} catch { capture.failure = error.localizedDescription }
	}

	private func add() {
		guard let draft = capture.draft else { return }
		field = nil
		stopPreview()
		busy = true
		Task {
			defer { busy = false }
			do {
				let start = try startTime()
				let url = try ProjectStorage.recording(draft, project: project.id, draft: true, voiceOver: true)
				let length = try await AVURLAsset(url: url).load(.duration)
				guard length.isNumeric && length > .zero else { throw ProjectFailure("Record a take before adding it.") }
				let id = UUID()
				let source = ProjectMediaSource(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
					reference: .recording(project: project.id, id: id), duration: ProjectTime(length), picture: nil, hasAudio: true)
				var next = project
				try next.addVoiceOver(source, at: start)
				let directory = try ProjectStorage.recordings(project.id, drafts: false, create: true)
				let destination = directory.appendingPathComponent(id.uuidString + ".caf")
				try FileManager.default.linkItem(at: url, to: destination)
				do { try save(next, "Add Voice Over") }
				catch { try? FileManager.default.removeItem(at: destination); throw error }
				removeDraft()
				dismiss()
			} catch { capture.failure = error.localizedDescription }
		}
	}
}
