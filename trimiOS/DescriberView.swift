import AVFoundation
import SwiftUI

struct DescriptionEntry: Identifiable {
	let id = UUID()
	let timeline: DescriptionTimeline
	let transcript: TranscriptEntry?
	let take: DescriptionTake?
	let range: CMTimeRange
	var editing: Bool { transcript != nil || take != nil }
}

struct TimelineChooser<Option: Identifiable>: View {
	@Binding var selection: Option.ID
	let options: [Option]
	let title: KeyPath<Option, String>
	private let label = "Timeline Chooser"

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(label)
				.padding(.horizontal, 12)
				.accessibilityHidden(true)
			Wheel(selection: $selection, options: options, title: title, label: label)
				.frame(height: 100)
		}
	}

	private struct Wheel: UIViewRepresentable {
		@Binding var selection: Option.ID
		let options: [Option]
		let title: KeyPath<Option, String>
		let label: String

		func makeCoordinator() -> Coordinator { Coordinator(self) }

		func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPickerView, context: Context) -> CGSize? {
			guard let width = proposal.width, let height = proposal.height else { return nil }
			return CGSize(width: width, height: height)
		}

		func makeUIView(context: Context) -> UIPickerView {
			let picker = UIPickerView()
			picker.delegate = context.coordinator
			picker.dataSource = context.coordinator
			return picker
		}

		func updateUIView(_ picker: UIPickerView, context: Context) {
			let previous = context.coordinator.wheel.options
			context.coordinator.wheel = self
			if !previous.elementsEqual(options, by: { $0.id == $1.id && $0[keyPath: title] == $1[keyPath: title] }) {
				picker.reloadAllComponents()
			}
			if let row = options.firstIndex(where: { $0.id == selection }), picker.selectedRow(inComponent: 0) != row {
				picker.selectRow(row, inComponent: 0, animated: false)
			}
		}

		final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewAccessibilityDelegate {
			var wheel: Wheel
			init(_ wheel: Wheel) { self.wheel = wheel }

			func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
			func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int { wheel.options.count }
			func pickerView(_ pickerView: UIPickerView, accessibilityLabelForComponent component: Int) -> String? { wheel.label }
			func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
				wheel.options[row][keyPath: wheel.title]
			}
			func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
				guard wheel.options.indices.contains(row) else { return }
				wheel.selection = wheel.options[row].id
			}
		}
	}
}

struct DescriberView: View {
	@Binding var project: EditingProject
	@Binding var timeline: DescriptionTimeline
	let focus: AccessibilityFocusState<String?>.Binding
	let keyboardFocus: FocusState<String?>.Binding
	let time: (CMTime) -> String
	let open: (UUID?) -> Void
	let seek: (CMTime) -> Void
	let save: (EditingProject, String) throws -> Void
	let shift: (TimelineShiftRequest, String) -> Void
	@State private var marked: Set<UUID> = []
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var outgoingTimeline: DescriptionTimeline?
	@State private var transitionStart: Date?
	private let fadeDuration = 0.12
	@State private var shared: ExportFile?
	@State private var error: String?
	@State private var ducking = false
	@State private var mix = DescriptionDucking()

	var body: some View {
		TimelineChooser(selection: $timeline, options: DescriptionTimeline.allCases, title: \.rawValue)
		.alert("Describer", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button("OK") {}
		} message: { Text(error ?? "") }
		Button("New Description") { open(nil) }
			.buttonStyle(EditorButtonStyle())
			.accessibilityFocused(focus, equals: "newDescription")
		TimelineView(.animation(paused: transitionStart == nil || reduceMotion)) { frame in
			let elapsed = transitionStart.map { max(0, frame.date.timeIntervalSince($0)) } ?? 2 * fadeDuration
			let fadingOut = !reduceMotion && elapsed < fadeDuration
			let visible = fadingOut ? outgoingTimeline ?? timeline : timeline
			let opacity = reduceMotion ? 1 : min(1, abs(elapsed / fadeDuration - 1))
			VStack(alignment: .leading, spacing: 0) { timelineContents(for: visible) }
				.buttonStyle(.borderless)
				.opacity(opacity * opacity * (3 - 2 * opacity))
				.allowsHitTesting(visible == timeline)
		}
		.onChange(of: timeline) { previous, _ in
			let now = Date.now
			if !reduceMotion {
				if transitionStart.map({ now.timeIntervalSince($0) >= fadeDuration }) ?? true {
					outgoingTimeline = previous
				}
				transitionStart = now
			}
		}
		.task(id: transitionStart) {
			guard transitionStart != nil else { return }
			do { try await Task.sleep(for: .seconds(2 * fadeDuration)) } catch { return }
			transitionStart = nil
			outgoingTimeline = nil
		}
	}

	@ViewBuilder private func timelineContents(for timeline: DescriptionTimeline) -> some View {
		switch timeline {
		case .transcript: exportTranscriptButton
		case .audio: duckingButton
		}
		let trackActions = [EditorMenuAction("Shift Track") {
			shift(shiftRequest(timeline, ids: Set(project.descriptionRows(timeline).map(\.id)), title: "Shift Track"), "descriptionTrack")
		}]
		Menu { EditorMenuAction.buttons(trackActions) } label: {
			Text(timeline.rawValue).font(.headline).editorTouchRow(alignment: .leading)
		}
		.contextMenu { EditorMenuAction.buttons(trackActions) }
		.editorMenuActions(timeline.rawValue, trackActions)
		.accessibilityAddTraits(.isHeader)
		.accessibilityFocused(focus, equals: "descriptionTrack")
		ForEach(project.descriptionRows(timeline)) { row in
			let available = Set(project.descriptionRows(timeline).map(\.id))
			let ids: Set<UUID> = marked.contains(row.id) ? marked.intersection(available) : [row.id]
			let shiftTitle = ids.count == 1 ? "Shift Clip" : "Shift Clips"
			let actions = [
				EditorMenuAction(marked.contains(row.id) ? "Deselect Clip" : "Select Clip") {
					if marked.contains(row.id) { marked.remove(row.id) } else { marked.insert(row.id) }
				},
				EditorMenuAction(shiftTitle) {
					shift(shiftRequest(timeline, ids: ids, title: shiftTitle), row.id.uuidString)
				},
				EditorMenuAction("Go to Start") { seek(row.start) },
				EditorMenuAction("Edit " + timeline.rawValue) { open(row.id) },
				EditorMenuAction("Delete " + timeline.rawValue) { delete(row.id) }
			]
			Menu { EditorMenuAction.buttons(actions) } label: {
				VStack(alignment: .leading) {
					Text(row.name)
					Text(time(row.start) + " to " + time(row.end)).font(.subheadline)
				}.editorTouchRow(alignment: .leading)
			}
			.contextMenu { EditorMenuAction.buttons(actions) }
			.editorMenuActions(row.name, actions)
			.accessibilityValue((marked.contains(row.id) ? "Selected, " : "") + time(row.start) + " to " + time(row.end))
			.focused(keyboardFocus, equals: row.id.uuidString)
			.accessibilityFocused(focus, equals: row.id.uuidString)
		}
	}

	private func shiftRequest(_ timeline: DescriptionTimeline, ids: Set<UUID>, title: String) -> TimelineShiftRequest {
		TimelineShiftRequest(title: title, transcripts: timeline == .transcript ? ids : [], descriptions: timeline == .audio ? ids : [])
	}

	private var duckingButton: some View {
		Button("Audio Ducking") { mix = project.descriptionDucking ?? DescriptionDucking(); ducking = true }
			.buttonStyle(EditorButtonStyle())
			.accessibilityFocused(focus, equals: "ducking")
			.sheet(isPresented: $ducking, onDismiss: { focus.wrappedValue = "ducking" }) {
				NavigationStack {
					Form {
						Toggle("Audio Ducking", isOn: $mix.enabled)
						if mix.enabled {
							LabeledContent("Ducking Amount", value: mix.decibels.formatted() + " dB").accessibilityHidden(true)
							Slider(value: $mix.decibels, in: -30...0, step: 1) { Text("Ducking Amount") }
								.accessibilityValue(mix.decibels.formatted() + " decibels")
							LabeledContent("Fade", value: mix.fade.formatted() + " s").accessibilityHidden(true)
							Slider(value: $mix.fade, in: 0...3, step: 0.05) { Text("Fade") }
								.accessibilityValue(mix.fade.formatted() + " seconds")
						}
					}
					.navigationTitle("Audio Ducking")
					.toolbar {
						ToolbarItem(placement: .cancellationAction) { Button("Cancel") { ducking = false } }
						ToolbarItem(placement: .confirmationAction) { Button("Save") {
							var next = project
							next.descriptionDucking = mix
							do { try save(next, "Audio Ducking"); ducking = false }
							catch { ducking = false; self.error = error.localizedDescription }
						} }
					}
				}.editorAppearance()
			}
	}

	private var exportTranscriptButton: some View {
		Button("Export Description Transcript") {
			do {
				let data = try CaptionFileCodec.encode((project.descriptiveTranscript ?? []).map {
					CaptionCue(start: $0.start, end: $0.end, text: $0.text)
				}, format: .webVTT)
				let file = try ExportFile(name: project.name + " Description Transcript", suffix: "vtt")
				try data.write(to: file.url, options: .atomic)
				shared = file
			} catch { self.error = error.localizedDescription }
		}
		.buttonStyle(EditorButtonStyle())
		.disabled(project.descriptiveTranscript?.isEmpty != false)
		.accessibilityFocused(focus, equals: "exportDescription")
		.sheet(item: $shared, onDismiss: { focus.wrappedValue = "exportDescription" }) { file in
			ShareDescriptionFile(file: file) { shared = nil }
		}
	}

	private func delete(_ id: UUID) {
		var next = project
		switch timeline {
		case .transcript: next.descriptiveTranscript?.removeAll { $0.id == id }
		case .audio: next.audioDescriptions?.removeAll { $0.id == id }
		}
		do { try save(next, "Delete " + timeline.rawValue) } catch { self.error = error.localizedDescription }
	}
}

private struct ShareDescriptionFile: UIViewControllerRepresentable {
	let file: ExportFile
	let finish: () -> Void
	func makeUIViewController(context: Context) -> UIActivityViewController {
		let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
		controller.completionWithItemsHandler = { _, _, _, _ in finish() }
		return controller
	}
	func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DescriptionEntryView: View {
	let entry: DescriptionEntry
	let project: EditingProject
	let playback: ProjectPlayback
	let time: (CMTime) -> String
	let save: (EditingProject, String) throws -> Void
	@AppStorage(ProjectRecording.sourcePlaybackKey, store: EditorPreferences.shared) private var sourcePlayback = true
	@StateObject private var capture = ProjectRecording()
	@State private var range: CMTimeRange
	@State private var text: String
	@State private var name: String
	@State private var fit: DescriptionFit
	@State private var length: CMTime?
	@State private var measuredRecording: UUID?
	@State private var measuredLength: ProjectTime?
	@State private var drafts: [URL] = []
	@State private var playMode: PlayMode?
	@State private var confirming = false
	@FocusState private var field: Field?
	@AccessibilityFocusState(for: .voiceOver) private var recordFocused: Bool
	@AccessibilityFocusState(for: .voiceOver) private var textFocused: Bool
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var phase
	private enum Field { case text, name }
	private enum PlayMode { case passage, take, mixed }

	init(entry: DescriptionEntry, project: EditingProject, playback: ProjectPlayback, time: @escaping (CMTime) -> String, save: @escaping (EditingProject, String) throws -> Void) {
		self.entry = entry
		self.project = project
		self.playback = playback
		self.time = time
		self.save = save
		_range = State(initialValue: entry.range)
		_text = State(initialValue: entry.transcript?.text ?? "")
		_name = State(initialValue: entry.take?.name ?? "Description " + String((project.audioDescriptions?.count ?? 0) + 1))
		_fit = State(initialValue: entry.take?.fit ?? .speed)
		_length = State(initialValue: entry.take?.length.time)
	}

	private var recordingID: UUID? { capture.draft ?? entry.take?.recording }
	private var narrationLength: ProjectTime? {
		if capture.draft == nil, let saved = entry.take?.narrationLength { return saved }
		return measuredRecording == recordingID ? measuredLength : nil
	}
	private var needsMeasurement: Bool {
		fit == .speed && recordingID != nil && narrationLength == nil
	}
	private var recordingToMeasure: UUID? {
		capture.phase == .idle && length != nil && needsMeasurement ? recordingID : nil
	}

	private var title: String { entry.timeline == .audio ? "Audio Description" : "Written Description" }
	private var dirty: Bool {
		capture.draft != nil || capture.phase != .idle || text != (entry.transcript?.text ?? "") ||
			range != entry.range || fit != (entry.take?.fit ?? .speed) || (entry.take != nil && name != entry.take?.name)
	}

	var body: some View {
		NavigationStack {
			Form {
				if project.placements.contains(where: { $0.track == .video }) {
					ProjectPreview(player: capture.player).aspectRatio(CGFloat(project.picture?.width ?? 16) / CGFloat(max(1, project.picture?.height ?? 9)), contentMode: .fit)
						.frame(maxHeight: 200)
				}
				LabeledContent("In", value: time(range.start))
				LabeledContent("Out", value: time(range.end))
				if entry.editing, let marks = project.captionRange, marks != range {
					Button("Use Marked Range") { stopPreview(); range = marks }.disabled(capture.phase != .idle)
				}
				if entry.timeline == .transcript {
					TextEditor(text: $text).frame(minHeight: 96).focused($field, equals: .text).accessibilityFocused($textFocused).editorFieldLabel("Description Text")
				}
				previewButton("Play In to Out", mode: .passage)
				if entry.timeline == .audio { recordingControls }
			}
			.editorListMargins()
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle(title)
			.navigationBarTitleDisplayMode(.inline)
			.dismissKeyboardToolbar(while: field != nil) { field = nil }
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if dirty { confirming = true } else { dismiss() } } }
				ToolbarItem(placement: .principal) { Text(title).font(.headline).accessibilityAddTraits(.isHeader) }
				ToolbarItem(placement: .confirmationAction) { Button("Save", action: accept)
					.disabled(capture.phase != .idle || needsMeasurement || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && length == nil)) }
			}
		}
		.editorAppearance()
		.interactiveDismissDisabled(dirty)
		.alert("Discard description changes?", isPresented: $confirming) {
			Button("Keep Editing", role: .cancel) {}
			Button("Discard Changes", role: .destructive) {
				capture.interrupt()
				if let id = capture.draft, let url = try? ProjectStorage.recording(id, project: project.id, draft: true) { try? FileManager.default.removeItem(at: url) }
				dismiss()
			}
		}
		.alert("Describer", isPresented: Binding(get: { capture.failure != nil }, set: { if !$0 { capture.failure = nil } })) {
			Button("OK") {}
		} message: { Text(capture.failure ?? "") }
		.onAppear {
			if entry.timeline == .audio {
				refresh()
				recordFocused = true
			} else {
				field = .text
				textFocused = true
			}
		}
		.task(id: recordingToMeasure) {
			guard let id = recordingToMeasure, let length else { return }
			do {
				let url = try ProjectStorage.recording(id, project: project.id, draft: capture.draft != nil)
				let measured = try await ClipSilenceTrimming.narrationLength(url: url, length: length)
				try Task.checkCancellation()
				guard recordingID == id else { return }
				measuredLength = ProjectTime(measured)
				measuredRecording = id
			} catch {
				if !Task.isCancelled { capture.failure = "Could not read the recording. Recover the take or record another." }
			}
		}
		.onChange(of: capture.phase) { _, phase in if phase == .idle { refresh() } }
		.onChange(of: phase) { _, phase in if phase == .background { interrupted() } }
		.onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
			if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue { interrupted() }
		}
		.onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
			if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { interrupted() }
		}
		.onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
			guard let item = note.object as? AVPlayerItem, item === capture.player.currentItem else { return }
			if playMode == .passage { audition(.passage) } else { playMode = nil }
		}
		.onDisappear { capture.interrupt(); capture.selectDraft(nil) }
	}

	@ViewBuilder private var recordingControls: some View {
		TextField("", text: $name).focused($field, equals: .name).editorFieldLabel("Recording Name")
		Toggle("Source Audio Playback", isOn: $sourcePlayback)
			.disabled(capture.phase != .idle)
		Button(capture.phase == .recording ? "Stop Recording" : "Record") {
			field = nil
			playMode = nil
			if capture.phase == .recording { capture.stop() }
			else { Task { await capture.start(project: project, playback: playback, range: range, sourcePlayback: sourcePlayback) } }
		}
		.accessibilityFocused($recordFocused)
		.disabled(capture.phase == .preparing)
		if !drafts.isEmpty {
			Menu("Recover Take") {
				ForEach(drafts, id: \.self) { url in
					let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
					Button(date.formatted(date: .abbreviated, time: .standard)) {
						guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return }
						do { stopPreview(); try capture.recover(id); refresh() } catch { capture.failure = error.localizedDescription }
					}
				}
			}.disabled(capture.phase != .idle)
		}
		if let length {
			LabeledContent("Take Length", value: time(length))
			if length > range.duration {
				Picker("Fit", selection: $fit) {
					ForEach(DescriptionFit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
				}.onChange(of: fit) { stopPreview() }
			}
			previewButton("Play Take", mode: .take)
			previewButton("Play with Primary Audio", mode: .mixed)
		}
	}

	private func refresh() {
		drafts = capture.availableDrafts(project: project.id)
		if let id = capture.draft {
			do {
				let url = try ProjectStorage.recording(id, project: project.id, draft: true)
				let file = try AVAudioFile(forReading: url)
				let seconds = Double(file.length) / file.processingFormat.sampleRate
				guard seconds.isFinite, seconds > 0 else { throw ProjectFailure("The take is empty. Record another take.") }
				length = CMTime(seconds: seconds, preferredTimescale: 48000)
			} catch { length = nil; capture.failure = error.localizedDescription }
		}
	}

	private func take() throws -> (DescriptionTake, URL)? {
		guard let id = capture.draft ?? entry.take?.recording else { return nil }
		guard let length else { throw ProjectFailure("Could not read the take. Record another take.") }
		let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !label.isEmpty else { throw ProjectFailure("Enter a recording name.") }
		return try (DescriptionTake(id: entry.take?.id ?? UUID(), recording: id, name: label, start: ProjectTime(range.start),
			limit: ProjectTime(range.end), length: ProjectTime(length), fit: fit, narrationLength: narrationLength), ProjectStorage.recording(id, project: project.id, draft: capture.draft != nil))
	}

	private func previewButton(_ label: String, mode: PlayMode) -> some View {
		Button(playMode == mode ? "Stop Preview" : label) {
			if playMode == mode { stopPreview() } else { audition(mode) }
		}.disabled(capture.phase != .idle || (mode == .mixed && needsMeasurement))
	}

	private func audition(_ mode: PlayMode) {
		field = nil
		playMode = mode
		do {
			let result = mode == .passage ? nil : try take()
			if mode == .take, let result { capture.playTake(result.1) }
			else { Task { await capture.preview(playback: playback, range: range, take: result?.0, url: result?.1) } }
		} catch { playMode = nil; capture.failure = error.localizedDescription }
	}

	private func stopPreview() { playMode = nil; capture.stopPreview() }
	private func interrupted() { playMode = nil; capture.interrupt(); refresh() }

	private func accept() {
		do {
			guard range.start >= .zero, range.end <= project.duration else { throw ProjectFailure("Mark a range within the project and choose Use Marked Range.") }
			var next = project
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			if entry.timeline == .transcript, !trimmed.isEmpty {
				let row = TranscriptEntry(id: entry.transcript?.id ?? UUID(), start: ProjectTime(range.start), end: ProjectTime(range.end), text: trimmed)
				var rows = next.descriptiveTranscript ?? []
				rows.removeAll { $0.id == row.id }
				rows.append(row)
				next.descriptiveTranscript = rows
			}
			var linked: URL?
			if let result = try take() {
				var take = result.0
				if capture.draft != nil {
					let directory = try ProjectStorage.recordings(project.id, drafts: false, create: true)
					take.recording = UUID()
					let destination = directory.appendingPathComponent(take.recording.uuidString + ".caf")
					try FileManager.default.linkItem(at: result.1, to: destination)
					linked = destination
				}
				var takes = next.audioDescriptions ?? []
				takes.removeAll { $0.id == take.id }
				takes.append(take)
				next.audioDescriptions = takes
			}
			do { try save(next, entry.editing ? "Update Description" : "Create Description") }
			catch { if let linked { try? FileManager.default.removeItem(at: linked) }; throw error }
			if let draft = capture.draft, let url = try? ProjectStorage.recording(draft, project: project.id, draft: true) {
				try? FileManager.default.removeItem(at: url)
			}
			dismiss()
		} catch { capture.failure = error.localizedDescription }
	}
}
