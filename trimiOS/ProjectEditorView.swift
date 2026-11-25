import SwiftUI
import AVKit
import PhotosUI
import Combine
import OSLog
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

@MainActor private final class ProjectExportCue: NSObject, ObservableObject, AVAudioPlayerDelegate {
	private var player: AVAudioPlayer?
	private var preparation: Task<Void, Never>?
	private var interruption: AnyCancellable?

	func prepare() {
		preparation = Task { player = await Self.preparePlayer() }
	}

	@concurrent private static func preparePlayer() async -> sending AVAudioPlayer? {
		guard let url = Bundle.main.url(forResource: "ExportComplete", withExtension: "wav"),
			let cue = try? AVAudioPlayer(contentsOf: url), cue.prepareToPlay() else { return nil }
		return cue
	}

	func play() async {
		await preparation?.value
		preparation = nil
		player?.delegate = self
		guard let player, player.play() else { finish(); return }
		interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] note in
				if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
					self?.finish()
				}
			}
	}

	func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		if self.player === player { finish() }
	}

	func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
		if self.player === player { finish() }
	}

	private func finish() {
		interruption = nil
		player = nil
		let message = NSAttributedString(string: "Export complete", attributes: [.accessibilitySpeechQueueAnnouncement: true])
		UIAccessibility.post(notification: .announcement, argument: message)
	}
}

struct ProjectEditorView: View {
	@Binding var project: EditingProject
	let close: () -> Void
	@ObservedObject var playback: ProjectPlayback
	@Binding var board: ProjectBoard?
	@Binding var revision: Int
	let preparedRevision: Int?
	let saves: ProjectSaveQueue
	@State private var tool = ProjectTool.editor
	@State private var mixerTrack = TimelineTrack.primaryAudio.id
	@State private var soloTracks: Set<String> = []
	@State private var voiceInsertion: VoiceInsertion?
	@State private var descriptionTimeline = DescriptionTimeline.audio
	@State private var descriptionProjectID: UUID?
	@State private var shifting: TimelineShiftRequest?
	@State private var clipsBoard: ClipsBoardRequest?
	@State private var descriptionEntry: DescriptionEntry?
	@State private var descriptionTrigger = "newDescription"
	@State private var descriptionNeedsRebuild = false
	@State private var descriptionSaved = false
	@State private var restoringDescription = false
	@State private var captionEntry: CaptionEntry?
	@State private var captionTrigger = "newCaption"
	@State private var captionCreated = false
	@State private var selectedEntries: Set<UUID> = []
	@State private var activeTrack = TimelineTrack.primaryVideo.id
	@State private var pendingEditorTrack: String?
	@State private var timelineOpacity = 1.0
	@State private var marked: Set<UUID> = []
	@State private var dropAnchor: UUID?
	@State private var dropAfter = false
	@State private var dragging: Set<UUID> = []
	@ScaledMetric(relativeTo: .body) private var wideTransportWidth: CGFloat = 420
	@State private var generatorRequest: GeneratorRequest?
	@State private var effects: TimelineTrack?
	@State private var transitionRequest: ProjectTransitionRequest?
	@State private var transitionChanged = false
	@State private var transitionFallback: String?
	@FocusState private var keyboardClip: String?
	@State private var expanded = true
	@State private var pickingFile = false
	@State private var pickingPhoto = false
	@State private var confirmedPhoto: SelectedPhotoClip?
	@State private var deletingSource: ProjectMediaSource?
	@State private var renaming: ProjectMediaSource?
	@State private var clipName = ""
	@State private var reconnect: UUID?
	@State private var clipTask: Task<Void, Never>?
	@State private var projectSheet: ProjectSheet?
	@State private var exportCompleted = false
	@StateObject private var exportCue = ProjectExportCue()
	@State private var undo: [HistoryEntry] = []
	@State private var redo: [HistoryEntry] = []
	@State private var error: String?
	@State private var fullScreenPreview: PreviewPlayback?
	@State private var directTouch = false
	@State private var returnMessage: String?
	@AccessibilityFocusState(for: .voiceOver) private var surfaceFocused: Bool
	@AppStorage("directTouchScrubbing", store: EditorPreferences.shared) private var scrubMode = DirectTouchScrubbing.absolute
	@State private var jumping = false
	@State private var movingToTime: ProjectPlacement?
	@State private var trackForMove: ProjectPlacement?
	@State private var newTrackName = ""
	@FocusState private var typingTrackName: Bool
	@State private var confirmPacking: TimelineTrack?
	@State private var placementFocus: String?
	@State private var placementNeedsRebuild = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@FocusState private var renamingClip: Bool
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@AccessibilityFocusState private var focus: String?
	@State private var trigger: String?

	private var preparingTimeline: Bool {
		board == nil && !project.placements.isEmpty && (preparedRevision != revision || playback.preparing)
	}

	private var loading: Bool { clipTask != nil || preparingTimeline }

	var body: some View {
		Group {
			if preparingTimeline && !directTouch {
				LoadingStatusView("Preparing timeline", cancel: close)
			} else {
				ProjectWorkspaceTabs(selection: $tool) { workspacePage }
			}
		}
		.onAppear {
			if descriptionProjectID != project.id {
				descriptionTimeline = project.initialDescriptionTimeline
				descriptionProjectID = project.id
			}
		}
		.onChange(of: playback.failure) { _, message in
			if let message { error = message; playback.failure = nil }
		}
		.onChange(of: preparingTimeline) { _, preparing in
			if !preparing, let placementFocus { focus = placementFocus; self.placementFocus = nil }
			if !preparing && restoringDescription { restoreDescriptionFocus() }
		}
		.onChange(of: activeTrack) {
			dropAnchor = nil
			if let pendingEditorTrack, pendingEditorTrack != activeTrack { self.pendingEditorTrack = nil }
		}
		.onChange(of: reduceMotion) {
			if reduceMotion {
				if let pendingEditorTrack { activeTrack = pendingEditorTrack }
				pendingEditorTrack = nil
				withAnimation(nil) { timelineOpacity = 1 }
			}
		}
		.onChange(of: soloTracks) { playback.updateMix(project, solo: soloTracks) }
		.onChange(of: playback.ready) { if playback.ready { playback.updateMix(project, solo: soloTracks) } }
		.onChange(of: tool) { previous, _ in
			if previous == .mixer { playback.setMixerLoop(nil); soloTracks.removeAll() }
			playback.playhead.navigationLabel = nil
			keyboardClip = nil
		}
	}

	private var workspacePage: some View {
		ProjectEditorKeyboard(playback: playback, enabled: clipsBoard == nil && shifting == nil && generatorRequest == nil && deletingSource == nil && voiceInsertion == nil && movingToTime == nil && trackForMove == nil && confirmPacking == nil && descriptionEntry == nil && captionEntry == nil && !directTouch && projectSheet == nil && renaming == nil && fullScreenPreview == nil && board == nil && effects == nil && transitionRequest == nil && !jumping && error == nil && !loading && !pickingPhoto && !pickingFile,
			tool: tool, undoShake: {
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
				} else {
					editorLayout
				}
			}
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle(tool == .editor ? project.name : tool.rawValue)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar(loading ? .hidden : .visible, for: .navigationBar)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Close", action: close) }
				ToolbarItem(placement: .principal) {
					Text(tool == .editor ? project.name : tool.rawValue).font(.headline).accessibilityAddTraits(.isHeader)
				}
				ToolbarItem(placement: .topBarTrailing) {
					let actions = projectActions
					Menu("Project Actions") { EditorMenuAction.buttons(actions) }
						.editorMenuActions("Project Actions", actions)
						.accessibilityFocused($focus, equals: "projectActions")
				}
			}
			.sheet(item: $projectSheet, onDismiss: projectSheetDismissed) { sheet in
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
					ProjectExportView(timeline: timeline, didSave: prepareExportConfirmation)
				}
			}
			.sheet(item: transitionBinding(direct: false), onDismiss: finishTransition, content: transitionSheet)
			.fullScreenCover(item: $clipsBoard, onDismiss: restoreClipFocus) { request in
				if let model = try? ClipsBoardModel(request) {
					ClipsCuttingBoardView(model: model) { edited in
						guard project == request.project else { throw ProjectFailure("The project changed. Reopen Clips Cutting Board to edit the current clips.") }
						try save(edited, action: "Edit Selected Clips")
					}
				}
			}
			.sheet(item: $shifting, onDismiss: restoreClipFocus) { request in
				TimelineShiftView(request: request) { seconds in
					var next = project
					try next.shift(request, by: seconds)
					try save(next, action: request.title)
				}
			}
			.sheet(item: $effects, onDismiss: { focus = trigger }) { track in
				trackEffectsSheet(track)
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
					Form { TextField("", text: $clipName).focused($renamingClip).editorFieldLabel("Clip Name") }
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
			.sheet(item: voiceBinding(direct: false), onDismiss: finishVoice, content: voiceSheet)
			.sheet(item: descriptionBinding(direct: false), onDismiss: finishDescription, content: descriptionSheet)
			.sheet(item: captionBinding(direct: false), onDismiss: { finishCaption(direct: false) }, content: captionSheet)
			.fullScreenCover(isPresented: $directTouch, onDismiss: { returnMessage = nil; focus = "projectDirectTouch" }) {
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
			.sheet(item: generatorBinding(direct: false), onDismiss: finishGenerator, content: generatorSheet)
			.sheet(item: $movingToTime, onDismiss: restoreClipFocus) { clip in
				ProjectJumpSheet(format: format, frame: project.frame, moving: true, initial: time(clip.start.time).replacingOccurrences(of: "Frame ", with: "")) { time in
					try moveClip(clip, to: time, exact: true)
				}
			}
			.sheet(item: $trackForMove, onDismiss: restoreClipFocus) { clip in
				NavigationStack {
					Form { TextField("", text: $newTrackName).focused($typingTrackName).editorFieldLabel("Track Name") }
						.dismissKeyboardToolbar(while: typingTrackName) { typingTrackName = false }
						.navigationTitle("Move to New Track")
						.navigationBarTitleDisplayMode(.inline)
						.toolbar {
							ToolbarItem(placement: .principal) { Text("Move to New Track").font(.headline).accessibilityAddTraits(.isHeader) }
							ToolbarItem(placement: .cancellationAction) { Button("Cancel") { trackForMove = nil } }
							ToolbarItem(placement: .confirmationAction) { Button("Move") {
								do {
									var next = project
									let track = try next.createTrack(newTrackName, kind: clip.track)
									try next.moveClip(clip.id, to: clip.start.time, on: track, exact: true)
									try save(next, action: "Move to New Track")
									placementFocus = clip.id.uuidString
									activeTrack = track.id
									trigger = clip.id.uuidString
									trackForMove = nil
								} catch { self.error = error.localizedDescription }
							}.disabled(newTrackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
						}
						.alert("Move to New Track", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
							Button("OK") {}
						} message: { Text(error ?? "") }
				}.editorAppearance()
			}
			.alert("Delete from Project?", isPresented: Binding(get: { deletingSource != nil }, set: { if !$0 { deletingSource = nil } }), presenting: deletingSource) { source in
				Button("Cancel", role: .cancel) { focus = trigger }
				Button("Delete from Project", role: .destructive) {
					var next = project
					next.deleteSource(source.id)
					commit(next, action: "Delete from Project")
				}
			} message: { source in
				let count = project.placements.filter { $0.sourceID == source.id }.count
				if count == 0 { Text("Delete \(source.displayName) from project?") }
				else { Text("Delete \(source.displayName) from project and remove \(count) \(count == 1 ? "clip" : "clips") from the timeline?") }
			}
			.alert("Enable Magnetic and reposition clips?", isPresented: Binding(get: { confirmPacking != nil }, set: { if !$0 { confirmPacking = nil } }), presenting: confirmPacking) { track in
				Button("Cancel", role: .cancel) { focus = track.id }
				Button("Enable Magnetic") { changeMagnetic(true, on: track) }
			} message: { track in Text("Clips on " + track.title + " will be placed together from the start of the project.") }
			.sheet(isPresented: $jumping, onDismiss: { focus = "jump" }) {
				ProjectJumpSheet(format: format, frame: project.frame) { playback.seek($0) }
			}
			.alert("Project", isPresented: Binding(get: { trackForMove == nil && !directTouch && error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK") { error = nil }
			} message: { Text(error ?? "") }
		}
		.onChange(of: dragging) { _, ids in if ids.isEmpty { dropAnchor = nil } }
	}

	private var editorLayout: some View {
		GeometryReader { geometry in
			let hasVideo = project.placements.contains { $0.track == .video }
			let wide = geometry.size.width > geometry.size.height && geometry.size.width > 550
			HStack(spacing: 0) {
				if hasVideo && wide {
					preview.frame(width: geometry.size.width * 0.45)
				}
				ScrollView {
					VStack(alignment: .leading, spacing: 0) {
						if hasVideo && !wide {
							preview.frame(maxWidth: .infinity)
								.frame(height: min(geometry.size.height * 0.4, geometry.size.width / pictureAspect) + 48)
						}
						Group {
							if tool == .editor { projectRows }
							else if tool == .mixer {
								transport
								MixerView(project: project, selection: $mixerTrack, solo: $soloTracks, playback: playback, apply: applyMixerEdit)
							}
							else if tool == .voicer {
								transport
								Button("Record Voice Over", action: openVoice)
									.buttonStyle(EditorButtonStyle()).accessibilityFocused($focus, equals: "recordVoice")
								ForEach(project.tracks.filter { $0.isVoiceOver == true }) { track in
									Text(track.title).font(.headline).accessibilityAddTraits(.isHeader)
									ForEach(project.clips(on: track)) { clip in
										if let source = project.sources.first(where: { $0.id == clip.sourceID }) {
											clipButton(clip, source: source, track: track, count: 1)
										}
									}
								}
							}
							else if tool == .describer {
								transport
								DescriberView(project: $project, timeline: $descriptionTimeline, focus: $focus, keyboardFocus: $keyboardClip,
									time: time, open: openDescription, seek: playback.seek, save: save, shift: openShift)
							} else {
								transport
								CaptionerView(project: $project, playback: playback, focus: $focus, keyboardFocus: $keyboardClip, time: time,
									newCaption: { openCaption(nil) }, edit: { openCaption($0) }, save: save)
							}
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.contentMargins(.all, 0, for: .scrollContent)
			}
		}
		.accessibilityAction(.magicTap) { playback.toggle() }
	}

	private func prepareExportConfirmation() {
		exportCompleted = true
		exportCue.prepare()
	}

	private func projectSheetDismissed() {
		focus = "projectActions"
		guard exportCompleted else { return }
		exportCompleted = false
		Task { await exportCue.play() }
	}

	private var projectActions: [EditorMenuAction] {
		var actions = [EditorMenuAction("Project Settings") { playback.releaseAudio(); projectSheet = .settings }]
		if !project.placements.isEmpty {
			actions.append(EditorMenuAction("Export") {
				guard preparedRevision == revision, let timeline = playback.exportTimeline(named: project.name, captions: project.captions ?? [], project: project) else {
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
		VStack(spacing: 0) {
			ProjectPreview(player: playback.player)
				.overlay {
					if let cues = project.captions, !cues.isEmpty {
						CaptionOverlay(cues: cues, playhead: playback.playhead, aspect: pictureAspect)
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			Button { fullScreenPreview = playback.makePreview() } label: {
				Label("Full Screen Preview", systemImage: "arrow.up.left.and.arrow.down.right")
			}
			.buttonStyle(EditorButtonStyle())
			.fixedSize(horizontal: false, vertical: true)
			.disabled(!playback.ready)
			.accessibilityFocused($focus, equals: "fullScreenPreview")
		}
	}

	private var mainTransitionActions: [EditorMenuAction] {
		[
			EditorMenuAction("Add Transition...") { openTransition(quick: false); trigger = "transitions" },
			EditorMenuAction("Quick Fade") { openTransition(quick: true); trigger = "transitions" },
			EditorMenuAction(selectedTrack.kind == .video ? "Cross Dissolve" : "Cross Fade") {
				trigger = "transitions"
				quickCross()
			}
		]
	}

	@ViewBuilder private var projectRows: some View {
		transport

		DisclosureGroup(isExpanded: $expanded) {
			sourcePicker("Import Clip", source: nil)
			ForEach(project.sources) { source in
				let actions = (source.generator == nil ? [] : [EditorMenuAction("Edit Generator") { openGenerator(source: source, rowID: source.id.uuidString) }]) + [
					EditorMenuAction("Open Cutting Board") { openBoard(source, placement: nil) },
					EditorMenuAction("Rename Clip") { beginRename(source) },
					deleteAction(source, rowID: source.id.uuidString)
				] + (source.generator == nil ? [EditorMenuAction("Reconnect from Files") { pick(source.id, files: true) }, EditorMenuAction("Reconnect from Photos") { pick(source.id, files: false) }] : [])
				Menu { EditorMenuAction.buttons(actions) } label: {
					Text(source.displayName)
						.editorTouchRow(alignment: .leading)
				}
				.contextMenu { EditorMenuAction.buttons(actions) }
				.editorMenuActions(source.displayName, actions)
				.accessibilityFocused($focus, equals: source.id.uuidString)
			}
		} label: { Text("Project Media").editorTouchRow(alignment: .leading) }
		.accessibilityAddTraits(.isHeader)
		TimelineChooser(selection: Binding(get: { pendingEditorTrack ?? activeTrack }, set: selectEditorTrack), options: project.editorTimelines, title: \.title)
			.id("editor-timeline-chooser")
			.transaction { $0.animation = nil }

		VStack(spacing: 0) {
		if editorTimeline.mediaTrack != nil {
		EditorCommandRow {
			Button("Generators") { openGenerator() }
				.accessibilityHint("Adds a generator to your project.")
				.accessibilityFocused($focus, equals: "generator")
			EditorMenuButton(title: "Transitions", actions: mainTransitionActions)
				.accessibilityFocused($focus, equals: "transitions")
				.disabled(!playback.ready || project.displayedClips(on: selectedTrack).isEmpty)
		}
		.buttonStyle(EditorButtonStyle())
		.fixedSize(horizontal: false, vertical: true)
		}
			if let track = editorTimeline.mediaTrack {
				trackHeading(track)
				trackContents(track)
			} else {
				entryHeading
				editorEntryContents
			}
		}
		.opacity(timelineOpacity)
		.task(id: pendingEditorTrack) {
			guard let destination = pendingEditorTrack else {
				withAnimation(reduceMotion ? nil : .easeIn(duration: 0.12)) { timelineOpacity = 1 }
				return
			}
			if !reduceMotion {
				withAnimation(.easeOut(duration: 0.1)) { timelineOpacity = 0 }
				do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
			}
			guard !Task.isCancelled, pendingEditorTrack == destination else { return }
			activeTrack = destination
			keyboardClip = nil
			playback.playhead.navigationLabel = nil
			pendingEditorTrack = nil
			withAnimation(reduceMotion ? nil : .easeIn(duration: 0.12)) { timelineOpacity = 1 }
		}
		.id("editor-timeline-content")

		if let seconds = project.targetSeconds { LabeledContent("Project Duration", value: time(CMTime(seconds: seconds, preferredTimescale: 60000))) }
	}

	private func selectEditorTrack(_ track: String) {
		guard project.editorTimelines.contains(where: { $0.id == track }) else { return }
		if reduceMotion {
			pendingEditorTrack = nil
			activeTrack = track
			keyboardClip = nil
			playback.playhead.navigationLabel = nil
			withAnimation(nil) { timelineOpacity = 1 }
		} else {
			pendingEditorTrack = track == activeTrack ? nil : track
		}
	}

	private func entrySelection(_ id: UUID) -> Set<UUID> {
		selectedEntries.contains(id) ? selectedEntries.intersection(project.editorRows(editorTimeline).map(\.id)) : [id]
	}
	private func selectEntry(_ id: UUID) {
		if selectedEntries.contains(id) { selectedEntries.remove(id) } else { selectedEntries.insert(id) }
	}
	private func entryShift(_ ids: Set<UUID>, title: String) -> TimelineShiftRequest {
		switch editorTimeline {
		case .captions: TimelineShiftRequest(title: title, captions: ids)
		case .descriptions(.audio): TimelineShiftRequest(title: title, descriptions: ids)
		case .descriptions(.transcript): TimelineShiftRequest(title: title, transcripts: ids)
		case .media: TimelineShiftRequest(title: title, clips: ids)
		}
	}
	private func editEntry(_ row: DescriptionRow) {
		switch editorTimeline {
		case .captions:
			if let cue = project.captions?.first(where: { $0.id == row.id }) { openCaption(cue) }
		case .descriptions(let type): descriptionTimeline = type; openDescription(row.id)
		case .media: break
		}
	}
	private func deleteEntries(_ ids: Set<UUID>) {
		var next = project
		let action: String
		switch editorTimeline {
		case .captions:
			next.captions?.removeAll { ids.contains($0.id) }
			action = ids.count == 1 ? "Delete Caption" : "Delete Captions"
		case .descriptions(.audio):
			next.audioDescriptions?.removeAll { ids.contains($0.id) }
			action = ids.count == 1 ? "Delete Audio Description" : "Delete Audio Descriptions"
		case .descriptions(.transcript):
			next.descriptiveTranscript?.removeAll { ids.contains($0.id) }
			action = ids.count == 1 ? "Delete Descriptive Transcript" : "Delete Descriptive Transcripts"
		case .media: return
		}
		commit(next, action: action)
	}
	private func entryActions(_ row: DescriptionRow) -> [EditorMenuAction] {
		let ids = entrySelection(row.id)
		let shiftTitle = ids.count == 1 ? "Shift Clip" : "Shift Clips"
		let editTitle = editorTimeline == .captions ? "Edit Caption" : "Edit " + editorTimeline.title
		let deleteTitle = editorTimeline == .captions ? (ids.count == 1 ? "Delete Caption" : "Delete Captions") : (ids.count == 1 ? "Delete Description" : "Delete Descriptions")
		return [
			EditorMenuAction("Go to Start") { playback.seek(row.start) },
			EditorMenuAction("Go to End") { playback.seek(row.end) },
			EditorMenuAction(editTitle) { editEntry(row) },
			EditorMenuAction(selectedEntries.contains(row.id) ? "Deselect Clip" : "Select Clip") { selectEntry(row.id) },
			EditorMenuAction(shiftTitle) { openShift(entryShift(ids, title: shiftTitle), trigger: row.id.uuidString) },
			EditorMenuAction(deleteTitle) { deleteEntries(ids) }
		]
	}
	@ViewBuilder private var editorEntryContents: some View {
		let rows = project.editorRows(editorTimeline)
		if rows.isEmpty { Text("No entries").editorTouchRow(alignment: .leading) }
		ForEach(rows) { row in
			let actions = entryActions(row)
			Menu { EditorMenuAction.buttons(actions) } label: {
				VStack(alignment: .leading) {
					Text(row.name)
					Text(time(row.start) + " to " + time(row.end)).font(.subheadline)
				}.editorTouchRow(alignment: .leading)
			}
			.contextMenu { EditorMenuAction.buttons(actions) }
			.editorMenuActions(row.name, actions)
			.accessibilityValue((selectedEntries.contains(row.id) ? "Selected, " : "") + time(row.start) + " to " + time(row.end))
			.focused($keyboardClip, equals: row.id.uuidString)
			.accessibilityFocused($focus, equals: row.id.uuidString)
		}
	}

	@ViewBuilder private var entryHeading: some View {
		let actions = [EditorMenuAction("Shift Track") {
			openShift(entryShift(Set(project.editorRows(editorTimeline).map(\.id)), title: "Shift Track"), trigger: editorTimeline.id)
		}]
		Menu { EditorMenuAction.buttons(actions) } label: {
			Text(editorTimeline.title).editorTouchRow(alignment: .leading)
		}
		.editorMenuActions(editorTimeline.title, actions)
		.contextMenu { EditorMenuAction.buttons(actions) }
		.accessibilityAddTraits(.isHeader)
		.accessibilityFocused($focus, equals: editorTimeline.id)
	}

	@ViewBuilder private func trackContents(_ track: TimelineTrack) -> some View {
		let clips = project.displayedClips(on: track)
		let items = project.timelineItems(on: track)
		if clips.isEmpty {
			Text("No clips").editorTouchRow(alignment: .leading)
				.accessibilityDropPoint(.center, description: Text("Drop on " + track.title))
				.dropDestination(for: String.self) { items, _ in drop(items, on: track, beside: nil, after: false) }
		} else {
			ScrollView(.horizontal) {
				HStack(spacing: 0) {
					ForEach(items) { item in
						switch item {
						case .clip(let clip):
							if let source = project.sources.first(where: { $0.id == clip.sourceID }) {
								clipButton(clip, source: source, track: track, count: items.count)
							}
						case .transition(let effect): transitionButton(effect, track: track, count: items.count)
						}
					}
				}
			}
		}
	}

	@ViewBuilder private func trackHeading(_ track: TimelineTrack) -> some View {
		let actions = trackActions(track)
		Menu { EditorMenuAction.buttons(actions) } label: {
			HStack {
				Text(track.title)
				Image(systemName: "chevron.down").accessibilityHidden(true)
			}
			.padding(.horizontal, 12)
			.editorTouchRow(alignment: .leading)
		}
			.accessibilityAddTraits(.isHeader)
			.contextMenu { EditorMenuAction.buttons(actions) }
			.accessibilityFocused($focus, equals: track.id)
			.dropDestination(for: String.self) { items, _ in drop(items, on: track, beside: nil, after: true) }
			.editorMenuActions(track.title, actions)
	}

	private var timelinePoints: [CMTime] {
		switch tool {
		case .editor: return project.editorPoints(editorTimeline)
		case .voicer: return project.editPoints(for: project.voiceClips)
		case .mixer:
			if mixerTrack == EditingProject.descriptionMixID {
				return project.descriptionRows(.audio).flatMap { [$0.start, $0.end] } + project.editPoints(for: [])
			}
			return project.editPoints(on: project.tracks.first { $0.id == mixerTrack } ?? .primaryAudio)
		default: return []
		}
	}

	private var transport: some View {
		Group {
			if tool != .mixer {
				Button("Direct Touch Editor") { directTouch = true }
					.buttonStyle(EditorButtonStyle())
					.accessibilityFocused($focus, equals: "projectDirectTouch")
					.disabled(!playback.ready)
			}
			ProjectTimelineSlider(playhead: playback.playhead, playback: playback, duration: project.duration,
				points: timelinePoints,
				frame: project.frame, format: format, formatTime: time)
				.disabled(!playback.ready)
			Button("Jump to Time", action: openJump)
				.buttonStyle(EditorButtonStyle())
				.accessibilityFocused($focus, equals: "jump")
				.disabled(!playback.ready)
			ViewThatFits(in: .horizontal) {
				HStack(spacing: 0) {
					editPointButton(forward: false)
					playbackButtons
					editPointButton(forward: true)
				}
				.frame(minWidth: wideTransportWidth)
				VStack(spacing: 0) {
					HStack(spacing: 0) { playbackButtons }
					HStack(spacing: 0) {
						editPointButton(forward: false)
						editPointButton(forward: true)
					}
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

	@ViewBuilder private var playbackButtons: some View {
		stepButton(forward: false)
		ProjectShuttleButton(playback: playback, forward: false, boundary: .zero)
		ProjectPlayButton(playback: playback)
		ProjectShuttleButton(playback: playback, forward: true, boundary: project.duration)
		stepButton(forward: true)
	}

	private func editPointTitle(forward: Bool) -> String {
		let direction = forward ? "Next" : "Previous"
		switch tool {
		case .captioner: return direction + " Caption Point"
		case .describer: return direction + " Description Point"
		default: return direction + " Edit Point"
		}
	}

	private func editPointButton(forward: Bool) -> some View {
		Button { navigate(forward: forward, track: selectedTrack) } label: {
			Label(editPointTitle(forward: forward), systemImage: forward ? "forward.end" : "backward.end")
		}
	}

	private var editorTimeline: EditorTimeline {
		project.editorTimelines.first { $0.id == activeTrack } ?? .media(.primaryVideo)
	}

	private var selectedTrack: TimelineTrack {
		project.tracks.first { $0.id == activeTrack } ?? .primaryVideo
	}

	private var directSurface: ProjectTouchSurface {
		let edit: (() -> Void)? = tool == .describer ? { descriptionTap() } : tool == .editor ? {
			let rows = project.editorRows(editorTimeline)
			if let row = rows.first(where: { $0.start == playback.position }) ?? rows.first(where: { $0.end == playback.position }) { editEntry(row) }
		} : nil
		return ProjectTouchSurface(playhead: playback.playhead, playback: playback, formatTime: time, transitions: tool == .editor ? { openTransition(quick: false) } : nil, duration: project.duration,
					captioning: tool == .captioner, editDescription: edit, trackName: touchTrackName, mode: scrubMode, close: { directTouch = false }, swipe: projectSwipe)
	}

	private var directTouchContents: some View {
		VStack(spacing: 0) {
			HStack(spacing: 0) {
				Button("Close") { directTouch = false }
					.buttonStyle(EditorButtonStyle())
					.fixedSize()
				VStack(alignment: .leading) {
					Text("Direct Touch Editor").font(.headline).accessibilityAddTraits(.isHeader)
					Text(touchTrackName).accessibilityHidden(true)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			if preparingTimeline {
				LoadingStatusView("Preparing timeline", cancel: { directTouch = false })
			} else {
				directSurface
					.overlay {
						if let cues = project.captions, !cues.isEmpty {
							CaptionOverlay(cues: cues, playhead: playback.playhead, aspect: pictureAspect)
						}
					}
					.accessibilityFocused($surfaceFocused)
					.directTouchReturnFeedback($returnMessage, ready: playback.ready, focus: $surfaceFocused)
					.onAppear {
						playback.primeScrubAudio()
						surfaceFocused = true
					}
			}
		}
	}

	private var directTouchEditor: some View {
		directTouchContents
		.background(EditorTheme.workspace)
		.editorAppearance()
		.accessibilityAction(.magicTap) { playback.toggle() }
		.sheet(item: transitionBinding(direct: true), onDismiss: finishTransition, content: transitionSheet)
		.sheet(item: generatorBinding(direct: true), onDismiss: finishGenerator, content: generatorSheet)
		.sheet(item: voiceBinding(direct: true), onDismiss: finishVoice, content: voiceSheet)
		.sheet(item: descriptionBinding(direct: true), onDismiss: finishDescription, content: descriptionSheet)
		.sheet(item: captionBinding(direct: true), onDismiss: { finishCaption(direct: true) }, content: captionSheet)
		.alert("Project", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button("OK") { error = nil }
		} message: { Text(error ?? "") }
	}

	private func projectSwipe(_ fingers: Int, _ direction: UISwipeGestureRecognizer.Direction) {
		let forward = direction == .right
		let down = direction == .down
		switch (fingers, direction) {
		case (4, .right) where tool == .editor: openGenerator()
		case (4, .down) where tool == .editor: quickCross()
		case (4, .up) where tool == .editor: openTransition(quick: true)
		case (2, .down) where tool == .voicer: openVoice()
		case (2, .up) where tool == .voicer: break
		case (2, .up) where tool == .describer, (2, .down) where tool == .describer:
			descriptionTimeline = down ? .audio : .transcript
			playback.playhead.navigationLabel = nil
			keyboardClip = nil
			openDescription(nil)
		case (2, .down) where tool == .captioner:
			openCaption(nil)
		case (2, .up) where tool == .captioner:
			break
		case (2, .up), (2, .down):
			let tracks = project.editorTimelines
			guard let index = tracks.firstIndex(of: editorTimeline) else { return }
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


	private func transitionTarget(quick: Bool, track: TimelineTrack?, clip: ProjectPlacement?) throws -> ProjectTransitionRequest {
		guard let track = track ?? editorTimeline.mediaTrack else {
			throw ProjectFailure("Choose a video or audio track in Timeline Chooser to add a transition.")
		}
		let clips = project.displayedClips(on: track)
		let time = playback.position
		let incoming = clips.first { abs(($0.start.time - time).seconds) < project.frame.seconds / 2 }
		let outgoing = incoming.flatMap { next in clips.first { $0.end == next.start.time && $0.id != next.id } }
		guard let selected = clip ?? incoming ?? clips.first(where: { $0.start.time <= time && time < $0.end }) ?? clips.last(where: { $0.end == time }) else {
			throw ProjectFailure("Move the playhead onto a clip or select a timeline clip.")
		}
		let next = clip == nil ? incoming : clips.first { $0.start.time == selected.end }
		let previous = clip == nil ? outgoing : (next == nil ? clips.first { $0.end == selected.start.time } : selected)
		return ProjectTransitionRequest(track: track, clip: selected.id,
			outgoing: quick && clip != nil ? nil : previous?.id,
			incoming: quick && clip != nil ? nil : (next ?? (previous == nil ? nil : selected))?.id,
			quickFade: quick, returnTime: time)
	}
	private func transitionButton(_ effect: ProjectTransition, track: TimelineTrack, count: Int) -> some View {
		let title = effect.title(audio: track.kind == .audio)
		let names = [effect.outgoing, effect.incoming].compactMap { $0 }.compactMap { clipName(for: $0) }
		let context = names.joined(separator: " to ")
		let rowID = "transition/" + track.id + "/" + effect.id.uuidString
		let duration = effect.seconds.formatted(.number.precision(.fractionLength(0...3)))
		let value = (track.id != effect.trackID ? "Linked audio, " : "") + "Duration " + duration + " seconds"
		return Button { editTransition(effect, track: track) } label: {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
				Text(context).font(.subheadline)
			}
			.fixedSize(horizontal: false, vertical: true)
			.padding(.horizontal, 6)
			.frame(minHeight: 48)
			.containerRelativeFrame(.horizontal) { width, _ in max(120, width / CGFloat(count)) }
			.background(.quaternary, in: RoundedRectangle(cornerRadius: 8).inset(by: 2))
		}
		.buttonStyle(.plain)
		.accessibilityLabel(title + ", " + context)
		.accessibilityValue(Text(value))
		.accessibilityAction(named: "Edit Transition") { editTransition(effect, track: track) }
		.contextMenu { Button("Edit Transition") { editTransition(effect, track: track) } }
		.focused($keyboardClip, equals: rowID)
		.accessibilityFocused($focus, equals: rowID)
	}
	private func editTransition(_ effect: ProjectTransition, track: TimelineTrack) {
		guard let owner = project.tracks.first(where: { $0.id == effect.trackID }), let clip = effect.incoming ?? effect.outgoing else { return }
		playback.pause()
		trigger = "transition/" + track.id + "/" + effect.id.uuidString
		let linked = project.placements.first { $0.id == clip }?.trackID != track.id
		transitionFallback = (linked ? "linked/" : "") + clip.uuidString
		transitionChanged = false
		transitionRequest = ProjectTransitionRequest(track: owner, clip: clip, outgoing: effect.outgoing, incoming: effect.incoming,
			quickFade: false, returnTime: playback.position, existingID: effect.id)
	}
	private func openTransition(quick: Bool, track: TimelineTrack? = nil, clip: ProjectPlacement? = nil) {
		do {
			transitionFallback = nil
			let request = try transitionTarget(quick: quick, track: track, clip: clip)
			playback.pause()
			if clip == nil { trigger = request.track.id }
			transitionChanged = false
			transitionRequest = request
		} catch { self.error = error.localizedDescription }
	}
	private func quickCross(track: TimelineTrack? = nil, clip: ProjectPlacement? = nil) {
		do {
			let request = try transitionTarget(quick: false, track: track, clip: clip)
			guard request.between else { throw ProjectFailure("Move to an edit point where two clips meet.") }
			let effect = ProjectTransition(trackID: request.track.id, outgoing: request.outgoing, incoming: request.incoming,
				edge: .between, seconds: TransitionEditorView.lastDuration(audio: request.track.kind == .audio))
			var next = project
			var effects = next.transitions ?? []
			effects.removeAll { $0.trackID == effect.trackID && $0.edge == .between && $0.outgoing == effect.outgoing && $0.incoming == effect.incoming }
			effects.append(effect)
			next.transitions = effects
			try next.validateTransitions()
			let name = effect.title(audio: request.track.kind == .audio)
			playback.pause()
			try save(next, action: "Apply " + name)
			if !directTouch { placementFocus = trigger ?? request.track.id }
			UIAccessibility.post(notification: .announcement, argument: name + " Applied")
		} catch { self.error = error.localizedDescription }
	}
	private func transitionBinding(direct: Bool) -> Binding<ProjectTransitionRequest?> {
		Binding(get: { directTouch == direct ? transitionRequest : nil }, set: { if directTouch == direct { transitionRequest = $0 } })
	}
	private func transitionSheet(_ request: ProjectTransitionRequest) -> some View {
		TransitionEditorView(project: project, request: request, format: format, formatTime: time) { next, action in
			try save(next, action: action)
			transitionChanged = true
		}
	}
	private func finishTransition() {
		if let trigger, trigger.hasPrefix("transition/"), let id = trigger.split(separator: "/").last,
			!project.timelineItems(on: selectedTrack).contains(where: { $0.id == "transition/" + id }) {
			self.trigger = transitionFallback
		}
		transitionFallback = nil
		if directTouch { returnMessage = directTouchReturnMessage() }
		else if transitionChanged && preparingTimeline { placementFocus = trigger }
		else { focus = trigger }
		transitionChanged = false
	}

	private func openJump() {
		playback.pause()
		jumping = true
	}

	private func step(_ count: Int32) {
		playback.stepWithAudio(forward: count > 0, frame: project.frame, count: abs(count))
	}

	private func stepButton(forward: Bool) -> some View {
		let direction = forward ? "Step Forward" : "Step Back"
		let count: Int32 = forward ? 1 : -1
		return Button { step(count) } label: {
			Label(direction + " One Frame", systemImage: forward ? "forward.frame" : "backward.frame")
		}
		.accessibilityActions {
			Button(direction + " 10 Frames") { step(count * 10) }
			Button(editPointTitle(forward: forward)) {
				navigate(forward: forward, track: selectedTrack)
			}
		}
	}

	private func navigate(forward: Bool, track: TimelineTrack) {
		let point: (time: CMTime, name: String)
		switch tool {
		case .editor: point = project.editorPoint(editorTimeline, from: playback.position, forward: forward)
		case .captioner: point = project.captionPoint(from: playback.position, forward: forward)
		case .describer: point = project.descriptionPoint(descriptionTimeline, from: playback.position, forward: forward)
		case .mixer where mixerTrack == EditingProject.descriptionMixID:
			point = project.descriptionPoint(.audio, from: playback.position, forward: forward)
		default:
			let destination = tool == .mixer ? project.tracks.first { $0.id == mixerTrack } ?? .primaryAudio : track
			point = project.navigationPoint(from: playback.position, forward: forward, on: destination, voiceOver: tool == .voicer)
		}
		let label = point.name + ", " + time(point.time)
		playback.seek(point.time)
		playback.playhead.navigationLabel = label
		UIAccessibility.post(notification: .announcement, argument: label)
	}

	private func setMarker(_ isIn: Bool, to point: ProjectTime?, spoken: Bool = false) {
		var next = project
		if isIn { next.markIn = point } else { next.markOut = point }
		do {
			try save(next, action: (point == nil ? "Clear " : "Mark ") + (isIn ? "In" : "Out"))
			if spoken {
				let message = point == nil ? (isIn ? "In Removed" : "Out Removed") : (isIn ? "Marked In" : "Marked Out")
				UIAccessibility.post(notification: .announcement, argument: message)
			}
		} catch { self.error = error.localizedDescription }
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
		.accessibilityValue((linked ? "Linked audio, " : "") + (marked.contains(clip.id) ? "Selected, " : "") + "Start " + time(clip.start.time) + ", duration " + time(clip.duration))
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

	private func openShift(_ request: TimelineShiftRequest, trigger row: String) {
		playback.pause()
		trigger = row
		shifting = request
	}

	private func trackActions(_ track: TimelineTrack) -> [EditorMenuAction] {
		var actions = [
			EditorMenuAction("Shift Track") { openShift(TimelineShiftRequest(title: "Shift Track", clips: Set(project.displayedClips(on: track).map(\.id))), trigger: track.id) },
			EditorMenuAction("Add Generator") { openGenerator(track: track, rowID: track.id) },
			EditorMenuAction(project.isMagnetic(track) ? "Turn Magnetic Off" : "Turn Magnetic On") {
				let enabled = !project.isMagnetic(track)
				if enabled && project.needsPacking(track) { confirmPacking = track }
				else { changeMagnetic(enabled, on: track) }
			},
			EditorMenuAction("Transitions") { trigger = track.id; openTransition(quick: false, track: track) },
			EditorMenuAction("Quick Fade") { trigger = track.id; openTransition(quick: true, track: track) },
			EditorMenuAction(track.kind == .audio ? "Cross Fade" : "Cross Dissolve") { trigger = track.id; quickCross(track: track) },
			EditorMenuAction("Track Effects") { trigger = track.id; playback.releaseAudio(); effects = track }
		]
		if !dragging.isEmpty && project.displayedClips(on: track).isEmpty && project.placements.filter({ dragging.contains($0.id) }).allSatisfy({ $0.track == track.kind }) {
			actions.append(EditorMenuAction("Drop on Track") { move(dragging, on: track, beside: nil, after: false) })
		}
		return actions
	}

	private func changeMagnetic(_ enabled: Bool, on track: TimelineTrack) {
		var next = project
		next.setMagnetic(enabled, on: track)
		if next.placements != project.placements { placementFocus = track.id }
		commit(next, action: enabled ? "Enable Magnetic" : "Disable Magnetic")
		focus = track.id
	}

	private func restoreClipFocus() {
		if placementNeedsRebuild {
			placementNeedsRebuild = false
			placementFocus = trigger
			revision += 1
		} else { focus = trigger; placementFocus = nil }
	}

	private func moveClip(_ clip: ProjectPlacement, to time: CMTime, exact: Bool) throws {
		guard let owner = project.tracks.first(where: { $0.id == clip.trackID }) else { throw ProjectFailure("Reopen the clip on its track.") }
		var next = project
		try next.moveClip(clip.id, to: time, on: owner, exact: exact)
		let moved = next.placements != project.placements
		try save(next, action: exact ? "Move to Time" : "Move to Playhead")
		if moved { placementFocus = trigger }
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
		let selection: Set<UUID> = marked.contains(clip.id) ? marked : [clip.id]
		let shiftTitle = selection.count == 1 ? "Shift Clip" : "Shift Clips"
		let track = linked ? project.audioPartner(for: clip.trackID) : project.tracks.first { $0.id == clip.trackID }
		var actions = [
			EditorMenuAction(shiftTitle) { openShift(TimelineShiftRequest(title: shiftTitle, clips: selection), trigger: rowID) },
			EditorMenuAction("Transitions") { trigger = rowID; openTransition(quick: false, track: track, clip: clip) },
			EditorMenuAction("Quick Fade") { trigger = rowID; openTransition(quick: true, track: track, clip: clip) },
			EditorMenuAction(linked || clip.track == .audio ? "Cross Fade" : "Cross Dissolve") { trigger = rowID; quickCross(track: track, clip: clip) },
			EditorMenuAction(selection.count > 1 ? "Open Clips Cutting Board" : "Open Cutting Board") { openSelectedBoard(clip, source: source, track: track, rowID: rowID) },
			EditorMenuAction("Move to Playhead") {
				playback.pause()
				trigger = rowID
				do { try moveClip(clip, to: playback.position, exact: false) } catch { self.error = error.localizedDescription }
			},
			EditorMenuAction("Move to Time") { playback.pause(); trigger = rowID; movingToTime = clip },
			EditorMenuAction("Move to New Track") { playback.pause(); trigger = rowID; newTrackName = ""; trackForMove = clip },
			EditorMenuAction(marked.contains(clip.id) ? "Deselect Clip" : "Select Clip") { toggleMark(clip.id) }
		]
		if source.generator != nil { actions.append(EditorMenuAction("Edit Generator") { openGenerator(source: source, clip: clip, rowID: rowID) }) }
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
		actions.append(EditorMenuAction(selection.count > 1 ? "Remove Clips from Track" : linked ? "Remove Linked Clip Pair" : "Remove from Track") {
			var next = project
			next.removeClips(selection)
			commit(next, action: selection.count > 1 ? "Remove Clips" : "Remove Clip")
		})
		actions.append(deleteAction(source, rowID: rowID))
		return actions
	}

	private func deleteAction(_ source: ProjectMediaSource, rowID: String) -> EditorMenuAction {
		EditorMenuAction("Delete from Project") {
			trigger = rowID
			deletingSource = source
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
		playback.releaseAudio()
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

	private func generatorBinding(direct: Bool) -> Binding<GeneratorRequest?> {
		Binding(get: { directTouch == direct ? generatorRequest : nil }, set: { if directTouch == direct { generatorRequest = $0 } })
	}

	private func generatorSheet(_ request: GeneratorRequest) -> some View {
		GeneratorEditorView(project: project, request: request) { next, action in
			try save(next, action: action)
			if !directTouch && preparingTimeline { placementFocus = trigger }
		}
	}

	private func finishGenerator() {
		if directTouch { returnMessage = directTouchReturnMessage() }
		else if preparingTimeline { placementFocus = trigger }
		else { focus = trigger }
	}

	private func openGenerator(track: TimelineTrack? = nil, source: ProjectMediaSource? = nil, clip: ProjectPlacement? = nil, rowID: String = "generator") {
		guard let destination = track ?? editorTimeline.mediaTrack else {
			error = "Choose a video or audio track in Timeline Chooser to add a generator."; return
		}
		playback.releaseAudio()
		trigger = rowID
		generatorRequest = GeneratorRequest(track: destination, time: playback.position, source: source, clip: clip)
	}

	private func openSelectedBoard(_ clip: ProjectPlacement, source: ProjectMediaSource, track: TimelineTrack?, rowID: String?) {
		let ids: Set<UUID> = marked.contains(clip.id) ? marked : [clip.id]
		guard ids.count > 1 else { openBoard(source, placement: clip, rowID: rowID); return }
		guard let track else { error = "Select clips on the same track."; return }
		let request = ClipsBoardRequest(project: project, track: track, ids: ids)
		do {
			_ = try ClipsBoardModel(request)
			playback.releaseAudio()
			trigger = rowID ?? clip.id.uuidString
			clipsBoard = request
		} catch { self.error = error.localizedDescription }
	}

	private func openBoard(_ source: ProjectMediaSource, placement: ProjectPlacement?, rowID: String? = nil) {
		playback.releaseAudio()
		trigger = rowID ?? (placement?.id ?? source.id).uuidString
		clipTask = Task {
			defer { if !Task.isCancelled { clipTask = nil } }
			do {
				var effective = source
				if let definition = placement?.generatorOverride { effective.reference = .generated(definition) }
				let access = try await effective.open()
				try Task.checkCancellation()
				let session = try await CuttingBoardSession.openReferenced(asset: access.asset, title: placement?.displayName(for: source) ?? source.displayName, access: access, ranges: placement?.ranges.map(\.range), generatedFrame: source.generator == nil ? nil : source.picture?.frame.time)
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
			update: board.placement == nil ? nil : { quick(.update) }, placementSheet: { directTouch, placed in
				AnyView(PlacementSheet(tracks: project.tracks.filter { $0.kind == kind }, destination: destination(),
					offersAudio: kind == .video && board.source.hasAudio, directTouch: directTouch) { track, name, mode, omitAudio in
					do {
						try place(board, mode: mode, track: track, newName: name, omitAudio: omitAudio, announce: { message in
							if directTouch { placed(message) } else { UIAccessibility.post(notification: .announcement, argument: message) }
						})
						board.session.choosingPlacement = false
						return nil
					} catch { return error.localizedDescription }
				})
			}, compositingSheet: board.placement == nil || kind != .video ? nil : {
				guard let clip = project.placements.first(where: { $0.id == board.placement?.id }) else { return AnyView(EmptyView()) }
				return AnyView(ClipCompositingSheet(project: project, clip: clip, save: save))
			})
	}

	private func place(_ editing: ProjectBoard, mode: PlacementMode, track: TimelineTrack, newName: String? = nil, omitAudio: Bool = false,
		announce: (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) }) throws {
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
		let editedPlacement = updating && next.placements != project.placements
		try save(next, action: action)
		activeTrack = destination.id
		if updating {
			if editedPlacement { placementFocus = trigger }
			board = nil
		}
		else { announce((mode == .append ? "Appended to " : "Added to ") + destination.title) }
	}

	private func commit(_ next: EditingProject, action: String) {
		do { try save(next, action: action) } catch { self.error = error.localizedDescription }
	}

	private func save(_ next: EditingProject, action: String) throws {
		guard next != project else { return }
		var next = next
		if let point = next.markIn, point.time > next.duration { next.markIn = nil }
		if let point = next.markOut, point.time > next.duration { next.markOut = nil }
		next.cleanTransitions()
		try next.validateTransitions()
		next.version = 12
		try saves.enqueue(next, replacing: project)
		undo.append(HistoryEntry(project: project, action: action))
		redo.removeAll()
		update(next)
	}

	private func history(back: Bool) {
		guard let entry = back ? undo.last : redo.last else { return }
		do {
			try saves.enqueue(entry.project, replacing: project)
			let inverse = HistoryEntry(project: project, action: entry.action)
			if back { undo.removeLast(); redo.append(inverse) }
			else { redo.removeLast(); undo.append(inverse) }
			dragging.removeAll()
			update(entry.project)
			UIAccessibility.post(notification: .announcement, argument: (back ? "Undo " : "Redo ") + entry.action)
		} catch { self.error = error.localizedDescription }
	}

	private func trackEffectsSheet(_ track: TimelineTrack) -> some View {
		TrackEffectsSheet(track: track, project: project, start: playback.position, format: format, formatTime: time, measurements: playback.measurements) { volume, effects in
			var next = project
			var levels = next.trackVolumes ?? [:]
			if volume != (levels[track.id] ?? 1) { levels[track.id] = volume }
			next.trackVolumes = levels.isEmpty ? nil : levels
			var settings = next.trackEffects ?? [:]
			settings[track.id] = effects == TrackAudioEffects() ? nil : effects
			next.trackEffects = settings.isEmpty ? nil : settings
			let rebuild = next.trackEffects != project.trackEffects
			try save(next, action: "Track Effects")
			if rebuild { placementFocus = track.id }
			self.effects = nil
		}
	}

	private func applyMixerEdit(_ next: EditingProject, action: String, commit: Bool) {
		if commit {
			do { try save(next, action: action) }
			catch { self.error = error.localizedDescription }
			playback.updateMix(project, solo: soloTracks)
		} else { playback.updateMix(next, solo: soloTracks, preview: true) }
	}

	private func update(_ next: EditingProject) {
		let usedSources = Set(next.placements.map(\.sourceID))
		func timelineReferences(_ model: EditingProject) -> [UUID: ProjectMediaSource.Reference] {
			Dictionary(uniqueKeysWithValues: model.sources.filter { usedSources.contains($0.id) }.map { ($0.id, $0.reference) })
		}
		let rebuild = project.transitions != next.transitions || project.trackEffects != next.trackEffects || project.audioDescriptions != next.audioDescriptions || project.descriptionDucking != next.descriptionDucking || project.picture != next.picture || project.placements != next.placements || timelineReferences(project) != timelineReferences(next) || project.tracks != next.tracks
		if !rebuild && (project.trackStereo != next.trackStereo || project.trackVolumes != next.trackVolumes || project.masterVolume != next.masterVolume || project.mutedTracks != next.mutedTracks) {
			playback.updateMix(next, solo: soloTracks)
		}
		if playback.mixerLoop != nil { playback.setMixerLoop(next.captionRange) }
		if !(next.mixerChannels.contains { $0.id == mixerTrack }) { mixerTrack = TimelineTrack.primaryAudio.id }
		soloTracks.formIntersection(next.mixerChannels.map(\.id))
		if playback.playhead.navigationLabel != nil { playback.playhead.navigationLabel = nil }
		project = next
		let valid = Set(next.placements.map(\.id))
		selectedEntries.formIntersection(next.editorTimelines.flatMap { next.editorRows($0).map(\.id) })
		marked.formIntersection(valid)
		dragging.formIntersection(valid)
		if !next.editorTimelines.contains(where: { $0.id == activeTrack }) { activeTrack = TimelineTrack.primaryVideo.id }
		if rebuild {
			if voiceInsertion != nil { placementNeedsRebuild = true }
			else if descriptionEntry != nil { descriptionNeedsRebuild = true }
			else if clipsBoard != nil || shifting != nil || movingToTime != nil || trackForMove != nil { placementNeedsRebuild = true }
			else { revision += 1 }
		}
	}

	private var touchTrackName: String {
		switch tool {
		case .editor: editorTimeline.title
		case .captioner, .voicer, .mixer: tool.rawValue
		case .describer: descriptionTimeline.rawValue
		}
	}

	private func openVoice() {
		playback.releaseAudio()
		voiceInsertion = VoiceInsertion(time: playback.position)
	}

	private func voiceBinding(direct: Bool) -> Binding<VoiceInsertion?> {
		Binding(get: { directTouch == direct ? voiceInsertion : nil }, set: { if directTouch == direct { voiceInsertion = $0 } })
	}

	private func voiceSheet(_ entry: VoiceInsertion) -> some View {
		VoicerRecordingView(project: project, position: entry.time, format: format,
			initialTime: time(entry.time).replacingOccurrences(of: "Frame ", with: ""), playback: playback, save: save)
	}

	private func finishVoice() {
		if directTouch { returnMessage = directTouchReturnMessage() }
		if placementNeedsRebuild {
			placementNeedsRebuild = false
			if !directTouch { placementFocus = "recordVoice" }
			revision += 1
		} else if !directTouch { focus = "recordVoice" }
	}

	private func descriptionBinding(direct: Bool) -> Binding<DescriptionEntry?> {
		Binding(get: { directTouch == direct ? descriptionEntry : nil }, set: { if directTouch == direct { descriptionEntry = $0 } })
	}

	private func descriptionTap() {
		let rows = project.descriptionRows(descriptionTimeline)
		let position = playback.position
		openDescription((rows.first { $0.start == position } ?? rows.first { $0.end == position })?.id)
	}

	private func openDescription(_ id: UUID?) {
		guard descriptionEntry == nil else { return }
		let transcript = project.descriptiveTranscript?.first { $0.id == id }
		let take = project.audioDescriptions?.first { $0.id == id }
		let range: CMTimeRange
		if let transcript { range = CMTimeRange(start: transcript.start.time, end: transcript.end.time) }
		else if let take { range = CMTimeRange(start: take.start.time, end: take.limit.time) }
		else if let marked = project.captionRange { range = marked }
		else { error = "Mark In and Out around the passage, then choose New Description."; return }
		playback.releaseAudio()
		descriptionTrigger = id?.uuidString ?? "newDescription"
		descriptionSaved = false
		descriptionEntry = DescriptionEntry(timeline: descriptionTimeline, transcript: transcript, take: take, range: range)
	}

	private func descriptionSheet(_ entry: DescriptionEntry) -> some View {
		DescriptionEntryView(entry: entry, project: project, playback: playback, time: time) { next, action in
			try save(next, action: action)
			descriptionSaved = true
		}
	}

	private func finishDescription() {
		if descriptionNeedsRebuild {
			descriptionNeedsRebuild = false
			if directTouch { restoreDescriptionFocus() } else { restoringDescription = true }
			revision += 1
		} else { restoreDescriptionFocus() }
	}

	private func restoreDescriptionFocus() {
		restoringDescription = false
		if directTouch {
			returnMessage = directTouchReturnMessage(after: descriptionSaved ? "Description Saved" : nil)
			descriptionSaved = false
			return
		}
		focus = descriptionTrigger
		if descriptionSaved {
			descriptionSaved = false
			let message = NSAttributedString(string: "Description Saved", attributes: [.accessibilitySpeechQueueAnnouncement: true])
			UIAccessibility.post(notification: .announcement, argument: message)
		}
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
		playback.releaseAudio()
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
		if direct {
			returnMessage = directTouchReturnMessage(after: captionCreated ? "Caption Created" : nil)
			captionCreated = false
			return
		}
		focus = captionTrigger
		if captionCreated {
			captionCreated = false
			let message = NSAttributedString(string: "Caption Created", attributes: [.accessibilitySpeechQueueAnnouncement: true])
			UIAccessibility.post(notification: .announcement, argument: message)
		}
	}

	private func projectKey(_ key: String, flags: UIKeyModifierFlags) {
		// Transport and markers must not wait for clip sorting or focus resolution.
		switch key {
		case "g" where flags.isEmpty && tool == .editor: openGenerator(); return
		case "x" where flags.isEmpty && tool == .editor:
			trigger = selectedTrack.id
			quickCross()
			return
		case "f" where flags.isEmpty && tool == .editor: openTransition(quick: true); return
		case "t" where flags.contains(.command) && tool == .editor: openTransition(quick: false); return
		case " ", "k": playback.toggle(); return
		case "j", "l": playback.shuttle(forward: key == "l"); return
		case "i", "o":
			setMarker(key == "i", to: flags.contains(.alternate) ? nil : ProjectTime(playback.position), spoken: true)
			return
		case "z": history(back: !flags.contains(.shift)); return
		case "t" where flags.isEmpty:
			UIAccessibility.post(notification: .announcement, argument: time(playback.position))
			return
		default: break
		}
		if key.lowercased() == "m", flags.contains([.command, .shift]) { tool = .mixer; return }
		if tool == .mixer, flags.contains([.command, .alternate]), key == UIKeyCommand.inputUpArrow || key == UIKeyCommand.inputDownArrow {
			let tracks = project.mixerChannels
			if let index = tracks.firstIndex(where: { $0.id == mixerTrack }) {
				let delta = key == UIKeyCommand.inputUpArrow ? -1 : 1
				mixerTrack = tracks[(index + delta + tracks.count) % tracks.count].id
			}
			return
		}
		if key.lowercased() == "v", flags.contains([.command, .shift]) {
			tool = .voicer
			openVoice()
			return
		}
		if key.lowercased() == "d", flags.contains([.command, .shift]) {
			tool = .describer
			openDescription(nil)
			return
		}
		if tool != .editor {
			switch key {
			case "c" where tool == .captioner: openCaption(nil)
			case "\r" where tool == .describer:
				let rows = project.descriptionRows(descriptionTimeline)
				if let row = rows.first(where: { $0.id.uuidString == (keyboardClip ?? focus) }) ?? rows.first(where: { $0.start <= playback.position && playback.position < $0.end }) { openDescription(row.id) }
			case "\r" where tool == .captioner:
				if let cue = project.captions?.first(where: { ($0.id.uuidString == (keyboardClip ?? focus)) }) ??
					project.captions?.first(where: { $0.start.time <= playback.position && playback.position < $0.end.time }) { openCaption(cue) }
			case ";", "'": navigate(forward: key == "'", track: selectedTrack)
			case UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow:
				let forward = key == UIKeyCommand.inputRightArrow
				if flags.contains(.command) { navigate(forward: forward, track: selectedTrack) }
				else { step((forward ? 1 : -1) * (flags.contains(.shift) ? 10 : 1)) }
			case UIKeyCommand.inputHome, UIKeyCommand.inputUpArrow: keyboardBoundary(end: false)
			case UIKeyCommand.inputEnd, UIKeyCommand.inputDownArrow: keyboardBoundary(end: true)
			default: break
			}
			return
		}
		if flags.contains([.command, .alternate]), key == UIKeyCommand.inputUpArrow || key == UIKeyCommand.inputDownArrow {
			let tracks = project.editorTimelines
			if let index = tracks.firstIndex(where: { $0.id == (pendingEditorTrack ?? activeTrack) }) {
				let target = index + (key == UIKeyCommand.inputUpArrow ? -1 : 1)
				if tracks.indices.contains(target) {
					selectEditorTrack(tracks[target].id)
					UIAccessibility.post(notification: .announcement, argument: tracks[target].title)
				}
			}
			return
		}
		if editorTimeline.mediaTrack == nil {
			let rows = project.editorRows(editorTimeline)
			let row = rows.first { $0.id.uuidString == (keyboardClip ?? focus) } ?? rows.first { $0.start <= playback.position && playback.position < $0.end }
			switch key {
			case "c", "\r": if let row { editEntry(row) }
			case "s": if let row { selectEntry(row.id) }
			case "\u{8}", UIKeyCommand.inputDelete: if let row { deleteEntries(entrySelection(row.id)) }
			case ";", "'": navigate(forward: key == "'", track: selectedTrack)
			case UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow:
				let forward = key == UIKeyCommand.inputRightArrow
				if flags.contains(.command) { navigate(forward: forward, track: selectedTrack) }
				else { step((forward ? 1 : -1) * (flags.contains(.shift) ? 10 : 1)) }
			case UIKeyCommand.inputHome, UIKeyCommand.inputUpArrow: keyboardBoundary(end: false)
			case UIKeyCommand.inputEnd, UIKeyCommand.inputDownArrow: keyboardBoundary(end: true)
			default: break
			}
			return
		}
		let focusedRow = keyboardClip ?? focus
		let focusedID = focusedRow?.split(separator: "/").last.flatMap { UUID(uuidString: String($0)) }
		if focusedRow?.hasPrefix("transition/") == true, ["c", "\r"].contains(key),
			let effect = project.transitions?.first(where: { $0.id == focusedID }) {
			editTransition(effect, track: selectedTrack); return
		}
		let focusedClip = project.displayedClips(on: selectedTrack).first { $0.id == focusedID }
		var trackID = focusedClip?.trackID ?? activeTrack
		if focusedRow?.hasPrefix("linked/") == true, let partner = project.audioPartner(for: trackID) { trackID = partner.id }
		guard let track = project.tracks.first(where: { $0.id == trackID }) else { return }
		let clips = project.displayedClips(on: track)
		let position = playback.position
		let clip = focusedClip ?? clips.first { $0.end > position }
		let destinationTrack = clip.flatMap { placement in project.tracks.first { $0.id == placement.trackID } } ?? track
		var next = project
		switch key {
		case "s":
			if let clip {
				if flags.contains(.shift) {
					if dragging.isEmpty { startDrag(clip) }
					else if project.placements.filter({ dragging.contains($0.id) }).allSatisfy({ $0.track == clip.track }) { addToDrag(clip) }
				} else { toggleMark(clip.id) }
			}
		case UIKeyCommand.inputEscape: dragging.removeAll(); dropAnchor = nil
		case "v":
			if !dragging.isEmpty {
				move(dragging, on: destinationTrack, beside: dropAnchor ?? clip?.id, after: dropAnchor == nil ? true : dropAfter)
			}
		case "c", "\r":
			if let clip, let source = project.sources.first(where: { $0.id == clip.sourceID }) { openSelectedBoard(clip, source: source, track: track, rowID: focusedClip == nil ? nil : focusedRow) }
		case UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow:
			if flags.contains(.alternate), let index = project.tracks.firstIndex(of: track) {
				let target = index + (key == UIKeyCommand.inputUpArrow ? -1 : 1)
				if project.tracks.indices.contains(target) {
					playback.playhead.navigationLabel = nil
					activeTrack = project.tracks[target].id
					keyboardClip = nil
					focus = activeTrack
				}
			} else { keyboardBoundary(end: key == UIKeyCommand.inputDownArrow) }
		case UIKeyCommand.inputHome: keyboardBoundary(end: false)
		case UIKeyCommand.inputEnd: keyboardBoundary(end: true)
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
			if key != "b", next.isMagnetic(destinationTrack), let source = project.sources.first(where: { $0.id == clip.sourceID }) {
				let trimmed = key == "[" ? right : left
				do {
					try next.place(source, ranges: trimmed.ranges.map(\.range), at: clip.start.time, on: destinationTrack, mode: .update, replacing: clip.id, omitAudio: clip.omitAudio == true)
					try save(next, action: "Trim Clip")
					UIAccessibility.post(notification: .announcement, argument: key == "[" ? "Head trimmed to playhead" : "Tail trimmed to playhead")
				} catch { self.error = error.localizedDescription }
				return
			}
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
			keyboardEdit(next, action: key == "b" ? "Split Clip" : "Trim Clip",
				confirmation: key == "b" ? "Clip split" : (key == "[" ? "Head trimmed to playhead" : "Tail trimmed to playhead"))
		case "\u{8}", UIKeyCommand.inputDelete:
			if let clip {
				let ids: Set<UUID> = marked.contains(clip.id) ? marked : [clip.id]
				next.removeClips(ids)
				keyboardEdit(next, action: ids.count == 1 ? "Remove Clip" : "Remove Clips",
					confirmation: ids.count == 1 ? "Removed 1 clip" : "Removed \(ids.count) clips")
			}
		default: break
		}
	}

	private func keyboardBoundary(end: Bool) {
		playback.seek(end ? project.duration : .zero)
		let label = (end ? "End" : "Start") + ", " + time(playback.position)
		playback.playhead.navigationLabel = label
		UIAccessibility.post(notification: .announcement, argument: label)
	}

	private func keyboardEdit(_ next: EditingProject, action: String, confirmation: String) {
		do {
			try save(next, action: action)
			UIAccessibility.post(notification: .announcement, argument: confirmation)
		} catch { self.error = error.localizedDescription }
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
	let boundary: CMTime

	var body: some View {
		let rate = playback.transport.shuttleRate
		let active = forward ? rate > 0 : rate < 0
		let name = forward ? "Fast Forward" : "Rewind"
		Button { playback.shuttle(forward: forward) } label: {
			Image(systemName: forward ? "forward.fill" : "backward.fill")
				.accessibilityHidden(true)
		}
		.accessibilityLabel(Text(name))
		.accessibilityAction(named: forward ? Text("Go to End") : Text("Go to Start")) { playback.seek(boundary) }
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

private func configureProjectPreview(_ layer: AVPlayerLayer) {
	#if targetEnvironment(simulator)
	// The simulator's display queue can reject the composited YUV frames during preroll.
	layer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
	#endif
	layer.videoGravity = .resizeAspect
}

struct ProjectPreview: UIViewRepresentable {
	let player: AVPlayer

	final class FrameView: UIView {
		override class var layerClass: AnyClass { AVPlayerLayer.self }
	}

	func makeUIView(context: Context) -> FrameView {
		let view = FrameView()
		configureProjectPreview(view.layer as! AVPlayerLayer)
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
	let audition: EditingProject
	let start: CMTime
	let format: TimecodeFormat
	let formatTime: (CMTime) -> String
	let save: (Float, TrackAudioEffects) throws -> Void
	@StateObject private var preview: ProjectPlayback
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var phase
	@State private var volume: Double
	@State private var effects: TrackAudioEffects
	@State private var bypass = false
	@State private var measuring = false
	@State private var error: String?
	@AccessibilityFocusState private var pickerFocused: Bool

	init(track: TimelineTrack, project: EditingProject, start: CMTime, format: TimecodeFormat,
		formatTime: @escaping (CMTime) -> String, measurements: ClipLoudnessMeasurements, save: @escaping (Float, TrackAudioEffects) throws -> Void) {
		self.track = track
		self.start = start
		self.format = format
		self.formatTime = formatTime
		_preview = StateObject(wrappedValue: ProjectPlayback(measurements: measurements))
		self.save = save
		_volume = State(initialValue: Double(project.trackVolumes?[track.id] ?? 1))
		_effects = State(initialValue: project.trackEffects?[track.id] ?? TrackAudioEffects())
		var draft = project
		let audio = project.audioPartner(for: track.id)
		let clips = project.displayedClips(on: track) + (audio.map { project.clips(on: $0) } ?? [])
		let ids = Set(clips.map(\.id))
		draft.placements = project.placements.filter { ids.contains($0.id) }
		draft.audioDescriptions = nil
		draft.descriptionDucking = nil
		draft.mutedTracks = nil
		audition = draft
	}

	var body: some View {
		NavigationStack {
			Form {
				if audition.duration > .zero {
					Section {
						if track.kind == .video {
							ProjectPreview(player: preview.player)
								.aspectRatio(CGFloat(audition.picture?.width ?? 16) / CGFloat(audition.picture?.height ?? 9), contentMode: .fit)
						}
						ProjectTimelineSlider(playhead: preview.playhead, playback: preview, duration: audition.duration,
							points: audition.editPoints(on: track), frame: audition.frame, format: format, formatTime: formatTime)
						Button { preview.toggle() } label: {
							Label(preview.transport.playing ? "Pause" : "Play", systemImage: preview.transport.playing ? "pause.fill" : "play.fill")
								.labelStyle(.iconOnly).frame(maxWidth: .infinity, minHeight: 44)
						}
						Toggle("Bypass Effects", isOn: $bypass)
							.disabled(!hasPreviewEffects)
					}
					.disabled(!preview.ready)
				}
				Section {
					slider("Volume", value: $volume, range: 0...Double(EditingProject.maximumMixerLevel), step: 0.01,
						reading: volume.formatted(.percent.precision(.fractionLength(0))))
					if track.kind == .audio {
						Menu {
							Button("Match Loudness") {
								effects.loudness = .init()
								bypass = false
								measuring = preview.ready
								pickerFocused = true
							}.disabled(effects.loudness != nil)
							Button("Even Out Volume") {
								effects.smoothing = .init()
								bypass = false
								pickerFocused = true
							}.disabled(effects.smoothing != nil)
						} label: {
							Text("Effects").editorTouchRow(alignment: .leading)
						}
						.accessibilityFocused($pickerFocused)
					}
				}
				if let settings = effects.loudness {
					let loudness = effectBinding(\.loudness, current: settings)
					Section {
						slider("Playback Level", value: loudness.target, range: -30 ... -10, step: 1,
							reading: number(loudness.wrappedValue.target) + " loudness units")
						slider("Peak Limit", value: loudness.peak, range: -9 ... -1, step: 0.1,
							reading: number(loudness.wrappedValue.peak) + " decibels")
						Button("Remove Match Loudness", role: .destructive) { effects.loudness = nil }
					} header: { Text("Match Loudness").accessibilityAddTraits(.isHeader) }
				}
				if let settings = effects.smoothing {
					let smoothing = effectBinding(\.smoothing, current: settings)
					Section {
						slider("Start Smoothing Above", value: smoothing.threshold, range: -40 ... 0, step: 1,
							reading: number(smoothing.wrappedValue.threshold) + " decibels")
						slider("Smoothing Strength", value: smoothing.ratio, range: 1...10, step: 1,
							reading: number(smoothing.wrappedValue.ratio) + " to 1")
						Button("Remove Even Out Volume", role: .destructive) { effects.smoothing = nil }
					} header: { Text("Even Out Volume").accessibilityAddTraits(.isHeader) }
				}
			}
			.editorListMargins()
			.accessibilityHidden(busy)
			.disabled(busy)
			.overlay {
				if busy { LoadingStatusView(measuring ? "Measuring Loudness" : "Loading Track Preview", cancel: { dismiss() }) }
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .principal) { Text(track.title).accessibilityAddTraits(.isHeader) }
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") {
						do { preview.pause(); try save(Float(volume), effects) }
						catch { self.error = error.localizedDescription }
					}.disabled(busy)
				}
			}
			.toolbar(busy ? .hidden : .visible, for: .navigationBar)
		}
		.editorAppearance()
		.accessibilityAction(.magicTap) { if !busy { preview.toggle() } }
		.task {
			preview.playhead.position = start
			await preview.prepare(audition, audition: track)
		}
		.task(id: measuring) {
			guard measuring else { return }
			do {
				try await preview.measureAudition(audition, channel: track.id)
				try Task.checkCancellation()
				measuring = false
				updatePreview()
				pickerFocused = true
			} catch {
				guard !Task.isCancelled else { return }
				effects.loudness = nil
				measuring = false
				self.error = "Could not measure the audio. Reconnect the clip in Project Media."
			}
		}
		.onChange(of: preview.ready) { if preview.ready { updatePreview() } }
		.onChange(of: preview.failure) { error = preview.failure }
		.onChange(of: volume) { updatePreview() }
		.onChange(of: effects) { updatePreview() }
		.onChange(of: bypass) { updatePreview() }
		.onChange(of: phase) { if phase != .active { preview.pause() } }
		.onDisappear { preview.cancelPreparation(); preview.pause() }
		.alert(track.title, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button("OK") { error = nil }
		} message: { Text(error ?? "") }
	}

	private func effectBinding<T>(_ key: WritableKeyPath<TrackAudioEffects, T?>, current: T) -> Binding<T> {
		// SwiftUI can read a slider during its section's removal animation.
		Binding(get: { effects[keyPath: key] ?? current }, set: { value in
			if effects[keyPath: key] != nil { effects[keyPath: key] = value }
		})
	}

	private var busy: Bool { preview.preparing || measuring }
	private var hasPreviewEffects: Bool {
		if track.kind == .audio { return effects != TrackAudioEffects() }
		return audition.audioPartner(for: track.id).flatMap { audition.trackEffects?[$0.id] } != nil
	}

	private func updatePreview() {
		guard preview.ready, !measuring else { return }
		var draft = audition
		var levels = draft.trackVolumes ?? [:]
		levels[track.id] = Float(volume)
		draft.trackVolumes = levels
		var settings = draft.trackEffects ?? [:]
		if track.kind == .audio { settings[track.id] = bypass ? nil : effects }
		else if bypass, let audio = draft.audioPartner(for: track.id) { settings[audio.id] = nil }
		draft.trackEffects = settings
		preview.updateMix(draft, solo: [], preview: true)
	}

	private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }

	private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, reading: String) -> some View {
		VStack(spacing: 0) {
			LabeledContent(label, value: reading).accessibilityHidden(true)
			Slider(value: value, in: range, step: step) { Text(label) }
				.frame(minHeight: 48)
				.accessibilityValue(reading)
		}
	}
}

struct ProjectJumpSheet: View {
	let format: TimecodeFormat
	let frame: CMTime
	let moving: Bool
	let initial: String
	let seek: (CMTime) throws -> Void
	init(format: TimecodeFormat, frame: CMTime, moving: Bool = false, initial: String = "", seek: @escaping (CMTime) throws -> Void) {
		self.format = format
		self.frame = frame
		self.moving = moving
		self.initial = initial
		self.seek = seek
		_text = State(initialValue: initial)
	}
	private var title: String { moving ? "Move to Time" : "Jump to Time" }
	@Environment(\.dismiss) private var dismiss
	@FocusState private var typing: Bool
	@State private var text = ""
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				TextField("", text: $text)
					.focused($typing)
					.autocorrectionDisabled()
					.onSubmit(jump)
					.editorFieldLabel(moving ? (format == .frames ? "Start Frame" : "Start Time") : (format == .frames ? "Frame" : "Time"))
			}
			.editorListMargins()
			.dismissKeyboardToolbar(while: typing) { typing = false }
			.navigationTitle(title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .principal) { Text(title).font(.headline).accessibilityAddTraits(.isHeader) }
				ToolbarItem(placement: .confirmationAction) { Button(moving ? "Move" : "Jump", action: jump) }
			}
		}
		.editorAppearance()
		.alert(title, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button("OK") { typing = true }
		} message: { Text(error ?? "") }
		.task { typing = true }
	}

	private func jump() {
		do {
			if moving && text == initial { dismiss(); return }
			if format == .frames, let index = Int32(text), index >= 0 {
				try seek(CMTimeMultiply(frame, multiplier: index))
			} else if format != .frames, let time = CuttingBoardSession.parse(text) {
				try seek(time)
			} else { throw ProjectFailure(moving ? "Enter a valid clip start and choose Move." : "Enter a valid playhead position and choose Jump.") }
			dismiss()
		} catch { self.error = error.localizedDescription }
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
					if method == "New Track" { TextField("", text: $name).focused($namingTrack).editorFieldLabel("Track Name") }
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
	let didSave: () -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var destination: Destination?
	@State private var output: ExportFile?
	@State private var failure: String?
	@State private var savingToPhotos = false
	@State private var burnInCaptions = false
	@State private var allowStereo = false
	@State private var pendingDestination: Destination?
	@State private var stereoConfirmation = false
	private enum Destination { case files, photos }

	var body: some View {
		NavigationStack {
			List {
				if destination != nil {
					ProgressView("Exporting")
				} else {
					if timeline.hasVideo && !timeline.captions.isEmpty {
						Toggle("Burn In Open Captions", isOn: $burnInCaptions)
					}
					if timeline.hasVideo { Button("Photos") { request(.photos) } }
					Button("Files") { request(.files) }
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
		.confirmationDialog("Export in Stereo?", isPresented: $stereoConfirmation, titleVisibility: .visible, presenting: pendingDestination) { selected in
			Button("Export in Stereo") { allowStereo = true; destination = selected }
			Button("Cancel", role: .cancel) { pendingDestination = nil }
		} message: { _ in
			Text("This export will convert spatial or multichannel audio to stereo.")
		}
		.editorAppearance()
		.interactiveDismissDisabled(savingToPhotos)
		.sheet(item: $output, onDismiss: { dismiss() }) { file in
			FileSavePicker(file: file.url) { saved in
				if saved { didSave() }
				output = nil
			}
		}
		.task(id: destination) {
			guard let destination else { return }
			var stage = "access Photos"
			do {
				if destination == .photos {
					let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
					guard status == .authorized || status == .limited else {
						throw ProjectFailure("Allow Photos access in Settings or choose Files.")
					}
				}
				try Task.checkCancellation()
				stage = burnInCaptions ? "render the video with open captions" : "render the project"
				let file = try await timeline.render(burnInCaptions: burnInCaptions, allowStereo: allowStereo)
				if destination == .files {
					output = file
				} else {
					stage = "save the export to Photos"
					savingToPhotos = true
					defer { savingToPhotos = false }
					try await PHPhotoLibrary.shared().performChanges {
						let options = PHAssetResourceCreationOptions()
						options.originalFilename = file.url.lastPathComponent
						PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file.url, options: options)
					}
					didSave()
					dismiss()
				}
			} catch {
				guard !Task.isCancelled else { return }
				failure = Self.failureMessage(error, stage: stage)
				self.destination = nil
			}
		}
		.alert("Could Not Export Project", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("OK") { failure = nil }
		} message: { Text(failure ?? "") }
	}

	private func request(_ selected: Destination) {
		if timeline.needsStereoConfirmation {
			pendingDestination = selected
			stereoConfirmation = true
		} else { destination = selected }
	}

	private static func failureMessage(_ error: Error, stage: String) -> String {
		if let error = error as? MediaExportFailure { return error.localizedDescription }
		var chain = [NSError]()
		var next: NSError? = error as NSError
		while let current = next, !chain.contains(where: { $0 === current }) {
			chain.append(current)
			next = current.userInfo[NSUnderlyingErrorKey] as? NSError
		}
		let codes = chain.map { "\($0.domain) \($0.code)" }.joined(separator: ", ")
		Logger(subsystem: "com.marconius.trimato-ios", category: "Export").error("Could not \(stage, privacy: .public): \(codes, privacy: .public)")
		if let failure = error as? ProjectFailure { return failure.message }
		if chain.contains(where: {
			switch ($0.domain, $0.code) {
			case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError), (NSPOSIXErrorDomain, Int(ENOSPC)),
				(AVFoundationErrorDomain, AVError.Code.diskFull.rawValue), (PHPhotosErrorDomain, PHPhotosError.Code.notEnoughSpace.rawValue):
				return true
			default: return false
			}
		}) {
			return "Could not " + stage + ". Free up storage and try again."
		}
		let reason = chain.compactMap(\.localizedFailureReason).first ?? error.localizedDescription
		return "Could not " + stage + ". " + reason + " (" + codes + ")"
	}
}

struct ProjectTimelineSlider: View {
	@ObservedObject var playhead: ProjectPlayhead
	let playback: ProjectPlayback
	let duration: CMTime
	let points: [CMTime]
	let frame: CMTime
	let format: TimecodeFormat
	let formatTime: (CMTime) -> String

	var body: some View {
		VStack(spacing: 0) {
			Text("Playhead, " + formatTime(playhead.position))
				.monospacedDigit()
				.accessibilityHidden(true)
			ProjectSliderControl(playback: playback, position: playhead.position, duration: duration, points: points,
				frame: frame, format: format, formatTime: formatTime)
				.frame(minHeight: 44)
		}
	}
}

private struct ProjectSliderControl: UIViewRepresentable {
	let playback: ProjectPlayback
	let position: CMTime
	let duration: CMTime
	let points: [CMTime]
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
		if slider.control?.points != points || slider.control?.duration != duration { slider.invalidateMarks() }
		slider.control = self
		slider.isEnabled = context.environment.isEnabled
		slider.display(position)
	}

	static func dismantleUIView(_ slider: TimelineSlider, coordinator: ()) {
		slider.finishDrag(announce: false)
	}

	final class TimelineSlider: UISlider {
		var control: ProjectSliderControl?
		private let marks = CAShapeLayer()
		private var markBounds: CGRect?
		func invalidateMarks() {
			markBounds = nil
			setNeedsLayout()
		}
		override func layoutSubviews() {
			super.layoutSubviews()
			marks.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
			guard markBounds != bounds else { return }
			markBounds = bounds
			guard let control, control.duration > .zero, !control.points.isEmpty else { marks.path = nil; return }
			if marks.superlayer == nil { layer.addSublayer(marks) }
			let track = trackRect(forBounds: bounds)
			let left = thumbRect(forBounds: bounds, trackRect: track, value: minimumValue).midX
			let right = thumbRect(forBounds: bounds, trackRect: track, value: maximumValue).midX
			let path = UIBezierPath()
			for point in control.points {
				let x = left + (right - left) * CGFloat(point.seconds / control.duration.seconds)
				path.move(to: CGPoint(x: x, y: track.maxY + 2))
				path.addLine(to: CGPoint(x: x, y: track.maxY + 7))
			}
			marks.lineWidth = 1.5
			marks.path = path.cgPath
		}
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

struct ProjectTouchSurface: UIViewRepresentable {
	@ObservedObject var playhead: ProjectPlayhead
	let playback: ProjectPlayback
	let formatTime: (CMTime) -> String
	let transitions: (() -> Void)?
	let duration: CMTime
	let captioning: Bool
	let editDescription: (() -> Void)?
	let trackName: String
	let mode: DirectTouchScrubbing
	let close: () -> Void
	let swipe: (Int, UISwipeGestureRecognizer.Direction) -> Void
	var clipEditing = false

	func makeUIView(context: Context) -> Surface {
		let view = Surface()
		view.isAccessibilityElement = true
		view.accessibilityLabel = "Direct Touch Editor"
		view.accessibilityTraits = .allowsDirectInteraction
		view.installTimelineGestures(projectTimeline: !clipEditing, captioning: captioning, transitions: transitions != nil, join: editDescription == nil ? nil : #selector(Surface.descriptionTap))
		view.backgroundColor = UIColor(EditorTheme.surface)
		configureProjectPreview(view.video)
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

		@objc func openTransitions() { control?.transitions?() }

		@objc func announcePosition() {
			guard let control else { return }
			UIAccessibility.post(notification: .announcement, argument: control.formatTime(control.playback.position))
		}

		@objc func descriptionTap() { control?.editDescription?() }
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
