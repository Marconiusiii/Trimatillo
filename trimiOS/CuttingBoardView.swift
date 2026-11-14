import AVFoundation
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

enum BoardSheet: Identifiable, Hashable {
	case jump
	case join(Int)
	var id: Self { self }
}

extension CuttingBoardSession {
	var positionLabel: String {
		let name: String?
		if position == .zero { name = "Start" }
		else if position == duration { name = "End" }
		else { name = currentJoin?.name }
		return [name, Self.timecode(position)].compactMap { $0 }.joined(separator: ", ")
	}

	func showJoin() {
		if let point = currentJoin { stop(); sheet = .join(point.index) }
	}
}

struct CuttingBoardView: View {
	@ObservedObject var session: CuttingBoardSession
	@State private var increment = 1
	@State private var directTouch = false
	@State private var preparing = false
	@State private var saving = false
	@State private var output: BoardExport?
	@State private var sheetFromMenu = false

	var body: some View {
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
		.background(EditorTheme.workspace)
		.tint(EditorTheme.accent)
		.alert("Cutting Board", isPresented: Binding(get: { session.message != nil && session.sheet == nil }, set: { if !$0 { session.message = nil } })) {
			Button("OK") { session.message = nil }
		} message: { Text(session.message ?? "") }
	}

	private var timeline: some View {
		VStack(spacing: 0) {
			Toggle("Use Direct Touch", isOn: $directTouch)
				.padding(.horizontal)
				.frame(minHeight: 44)
			CuttingBoardTouchSurface(session: session, enabled: directTouch)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			transport
		}
	}

	private var transport: some View {
		HStack(spacing: 0) {
			transportButton("Rewind", "backward.fill") { session.shuttle(-1) }
			transportButton(session.rate == 0 ? "Play" : "Pause", session.rate == 0 ? "play.fill" : "pause.fill") { session.toggle() }
			transportButton("Fast Forward", "forward.fill") { session.shuttle(1) }
		}
		.background(EditorTheme.surface)
	}

	private func transportButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Label { Text(title) } icon: { Image(systemName: symbol) }
				.labelStyle(.iconOnly)
				.accessibilityValue(symbol == "pause.fill" ? (session.rate < 0 ? "Reverse, \(-session.rate)×" : "Forward, \(session.rate)×") : "")
				.frame(maxWidth: .infinity, minHeight: 48)
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
				cell("Playhead, " + session.positionLabel)
			}
			.accessibilityActions { editActions(fromMenu: false) }
			.sheet(item: sheetBinding(forMenu: false)) { editorSheet($0) }
			Menu {
				Picker("Step by", selection: $increment) {
					Text(stepUnit(1)).tag(1)
					Text(stepUnit(10)).tag(10)
					Text("Edit point").tag(0)
				}
				.pickerStyle(.inline)
			} label: { cell("Step by, " + stepUnit(increment)) }
			HStack(spacing: 0) {
				Button { move(false) } label: { cell(stepLabel(false)) }
				Button { move(true) } label: { cell(stepLabel(true)) }
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
					guard !preparing && output == nil else { return }
					session.stop()
					preparing = true
				} label: { cell(preparing ? "Exporting…" : "Export") }
				.task(id: preparing) {
					guard preparing else { return }
					do {
						let file = try await session.exportClip()
						output = BoardExport(url: file)
						saving = true
					} catch {
						if !Task.isCancelled { session.message = "Could not export the clip. Check available storage and try Export again." }
					}
					preparing = false
				}
				.fileExporter(isPresented: $saving, item: output, contentTypes: output.map { [$0.type] } ?? [],
					defaultFilename: output?.url.lastPathComponent) { result in
					if case .failure = result { session.message = "Could not save the clip. Choose Export and select another destination." }
					output = nil
				} onCancellation: { output = nil }
			}
		}
		.buttonStyle(.plain)
		.foregroundStyle(EditorTheme.accent)
		.background(EditorTheme.surface)
	}

	private func editorSheet(_ sheet: BoardSheet) -> some View {
		BoardEditSheet(session: session, sheet: sheet)
			.accessibilityAction(.magicTap) { session.toggle() }
	}

	private func sheetBinding(forMenu menu: Bool) -> Binding<BoardSheet?> {
		Binding(get: { menu == sheetFromMenu ? session.sheet : nil }, set: { value in
			if menu == sheetFromMenu { session.sheet = value }
		})
	}

	private func cell(_ title: String) -> some View {
		Text(title)
			.multilineTextAlignment(.center)
			.frame(maxWidth: .infinity, minHeight: 48, maxHeight: .infinity)
			.contentShape(Rectangle())
	}

	private func stepUnit(_ amount: Int) -> String {
		if amount == 0 { return "Edit point" }
		if session.hasVideo { return amount == 1 ? "one frame" : "ten frames" }
		return amount == 1 ? "one thirtieth of a second" : "one third of a second"
	}

	private func stepLabel(_ forward: Bool) -> String {
		if increment == 0 { return forward ? "Next edit point" : "Previous edit point" }
		return (forward ? "Forward " : "Back ") + stepUnit(increment)
	}

	private func move(_ forward: Bool) {
		if increment == 0 { session.navigate(forward) }
		else { session.step(forward ? increment : -increment) }
	}

	private func markButton(_ isIn: Bool) -> some View {
		let time = isIn ? session.state.markIn : session.state.markOut
		let name = isIn ? "In" : "Out"
		return Button { session.mark(isIn) } label: {
			cell("Mark " + name + (time.map { ", " + CuttingBoardSession.timecode($0) } ?? ""))
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

	var body: some View {
		NavigationStack {
			Form {
				if let point {
					Picker("Boundary", selection: $preceding) {
						Text("End of preceding section").tag(true)
						Text("Start of following section").tag(false)
					}
					Stepper("Boundary, " + CuttingBoardSession.timecode(boundary),
						onIncrement: { adjust(by: 1) }, onDecrement: { adjust(by: -1) })
					Button("Play Across Edit") { session.playAcross(point.time) }
				}
				TextField(point == nil ? "Playhead time" : "Source time", text: $entry)
					.autocorrectionDisabled()
					.onSubmit { submit() }
				Button(point == nil ? "Jump" : "Set Boundary") { submit() }
				if let text = error ?? session.message { Text(text) }
			}
			.navigationTitle(point?.name ?? "Jump to Time")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { Button("Done") { dismiss() } }
		}
		.onAppear { entry = CuttingBoardSession.timecode(boundary) }
		.onChange(of: preceding) { _, _ in refresh() }
		.onDisappear { session.message = nil }
	}

	private func refresh() {
		error = nil
		entry = CuttingBoardSession.timecode(boundary)
	}

	private func adjust(by count: Int) {
		guard let point else { return }
		session.message = nil
		session.adjust(point.index, preceding: preceding, to: session.stepped(from: boundary, by: count, sourceTime: true), audible: true)
		refresh()
	}

	private func submit() {
		guard let time = CuttingBoardSession.parse(entry) else {
			error = "Enter seconds or hours:minutes:seconds."; return
		}
		if let point {
			session.message = nil
			if entry != CuttingBoardSession.timecode(boundary) {
				session.adjust(point.index, preceding: preceding, to: time, audible: true)
			}
			refresh()
		} else if time <= session.duration {
			session.seek(time)
			dismiss()
		} else { error = "Enter a time from zero through " + CuttingBoardSession.timecode(session.duration) + "." }
	}
}

private nonisolated final class BoardExport: Transferable, Sendable {
	let url: URL
	var type: UTType {
		switch url.pathExtension {
		case "mp4": .mpeg4Movie
		case "mov": .quickTimeMovie
		default: .mpeg4Audio
		}
	}

	init(url: URL) { self.url = url }

	static var transferRepresentation: some TransferRepresentation {
		FileRepresentation(exportedContentType: .mpeg4Movie) { SentTransferredFile($0.url) }
			.exportingCondition { $0.type == .mpeg4Movie }
		FileRepresentation(exportedContentType: .quickTimeMovie) { SentTransferredFile($0.url) }
			.exportingCondition { $0.type == .quickTimeMovie }
		FileRepresentation(exportedContentType: .mpeg4Audio) { SentTransferredFile($0.url) }
			.exportingCondition { $0.type == .mpeg4Audio }
	}

	deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct ClipInfoView: View {
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
		.tint(EditorTheme.accent)
		.accessibilityAction(.magicTap) { session.toggle() }
		.task { sections = await session.clipInfo() }
	}
}
