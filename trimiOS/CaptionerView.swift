import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct CaptionEntry: Identifiable {
	let cue: CaptionCue
	let editing: Bool
	let returnTime: CMTime
	var id: UUID { cue.id }
}

struct CaptionEntryView: View {
	let entry: CaptionEntry
	let playback: ProjectPlayback
	let markedRange: CMTimeRange?
	let time: (CMTime) -> String
	let save: (CaptionCue) throws -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var cue: CaptionCue
	@State private var failure: String?
	@FocusState private var typing: Bool
	@AccessibilityFocusState(for: .voiceOver) private var captionFocused: Bool
	@State private var didSetInitialFocus = false
	@AccessibilityFocusState private var insertFocused: Bool

	init(entry: CaptionEntry, playback: ProjectPlayback, markedRange: CMTimeRange?, time: @escaping (CMTime) -> String,
		save: @escaping (CaptionCue) throws -> Void) {
		self.entry = entry
		self.playback = playback
		self.markedRange = markedRange
		self.time = time
		self.save = save
		_cue = State(initialValue: entry.cue)
	}

	var body: some View {
		NavigationStack {
			Form {
				TextEditor(text: $cue.text)
					.accessibilityLabel("Caption Text")
					.focused($typing)
					.accessibilityFocused($captionFocused)
					.frame(minHeight: 96)
				LabeledContent("In", value: time(cue.start.time))
				LabeledContent("Out", value: time(cue.end.time))
				if entry.editing, let markedRange {
					Button("Use Marked Range") {
						playback.pause()
						cue.start = ProjectTime(markedRange.start)
						cue.end = ProjectTime(markedRange.end)
					}
				}
				let decorators = [
					EditorMenuAction("Music Description") { insert("[music description]") },
					EditorMenuAction("Sound Description") { insert("[sound description]") },
					EditorMenuAction("Lyrics") { insert("♪ lyrics ♪") }
				]
				Menu("Insert Caption Description") { EditorMenuAction.buttons(decorators) }
				.editorMenuActions("Insert Caption Description", decorators)
				.accessibilityFocused($insertFocused)
				Button(playback.transport.playing ? "Pause Selection" : "Play Selection", action: playSelection)
				if let failure { Text(failure) }
			}
			.editorListMargins()
			.dismissKeyboardToolbar(while: typing) { typing = false }
			.navigationTitle(entry.editing ? "Edit Caption" : "New Caption")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .principal) {
					Text(entry.editing ? "Edit Caption" : "New Caption").font(.headline).accessibilityAddTraits(.isHeader)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") {
						do {
							cue.isDraft = true
							try save(cue.validated())
							dismiss()
						} catch { failure = error.localizedDescription }
					}
					.disabled(cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				}
			}
		}
		.editorAppearance()
		.accessibilityAction(.magicTap, playSelection)
		.task {
			guard !didSetInitialFocus else { return }
			didSetInitialFocus = true
			typing = true
			if !entry.editing { captionFocused = true }
		}
		.onDisappear {
			playback.pause()
			playback.seek(entry.returnTime)
		}
	}

	private func playSelection() {
		if playback.transport.playing { playback.pause() }
		else { playback.playCaptionSelection(CMTimeRange(start: cue.start.time, end: cue.end.time)) }
	}

	private func insert(_ text: String) {
		if let last = cue.text.last, !last.isWhitespace { cue.text += " " }
		cue.text += text
		insertFocused = true
	}
}

struct CaptionOverlay: View {
	let cues: [CaptionCue]
	let playhead: ProjectPlayhead
	let aspect: CGFloat
	@State private var activeText = ""
	@State private var intervalStart = CMTime.invalid
	@State private var intervalEnd = CMTime.invalid

	var body: some View {
		GeometryReader { geometry in
			let height = min(geometry.size.height, geometry.size.width / max(0.01, aspect))
			let width = height * aspect
			if !activeText.isEmpty {
				Text(activeText)
					.font(.system(size: height * 45 / 1080, weight: .medium))
					.foregroundStyle(.white)
					.multilineTextAlignment(.center)
					.padding(height * 0.0125)
					.background(.black.opacity(0.8))
					.frame(maxWidth: width * 0.765)
					.padding(.bottom, height * 0.05)
					.frame(width: width, height: height, alignment: .bottom)
					.position(x: geometry.size.width / 2, y: geometry.size.height / 2)
			}
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
		.onReceive(playhead.$position) { time in
			if !intervalStart.isValid || time < intervalStart || time >= intervalEnd { update(at: time) }
		}
		.onChange(of: cues) { update(at: playhead.position) }
	}

	private func update(at time: CMTime) {
		var start = CMTime.negativeInfinity
		var end = CMTime.positiveInfinity
		var active = [String]()
		for cue in cues {
			for boundary in [cue.start.time, cue.end.time] {
				if boundary <= time { start = max(start, boundary) }
				else { end = min(end, boundary) }
			}
			if cue.start.time <= time && time < cue.end.time { active.append(cue.text) }
		}
		activeText = active.joined(separator: "\n")
		intervalStart = start
		intervalEnd = end
	}
}

struct CaptionedProjectPreview: View {
	let playback: PreviewPlayback
	let cues: [CaptionCue]
	let aspect: CGFloat
	@StateObject private var playhead = ProjectPlayhead()
	@Environment(\.scenePhase) private var phase
	@Environment(\.dismiss) private var dismiss
	@State private var observer: Any?
	@State private var ready = false
	@State private var failed = false

	var body: some View {
		NavigationStack {
			VideoPlayer(player: playback.player) {
				CaptionOverlay(cues: cues, playhead: playhead, aspect: aspect)
			}
			.disabled(!ready)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Close", action: close) }
				ToolbarItem(placement: .principal) {
					Text("Full Screen Preview").font(.headline).accessibilityAddTraits(.isHeader)
				}
			}
		}
		.editorAppearance()
		.accessibilityAction(.magicTap) { playback.toggle() }
		.interactiveDismissDisabled()
		.task {
			do {
				try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
				await playback.begin()
				guard !Task.isCancelled else { return }
				ready = playback.positioned
				guard ready else { failed = true; return }
				if phase != .active { playback.player.pause() }
				playhead.position = playback.player.currentTime()
				observer = playback.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
					MainActor.assumeIsolated { playhead.position = time }
				}
			} catch { failed = true }
		}
		.onDisappear {
			if let observer { playback.player.removeTimeObserver(observer); self.observer = nil }
			playback.finish()
		}
		.onChange(of: phase) { _, value in
			if value == .background { playback.player.pause() }
		}
		.onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: playback.player.currentItem)) { _ in
			failed = true
		}
		.alert("Could Not Play Preview", isPresented: $failed) {
			Button("Close", action: close)
		} message: { Text("Reopen the preview to try again.") }
	}

	private func close() {
		playback.finish()
		dismiss()
	}
}

private enum CaptionExportFormat: String, CaseIterable {
	case srt = "SRT"
	case vtt = "WebVTT"
	case txt = "Plain Text Transcript"

	var suffix: String {
		switch self { case .srt: "srt"; case .vtt: "vtt"; case .txt: "txt" }
	}
	var type: UTType { UTType(filenameExtension: suffix, conformingTo: .plainText) ?? .plainText }
}

private struct CaptionDocument: FileDocument {
	static var readableContentTypes: [UTType] { CaptionExportFormat.allCases.map(\.type) }
	var data: Data
	init(data: Data) { self.data = data }
	init(configuration: ReadConfiguration) throws {
		guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
		data = bytes
	}
	func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct CaptionerView: View {
	@Binding var project: EditingProject
	let playback: ProjectPlayback
	let focus: AccessibilityFocusState<String?>.Binding
	let keyboardFocus: FocusState<String?>.Binding
	let time: (CMTime) -> String
	let newCaption: () -> Void
	let edit: (CaptionCue) -> Void
	let save: (EditingProject, String) throws -> Void
	@State private var finalizing = false
	@State private var finalizedMessage: String?
	@State private var exporting = false
	@State private var exportFormat = CaptionExportFormat.srt
	@State private var document: CaptionDocument?
	@State private var failure: String?

	var body: some View {
		Button("New Caption", action: newCaption)
			.buttonStyle(EditorButtonStyle())
			.disabled(!playback.ready)
			.accessibilityFocused(focus, equals: "newCaption")
		Section {
			ForEach(project.captions ?? []) { cue in
				let actions = [
					EditorMenuAction("Go to Caption") { playback.seek(cue.start.time) },
					EditorMenuAction("Edit Caption") { edit(cue) },
					EditorMenuAction("Delete Caption") { delete(cue) }
				]
				Menu { EditorMenuAction.buttons(actions) } label: {
					VStack(alignment: .leading) {
						Text(cue.text)
						Text(time(cue.start.time) + " – " + time(cue.end.time)).font(.subheadline)
					}
					.padding(.horizontal, 8)
					.editorTouchRow(alignment: .leading)
				}
				.editorMenuActions(cue.text, actions)
				.accessibilityValue(time(cue.start.time) + " to " + time(cue.end.time))
				.focused(keyboardFocus, equals: cue.id.uuidString)
				.accessibilityFocused(focus, equals: cue.id.uuidString)
			}
		} header: { Text("Caption Timeline").accessibilityAddTraits(.isHeader) }
		Button("Finalize Captions") { playback.pause(); finalizing = true }
			.disabled(project.captions?.contains(where: \.isDraft) != true)
			.buttonStyle(EditorButtonStyle())
			.accessibilityFocused(focus, equals: "finalize")
			.sheet(isPresented: $finalizing, onDismiss: {
				focus.wrappedValue = "finalize"
				if let message = finalizedMessage {
					finalizedMessage = nil
					let speech = NSAttributedString(string: message, attributes: [.accessibilitySpeechQueueAnnouncement: true])
					UIAccessibility.post(notification: .announcement, argument: speech)
				}
			}) {
				CaptionFinalizationView(project: $project, save: save) { finalizedMessage = $0 }
			}
		Menu {
			ForEach(CaptionExportFormat.allCases, id: \.self) { format in
				Button(format.rawValue) { export(format) }
			}
		} label: {
			Text("Export Captions").editorTouchRow()
		}
		.buttonStyle(.borderless)
		.editorMenuActions("Export Captions", CaptionExportFormat.allCases.map { format in EditorMenuAction(format.rawValue) { export(format) } })
		.disabled(project.captions?.isEmpty != false)
		.accessibilityFocused(focus, equals: "exportCaptions")
		.fileExporter(isPresented: $exporting, document: document, contentTypes: [exportFormat.type],
			defaultFilename: project.name + "." + exportFormat.suffix) { result in
			focus.wrappedValue = "exportCaptions"
			if case .failure(let error) = result { failure = error.localizedDescription }
		} onCancellation: { focus.wrappedValue = "exportCaptions" }
		.alert("Captioner", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("OK") { failure = nil }
		} message: { Text(failure ?? "") }
	}

	private func delete(_ cue: CaptionCue) {
		var next = project
		next.captions?.removeAll { $0.id == cue.id }
		do { try save(next, "Delete Caption") } catch { failure = error.localizedDescription }
	}

	private func export(_ format: CaptionExportFormat) {
		guard let cues = project.captions, !cues.isEmpty else { return }
		do {
			let data: Data
			switch format {
			case .srt, .vtt:
				guard cues.allSatisfy({ $0.end.time <= project.duration }) else {
					throw ProjectFailure("A caption extends past the project. Edit its marked range before exporting.")
				}
				data = try CaptionFileCodec.encode(cues, format: format == .srt ? .subRip : .webVTT)
			case .txt: data = try CaptionFileCodec.encodePlainText(cues, projectTitle: project.name)
			}
			playback.pause()
			document = CaptionDocument(data: data)
			exportFormat = format
			exporting = true
		} catch { failure = error.localizedDescription }
	}
}

private struct CaptionFinalizationView: View {
	var reviewTitle: String {
		issues.count == 1 ? "Review 1 passage" : "Review " + String(issues.count) + " passages"
	}
	@Binding var project: EditingProject
	let save: (EditingProject, String) throws -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var issues: [CaptionFinalizationIssue] = []
	@State private var failure: String?
	@State private var running = true
	let completed: (String) -> Void
	@AccessibilityFocusState(for: .voiceOver) private var resultFocused: Bool

	var body: some View {
		NavigationStack {
			if running {
				LoadingStatusView("Finalizing captions", cancel: { dismiss() })
			} else {
				List {
					if let failure {
						Text("Could not finalize captions. " + failure)
							.accessibilityFocused($resultFocused)
							.onAppear { resultFocused = true }
					}
					ForEach(issues) { issue in
						Text(issue.displayName + ". " + issue.message)
					}
				}
				.navigationTitle(failure == nil ? reviewTitle : "Finalize Captions")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
					ToolbarItem(placement: .principal) {
						if failure == nil {
							Text(reviewTitle).font(.headline).accessibilityAddTraits(.isHeader)
								.accessibilityFocused($resultFocused)
								.onAppear { resultFocused = true }
						} else {
							Text("Finalize Captions").font(.headline).accessibilityAddTraits(.isHeader)
						}
					}
				}
			}
		}
		.editorAppearance()
		.task {
			let initial = project
			let work = Task.detached(priority: .userInitiated) {
				CaptionFinalizer.finalize(cues: initial.captions ?? [], projectDuration: ProjectTime(initial.duration),
					width: initial.picture?.width ?? 1920, height: initial.picture?.height ?? 1080,
					frameRate: 1 / initial.frame.seconds)
			}
			let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
			guard !Task.isCancelled else { return }
			do {
				guard project == initial else { throw ProjectFailure("The project changed. Choose Finalize Captions again.") }
				if result.changed {
					var next = project
					next.captions = result.cues
					try save(next, "Finalize Captions")
				}
				issues = result.issues
				if issues.isEmpty {
					let captions = result.createdCues == 1 ? "1 caption" : String(result.createdCues) + " captions"
					if result.finalizedPassages == result.createdCues {
						completed(captions + " finalized.")
					} else {
						let passages = result.finalizedPassages == 1 ? "1 passage" : String(result.finalizedPassages) + " passages"
						completed(captions + " finalized from " + passages + ".")
					}
					dismiss()
					return
				}
			} catch { failure = error.localizedDescription }
			running = false
		}
	}
}
