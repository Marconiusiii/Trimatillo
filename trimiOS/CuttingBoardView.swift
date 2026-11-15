import AVFoundation
import AVKit
import SwiftUI
import UIKit

enum BoardSheet: Identifiable, Hashable {
	case jump
	case join(Int)
	var id: Self { self }
}

extension CuttingBoardSession {
	func positionLabel(format: TimecodeFormat) -> String {
		let name: String?
		if position == .zero { name = "Start" }
		else if position == duration { name = "End" }
		else { name = currentJoin?.name }
		return [name, timecode(position, format: format)].compactMap { $0 }.joined(separator: ", ")
	}

	func showJoin() {
		if let point = currentJoin { stop(); sheet = .join(point.index) }
	}
}

struct BoardProjectActions {
	let append: () -> Void
	let split: () -> Void
	let overwrite: () -> Void
	let update: (() -> Void)?
	let placementSheet: () -> AnyView
}

struct CuttingBoardView: View {
	var projectActions: BoardProjectActions?
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@ObservedObject var session: CuttingBoardSession
	var closeDirectTouchEditor: (() -> Void)?
	@State private var showingDirectTouchEditor = false
	@AccessibilityFocusState(for: .voiceOver) private var launcherFocused: Bool
	@AccessibilityFocusState(for: .voiceOver) private var surfaceFocused: Bool
	@State private var preview: PreviewPlayback?
	@AccessibilityFocusState private var previewFocused: Bool
	@State private var exporting = false
	@AccessibilityFocusState(for: .voiceOver) private var exportFocused: Bool
	@AccessibilityFocusState private var placementFocused: Bool
	@State private var sheetFromMenu = false

	var body: some View {
		Group {
			if let closeDirectTouchEditor {
				VStack(spacing: 0) {
					HStack(spacing: 0) {
						Button(action: closeDirectTouchEditor) {
							Text("Close").padding(.horizontal).frame(minHeight: 48)
						}
						Text("Direct Touch Editor")
							.font(.headline)
							.frame(maxWidth: .infinity, minHeight: 48)
							.accessibilityAddTraits(.isHeader)
					}
					CuttingBoardTouchSurface(session: session, onClose: closeDirectTouchEditor, projectActions: projectActions)
						.accessibilityFocused($surfaceFocused)
				}
				.accessibilityAction(.magicTap) { session.toggle() }
				.sheet(item: $session.sheet, onDismiss: { surfaceFocused = true }) { editorSheet($0) }
			} else {
				board
					.fullScreenCover(item: $preview, onDismiss: { previewFocused = true }) { playback in
						FullScreenPreview(playback: playback)
					}
					.sheet(isPresented: $exporting, onDismiss: { exportFocused = true }) {
						ClipExportView(session: session)
					}
					.fullScreenCover(isPresented: $showingDirectTouchEditor, onDismiss: { launcherFocused = true }) {
						CuttingBoardView(projectActions: projectActions, session: session, closeDirectTouchEditor: { showingDirectTouchEditor = false })
					}
			}
		}
		.sheet(isPresented: Binding(get: { !showingDirectTouchEditor && session.choosingPlacement }, set: {
			if !showingDirectTouchEditor { session.choosingPlacement = $0 }
		}), onDismiss: {
			if closeDirectTouchEditor == nil { placementFocused = true } else { surfaceFocused = true }
		}) { projectActions?.placementSheet() }
		.background(EditorTheme.workspace)
		.alert("Cutting Board", isPresented: Binding(get: { !showingDirectTouchEditor && session.message != nil && session.sheet == nil }, set: { if !$0 { session.message = nil } })) {
			Button("OK") { session.message = nil }
		} message: { Text(session.message ?? "") }
	}

	private var board: some View {
		GeometryReader { geometry in
			let wide = geometry.size.width > geometry.size.height && geometry.size.width > 550
			let portraitVideo = (session.videoAspect ?? 1) < 1
			if wide {
				HStack(spacing: 0) {
					timeline
					ViewThatFits(in: .vertical) {
						controls
						ScrollView { controls }
					}
					.frame(width: geometry.size.width * (portraitVideo ? 0.60 : 0.49))
				}
			} else {
				ViewThatFits(in: .vertical) {
					VStack(spacing: 0) {
						timeline.frame(minHeight: portraitVideo ? max(180, geometry.size.height * 0.45) : 180)
						controls.fixedSize(horizontal: false, vertical: true)
					}
					VStack(spacing: 0) {
						timeline.frame(height: geometry.size.height * (portraitVideo ? 0.55 : 0.45))
						ScrollView { controls }
					}
				}
			}
		}
	}

	private var timeline: some View {
		VStack(spacing: 0) {
			Button { showingDirectTouchEditor = true } label: {
				Text("Direct Touch Editor")
					.frame(maxWidth: .infinity, minHeight: 48)
					.contentShape(Rectangle())
			}
			.accessibilityFocused($launcherFocused)
			if showingDirectTouchEditor {
				EditorTheme.surface
			} else {
				CuttingBoardTouchSurface(session: session, onClose: nil)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			transport
		}
	}

	private var transport: some View {
		HStack(spacing: 0) {
			transportButton("Rewind", "backward.fill", showsSpeed: session.rate < 0) { session.shuttle(-1) }
			transportButton(session.rate == 0 ? "Play" : "Pause", session.rate == 0 ? "play.fill" : "pause.fill") { session.toggle() }
			transportButton("Fast Forward", "forward.fill", showsSpeed: session.rate > 0) { session.shuttle(1) }
			if session.hasVideo {
				transportButton("Full Screen Preview", "arrow.up.left.and.arrow.down.right") {
					preview = session.makePreview()
				}
				.accessibilityFocused($previewFocused)
			}
		}
		.background(EditorTheme.surface)
	}

	private func transportButton(_ title: String, _ symbol: String, showsSpeed: Bool = false, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Label { Text(title) } icon: { Image(systemName: symbol) }
				.labelStyle(.iconOnly)
				.accessibilityValue(symbol == "pause.fill" ? session.shuttleLabel : "")
				.frame(maxWidth: .infinity, minHeight: 48)
				.overlay(alignment: .topTrailing) {
					if showsSpeed {
						Text(session.speedLabel)
							.font(.caption.weight(.semibold))
							.foregroundStyle(EditorTheme.surface)
							.padding(.horizontal, 5)
							.background(color.accent, in: Capsule())
							.padding(2)
							.accessibilityHidden(true)
							.allowsHitTesting(false)
					}
				}
				.contentShape(Rectangle())
		}
	}

	private var controls: some View {
		VStack(spacing: 0) {
			Button {
				sheetFromMenu = false
				session.stop()
				session.sheet = .jump
			} label: {
				cell("Playhead, " + session.positionLabel(format: format))
			}
			.accessibilityActions { editActions(fromMenu: false) }
			.sheet(item: sheetBinding(forMenu: false)) { editorSheet($0) }
			HStack(spacing: 0) {
				stepButton(forward: false)
				stepButton(forward: true)
			}
			HStack(spacing: 0) {
				markButton(true)
				markButton(false)
			}
			HStack(spacing: 0) {
				Menu { editActions(fromMenu: true) } label: { cell("Edit Actions") }
					.sheet(item: sheetBinding(forMenu: true)) { editorSheet($0) }
				Button { session.undo() } label: { cell("Undo") }
					.accessibilityActions {
						if session.canRedo { Button("Redo") { session.redo() } }
					}
					.disabled(!session.canUndo && !session.canRedo)
				if let projectActions {
					Button(action: projectActions.append) { cell("Append") }
					Button { session.stop(); session.choosingPlacement = true } label: { cell("Add at Playhead") }
						.accessibilityFocused($placementFocused)
					if let update = projectActions.update { Button(action: update) { cell("Save Changes") } }
				} else {
					Button {
						session.releaseAudio()
						exporting = true
					} label: { cell("Export") }
					.accessibilityFocused($exportFocused)
				}
			}
		}
		.buttonStyle(.plain)
		.foregroundStyle(color.accent)
		.background(EditorTheme.surface)
	}

	@ViewBuilder private func editorSheet(_ sheet: BoardSheet) -> some View {
		switch sheet {
		case .jump:
			JumpSheet(session: session)
				.accessibilityAction(.magicTap) { session.toggle() }
		case let .join(index):
			if let point = session.state.timeline.editPoints.first(where: { $0.index == index }) {
				JoinSheet(session: session, point: point)
			}
		}
	}

	private func sheetBinding(forMenu menu: Bool) -> Binding<BoardSheet?> {
		Binding(get: { !showingDirectTouchEditor && menu == sheetFromMenu ? session.sheet : nil }, set: { value in
			if menu == sheetFromMenu { session.sheet = value }
		})
	}

	private func cell(_ title: String) -> some View {
		Text(title)
			.multilineTextAlignment(.center)
			.frame(maxWidth: .infinity, minHeight: 48, maxHeight: .infinity)
			.contentShape(Rectangle())
	}

	private func stepButton(forward: Bool) -> some View {
		let direction = forward ? "Step Forward " : "Step Back "
		let single = session.hasVideo ? "One Frame" : "One Thirtieth of a Second"
		let ten = session.hasVideo ? "10 Frames" : "One Third of a Second"
		return Button { session.step(forward ? 1 : -1) } label: {
			cell(direction + single)
		}
		.accessibilityActions {
			Button(direction + ten) { session.step(forward ? 10 : -10) }
			Button(forward ? "Next Edit Point" : "Previous Edit Point") {
				session.navigate(forward, spoken: true)
			}
		}
	}

	private func markButton(_ isIn: Bool) -> some View {
		let time = isIn ? session.state.markIn : session.state.markOut
		let name = isIn ? "In" : "Out"
		return Button { session.mark(isIn) } label: {
			cell("Mark " + name + (time.map { ", " + session.timecode($0, format: format) } ?? ""))
		}
			.accessibilityActions {
				if let time {
					Button("Go to " + name) { session.seek(time) }
					Button("Clear " + name) { session.clear(isIn) }
				}
			}
	}

	@ViewBuilder private func editActions(fromMenu: Bool) -> some View {
		Button("Mark In Here") { session.mark(true) }
		Button("Mark Out Here") { session.mark(false) }
		if session.state.markIn != nil { Button("Clear In") { session.clear(true) } }
		if session.state.markOut != nil { Button("Clear Out") { session.clear(false) } }
		if let range = session.selection {
			Button("Play Marked Range") { session.playMarked() }
			if range.duration < session.duration {
				Button("Delete Marked Range") { session.delete(range) }
			}
		}
		if session.currentJoin != nil {
			Button("Adjust Edit Point") { sheetFromMenu = fromMenu; session.showJoin() }
		}
		Button("Previous Edit Point") { session.navigate(false) }
		Button("Next Edit Point") { session.navigate(true) }
		if session.position > .zero && session.position < session.duration {
			Button("Trim Head to Playhead") { session.trim(head: true) }
			Button("Trim Tail to Playhead") { session.trim(head: false) }
		}
	}
}

private struct TimeEntry {
	var exact: CMTime
	var text: String

	init(_ time: CMTime, session: CuttingBoardSession, format: TimecodeFormat, source: Bool) {
		exact = time
		text = format == .frames ? String(session.frameNumber(at: time, sourceTime: source)) : session.timecode(time, format: format)
	}

	func value(session: CuttingBoardSession, format: TimecodeFormat, source: Bool) -> CMTime? {
		if text == TimeEntry(exact, session: session, format: format, source: source).text { return exact }
		if format == .frames { return Int64(text).flatMap { session.time(atFrame: $0, sourceTime: source) } }
		return CuttingBoardSession.parse(text)
	}
}

private struct JumpSheet: View {
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@ObservedObject var session: CuttingBoardSession
	@Environment(\.dismiss) private var dismiss
	@State private var entry: TimeEntry?
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				if let binding = Binding($entry) {
					TextField(format == .frames ? "Playhead frame" : "Playhead time", text: binding.text)
						.autocorrectionDisabled()
						.onSubmit { jump() }
				}
				Button("Jump") { jump() }
				if let error { Text(error) }
			}
			.navigationTitle("Jump to Time")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
			}
		}
		.onAppear { entry = TimeEntry(session.position, session: session, format: format, source: false) }
	}

	private func jump() {
		guard let time = entry?.value(session: session, format: format, source: false), time <= session.duration else {
			error = "Enter a position from zero through " + session.timecode(session.duration, format: format) + "."
			return
		}
		session.seek(time)
		dismiss()
	}
}

private struct JoinSheet: View {
	@ObservedObject var session: CuttingBoardSession
	let point: ClipEditTimeline.EditPoint
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@Environment(\.dismiss) private var dismiss
	@State private var precedingEntry: TimeEntry?
	@State private var followingEntry: TimeEntry?
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				if let preceding = Binding($precedingEntry), let following = Binding($followingEntry) {
					boundary("End of preceding section", entry: preceding, preceding: true)
					boundary("Start of following section", entry: following, preceding: false)
				}
				if let text = error ?? session.message { Text(text) }
			}
			.navigationTitle(point.name)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
			}
		}
		.onAppear {
			precedingEntry = TimeEntry(point.inTime, session: session, format: format, source: true)
			followingEntry = TimeEntry(point.outTime, session: session, format: format, source: true)
		}
		.onDisappear { session.stop(); session.message = nil }
	}

	private func boundary(_ title: String, entry: Binding<TimeEntry>, preceding: Bool) -> some View {
		Section {
			TextField(title + (format == .frames ? ", source frame" : ", source time"), text: entry.text)
				.autocorrectionDisabled()
			Stepper(title + ", " + entry.wrappedValue.text,
				onIncrement: { step(entry, by: 1, preceding: preceding) },
				onDecrement: { step(entry, by: -1, preceding: preceding) })
		} header: { Text(title).accessibilityAddTraits(.isHeader) }
	}

	private func step(_ entry: Binding<TimeEntry>, by count: Int, preceding: Bool) {
		guard let value = entry.wrappedValue.value(session: session, format: format, source: true) else {
			error = "Enter a valid source position."
			return
		}
		let next = session.stepped(from: value, by: count, sourceTime: true)
		guard next > point.precedingStart, next < point.followingEnd else { return }
		entry.wrappedValue = TimeEntry(next, session: session, format: format, source: true)
		error = nil
		session.previewBoundary(at: next, preceding: preceding)
	}

	private func save() {
		guard let inTime = precedingEntry?.value(session: session, format: format, source: true),
			let outTime = followingEntry?.value(session: session, format: format, source: true) else {
			error = "Enter a valid source position for each boundary."
			return
		}
		do {
			try session.saveJoin(point, inTime: inTime, outTime: outTime)
			dismiss()
		} catch ClipEditError.invalidSelection {
			error = "Choose positions inside the adjacent sections and place the first boundary before the second."
		} catch { self.error = error.localizedDescription }
	}
}

private struct ClipExportView: View {
	let session: CuttingBoardSession
	@Environment(\.dismiss) private var dismiss
	@State private var destination: Destination?
	@State private var output: ExportFile?
	@State private var failure: String?

	private enum Destination { case original, photos, files }

	var body: some View {
		NavigationStack {
			List {
				if destination != nil {
					ProgressView("Exporting")
				} else if Bundle.main.bundleURL.pathExtension == "appex" {
					Section("Save as New Clip") {
						Button("Photos") { destination = .photos }
						Button("Files") { destination = .files }
					}
				} else {
					Button("Save Changes to Original") { destination = .original }
						.disabled(!session.canSaveOriginal)
					if session.hasVideo {
						Menu("Save as New Clip") {
							Button("Photos") { destination = .photos }
							Button("Files") { destination = .files }
						}
					} else {
						Button("Save as New Clip") { destination = .files }
					}
				}
			}
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle("Export")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }.disabled(destination != nil)
				}
			}
		}
		.sheet(item: $output, onDismiss: { dismiss() }) { rendered in
			FileSavePicker(file: rendered.url) { output = nil }
		}
		.interactiveDismissDisabled(destination != nil)
		.task(id: destination) {
			guard let destination else { return }
			do {
				switch destination {
				case .original: try await session.saveOriginal()
				case .photos: try await session.saveNewVideo()
				case .files:
					output = ExportFile(url: try await session.exportClip())
					return
				}
				dismiss()
			} catch {
				guard !Task.isCancelled else { return }
				failure = (error as? CuttingBoardSession.SaveFailure)?.errorDescription ??
					"Could not save the clip. Check available storage or choose another destination."
				self.destination = nil
			}
		}
		.alert("Could Not Save Clip", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("OK") { failure = nil }
		} message: { Text(failure ?? "") }
	}
}

private final class ExportFile: Identifiable {
	let url: URL
	init(url: URL) { self.url = url }
	deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

private struct FileSavePicker: UIViewControllerRepresentable {
	let file: URL
	let finish: () -> Void

	func makeCoordinator() -> Coordinator { Coordinator(finish) }
	func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
		let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
		picker.delegate = context.coordinator
		return picker
	}
	func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

	final class Coordinator: NSObject, UIDocumentPickerDelegate {
		let finish: () -> Void
		init(_ finish: @escaping () -> Void) { self.finish = finish }
		func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish() }
		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish() }
	}
}

struct ClipInfoView: View {
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	let session: CuttingBoardSession
	@Environment(\.dismiss) private var dismiss
	@State private var sections: [ClipInfoSection] = []

	var body: some View {
		NavigationStack {
			List {
				if sections.isEmpty { ProgressView("Loading clip info") }
				ForEach(sections.indices, id: \.self) { index in
					let section = sections[index]
					Section {
						ForEach(section.rows.indices, id: \.self) { rowIndex in
							let row = section.rows[rowIndex]
							LabeledContent(row.key, value: row.value)
								.accessibilityElement(children: .combine)
						}
					} header: {
						Text(section.title).accessibilityAddTraits(.isHeader)
					}
					.listRowBackground(EditorTheme.surface)
				}
			}
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle("Clip Info")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
			}
		}
		.accessibilityAction(.magicTap) { session.toggle() }
		.task(id: format) { sections = await session.clipInfo(format: format) }
	}
}

struct PrimaryCuttingBoard: View {
	let session: CuttingBoardSession
	var projectActions: BoardProjectActions?
	let close: () -> Void
	@State private var confirmClose = false
	@State private var showingInfo = false

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 0) {
				Button {
					session.stop()
					if session.hasTimelineEdits { confirmClose = true } else { close() }
				} label: { Text("Close").padding(.horizontal).frame(minHeight: 48) }
				.accessibilityIdentifier("sharedBoardClose")
				.alert("Close this clip and discard unsaved edits?", isPresented: $confirmClose) {
					Button("Close Clip", role: .destructive, action: close)
					Button("Keep Editing", role: .cancel) {}
				}
				Text(session.hasVideo ? "Video Cutting Board" : "Audio Cutting Board")
					.font(.headline)
					.frame(maxWidth: .infinity, minHeight: 48)
					.accessibilityAddTraits(.isHeader)
				Button { session.stop(); showingInfo = true } label: {
					Text("Clip Info").padding(.horizontal).frame(minHeight: 48)
				}
				.sheet(isPresented: $showingInfo) { ClipInfoView(session: session) }
			}
			CuttingBoardView(projectActions: projectActions, session: session)
		}
		.editorAppearance()
		.onDisappear { session.releaseAudio() }
	}
}

// Both the app and the Photos share extension present this player.
@MainActor final class PreviewPlayback: Identifiable {
	let player: AVPlayer
	let start: CMTime
	private let openingRate: Float
	private var returnPosition: ((CMTime) -> Void)?
	private(set) var positioned = false

	init(item: AVPlayerItem, start: CMTime, rate: Float, returnPosition: @escaping (CMTime) -> Void) {
		let previewItem = AVPlayerItem(asset: item.asset)
		previewItem.videoComposition = item.videoComposition
		previewItem.audioMix = item.audioMix
		player = AVPlayer(playerItem: previewItem)
		self.start = start
		openingRate = rate
		self.returnPosition = returnPosition
	}

	func begin() async {
		guard !positioned, returnPosition != nil else { return }
		let finished = await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
		guard finished, !Task.isCancelled, returnPosition != nil else { return }
		positioned = true
		if openingRate > 0 { player.playImmediately(atRate: openingRate) }
	}

	func toggle() {
		guard positioned else { return }
		if player.timeControlStatus == .paused {
			if let end = player.currentItem?.duration, end.isNumeric, player.currentTime() >= end {
				player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
			}
			player.play()
		} else {
			player.pause()
		}
	}

	func finish() {
		guard let returnPosition else { return }
		self.returnPosition = nil
		player.pause()
		let time = player.currentTime()
		returnPosition(positioned && time.isNumeric ? time : start)
	}
}

struct FullScreenPreview: View {
	let playback: PreviewPlayback
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var phase
	@State private var ready = false
	@State private var failed = false

	var body: some View {
		NavigationStack {
			VideoPlayer(player: playback.player)
				.disabled(!ready)
				.navigationTitle("Full Screen Preview")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .topBarLeading) {
						Button("Close") {
							playback.finish()
							dismiss()
						}
					}
				}
		}
		.editorAppearance()
		.accessibilityAction(.magicTap) { playback.toggle() }
		.task {
			do {
				try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
			} catch {
				failed = true
				return
			}
			await playback.begin()
			guard !Task.isCancelled else { return }
			ready = playback.positioned
			failed = !ready
			if phase != .active { playback.player.pause() }
		}
		.onChange(of: phase) { _, value in
			if value == .background { playback.player.pause() }
		}
		.onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: playback.player.currentItem)) { _ in
			failed = true
		}
		.alert("Could Not Play Preview", isPresented: $failed) {
			Button("Close") {
				playback.finish()
				dismiss()
			}
		} message: {
			Text("Reopen Full Screen Preview to try again.")
		}
		.interactiveDismissDisabled()
	}
}
