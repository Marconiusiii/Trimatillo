import AVFoundation
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

struct CuttingBoardView: View {
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@ObservedObject var session: CuttingBoardSession
	var closeDirectTouchEditor: (() -> Void)?
	@State private var showingDirectTouchEditor = false
	@AccessibilityFocusState(for: .voiceOver) private var launcherFocused: Bool
	@State private var exporting = false
	@AccessibilityFocusState(for: .voiceOver) private var exportFocused: Bool
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
					CuttingBoardTouchSurface(session: session, onClose: closeDirectTouchEditor)
				}
				.accessibilityAction(.magicTap) { session.toggle() }
				.sheet(item: $session.sheet) { editorSheet($0) }
			} else {
				board
					.sheet(isPresented: $exporting, onDismiss: { exportFocused = true }) {
						ClipExportView(session: session)
					}
					.fullScreenCover(isPresented: $showingDirectTouchEditor, onDismiss: { launcherFocused = true }) {
						CuttingBoardView(session: session, closeDirectTouchEditor: { showingDirectTouchEditor = false })
					}
			}
		}
		.background(EditorTheme.workspace)
		.alert("Cutting Board", isPresented: Binding(get: { !showingDirectTouchEditor && session.message != nil && session.sheet == nil }, set: { if !$0 { session.message = nil } })) {
			Button("OK") { session.message = nil }
		} message: { Text(session.message ?? "") }
	}

	private var board: some View {
		GeometryReader { geometry in
			let wide = geometry.size.width > geometry.size.height && geometry.size.width > 550
			if wide {
				HStack(spacing: 0) {
					timeline
					ViewThatFits(in: .vertical) {
						controls
						ScrollView { controls }
					}
					.frame(width: geometry.size.width * 0.49)
				}
			} else {
				ViewThatFits(in: .vertical) {
					VStack(spacing: 0) {
						timeline.frame(minHeight: 180)
						controls.fixedSize(horizontal: false, vertical: true)
					}
					VStack(spacing: 0) {
						timeline.frame(height: geometry.size.height * 0.45)
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
				Button { session.undo() } label: { cell("Undo") }.disabled(!session.canUndo)
				Button {
					session.releaseAudio()
					exporting = true
				} label: { cell("Export") }
				.accessibilityFocused($exportFocused)
			}
		}
		.buttonStyle(.plain)
		.foregroundStyle(color.accent)
		.background(EditorTheme.surface)
	}

	private func editorSheet(_ sheet: BoardSheet) -> some View {
		BoardEditSheet(session: session, sheet: sheet)
			.accessibilityAction(.magicTap) { session.toggle() }
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
		if let point = session.currentJoin {
			Button("Play Across Edit") { session.playAcross(point.time) }
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

private struct BoardEditSheet: View {
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@ObservedObject var session: CuttingBoardSession
	let sheet: BoardSheet
	@Environment(\.dismiss) private var dismiss
	@State private var preceding = false
	@State private var entry = ""
	@State private var error: String?

	private var point: ClipEditTimeline.EditPoint? {
		guard case let .join(index) = sheet else { return nil }
		return session.state.timeline.editPoints.first { $0.index == index }
	}
	private var boundary: CMTime {
		guard let point else { return session.position }
		return preceding ? point.inTime : point.outTime
	}

	private var boundaryEntry: String {
		if format == .frames { return String(session.frameNumber(at: boundary, sourceTime: point != nil)) }
		return session.timecode(boundary, format: format)
	}

	var body: some View {
		NavigationStack {
			Form {
				if let point {
					Picker("Boundary", selection: $preceding) {
						Text("End of preceding section").tag(true)
						Text("Start of following section").tag(false)
					}
					Stepper("Boundary, " + session.timecode(boundary, format: format, sourceTime: true),
						onIncrement: { adjust(by: 1) }, onDecrement: { adjust(by: -1) })
					Button("Play Across Edit") { session.playAcross(point.time) }
				}
				TextField((point == nil ? "Playhead" : "Source") + (format == .frames ? " frame" : " time"), text: $entry)
					.autocorrectionDisabled()
					.onSubmit { submit() }
				Button(point == nil ? "Jump" : "Set Boundary") { submit() }
				if let text = error ?? session.message { Text(text) }
			}
			.navigationTitle(point?.name ?? "Jump to Time")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { Button("Done") { dismiss() } }
		}
		.onAppear { entry = boundaryEntry }
		.onChange(of: preceding) { _, _ in refresh() }
		.onDisappear { session.message = nil }
	}

	private func refresh() {
		error = nil
		entry = boundaryEntry
	}

	private func adjust(by count: Int) {
		guard let point else { return }
		session.message = nil
		session.adjust(point.index, preceding: preceding, to: session.stepped(from: boundary, by: count, sourceTime: true), audible: true)
		refresh()
	}

	private func submit() {
		let time: CMTime?
		if entry == boundaryEntry { time = boundary }
		else if format == .frames { time = Int64(entry).flatMap { session.time(atFrame: $0, sourceTime: point != nil) } }
		else { time = CuttingBoardSession.parse(entry) }
		guard let time else {
			error = format == .frames ? "Enter a frame number within the clip." : "Enter seconds or hours:minutes:seconds."
			return
		}
		if let point {
			session.message = nil
			if entry != boundaryEntry {
				session.adjust(point.index, preceding: preceding, to: time, audible: true)
			}
			refresh()
		} else if time <= session.duration {
			session.seek(time)
			dismiss()
		} else { error = "Enter a time from zero through " + session.timecode(session.duration, format: format) + "." }
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
			.toolbar { Button("Done") { dismiss() } }
		}
		.accessibilityAction(.magicTap) { session.toggle() }
		.task(id: format) { sections = await session.clipInfo(format: format) }
	}
}

struct PrimaryCuttingBoard: View {
	let session: CuttingBoardSession
	let close: () -> Void
	@State private var confirmClose = false
	@State private var showingInfo = false

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 0) {
				Button {
					session.stop()
					if session.canUndo { confirmClose = true } else { close() }
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
			CuttingBoardView(session: session)
		}
		.editorAppearance()
		.onDisappear { session.releaseAudio() }
	}
}
