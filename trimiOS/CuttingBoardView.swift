import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct EditorMenuAction: Identifiable {
	let title: String
	let perform: () -> Void
	var id: String { title }

	init(_ title: String, _ perform: @escaping () -> Void) {
		self.title = title
		self.perform = perform
	}

	static func buttons(_ actions: [Self]) -> some View {
		ForEach(actions) { action in
			Button(action.title, action: action.perform)
		}
	}
}

extension View {
	func editorMenuActions(_ label: String, _ actions: [EditorMenuAction]) -> some View {
		actions.reduce(accessibilityLabel(Text(label))) { control, action in
			control.accessibilityAction(named: Text(action.title), action.perform)
		}
	}
}

enum BoardSheet: Identifiable, Hashable {
	case jump
	case trimSilences
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
		guard let point = currentJoin else { return }
		#if DEBUG
		editPointTrace.begin()
		#endif
		stop()
		prepareBoundaryAudio()
		sheet = .join(point.index)
	}
}

struct BoardProjectActions {
	let append: () -> Void
	let split: () -> Void
	let overwrite: () -> Void
	let update: (() -> Void)?
	let placementSheet: (_ directTouch: Bool) -> AnyView
}

struct CuttingBoardView: View {
	var projectActions: BoardProjectActions?
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
	@AccessibilityFocusState private var playheadFocused: Bool
	@AccessibilityFocusState private var editActionsFocused: Bool
	@State private var sheetFromMenu = false

	var body: some View {
		Group {
			if let closeDirectTouchEditor {
				VStack(spacing: 0) {
					HStack(spacing: 0) {
						Button(action: closeDirectTouchEditor) {
							Text("Close").padding(.horizontal).frame(minHeight: 48).contentShape(Rectangle())
						}
						Text("Direct Touch Editor")
							.font(.headline)
							.frame(maxWidth: .infinity, minHeight: 48)
							.contentShape(Rectangle())
							.accessibilityAddTraits(.isHeader)
					}
					CuttingBoardTouchSurface(session: session, onClose: closeDirectTouchEditor, projectActions: projectActions)
						.accessibilityFocused($surfaceFocused)
				}
				.accessibilityAction(.magicTap) { session.toggle() }
				.sheet(item: $session.sheet, onDismiss: {
					#if DEBUG
					session.editPointTrace.event("Board sheet dismissed, requesting Direct Touch Editor focus")
					if session.sheet == nil { session.editPointTrace.end() }
					#endif
					surfaceFocused = true
				}) { editorSheet($0) }
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
		}) { projectActions?.placementSheet(closeDirectTouchEditor != nil) }
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
		.fixedSize(horizontal: false, vertical: true)
		.background(EditorTheme.surface)
	}

	private func transportButton(_ title: String, _ symbol: String, showsSpeed: Bool = false, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Label { Text(title) } icon: { Image(systemName: symbol) }
				.labelStyle(.iconOnly)
				.accessibilityValue(symbol == "pause.fill" ? session.shuttleLabel : "")
		}
		.buttonStyle(EditorButtonStyle(square: true, badge: showsSpeed ? session.speedLabel : nil))
	}

	private var controls: some View {
		VStack(spacing: 0) {
			Button {
				sheetFromMenu = false
				session.stop()
				session.sheet = .jump
			} label: {
				Text("Playhead, " + session.positionLabel(format: format))
			}
			.accessibilityActions { EditorMenuAction.buttons(editCommands(fromMenu: false)) }
			.accessibilityFocused($playheadFocused)
			.sheet(item: sheetBinding(forMenu: false), onDismiss: {
				#if DEBUG
				session.editPointTrace.event("Board sheet dismissed, requesting Playhead focus")
				if session.sheet == nil { session.editPointTrace.end() }
				#endif
				playheadFocused = true
			}) { editorSheet($0) }
			EditorCommandRow {
				stepButton(forward: false)
				stepButton(forward: true)
			}
			EditorCommandRow {
				markButton(true)
				markButton(false)
			}
			EditorCommandRow {
				let actions = editCommands(fromMenu: true)
				Menu { EditorMenuAction.buttons(actions) } label: { Text("Edit Actions") }
					.editorMenuActions("Edit Actions", actions)
					.accessibilityFocused($editActionsFocused)
					.sheet(item: sheetBinding(forMenu: true), onDismiss: {
						#if DEBUG
						session.editPointTrace.event("Board sheet dismissed, requesting Edit Actions focus")
						if session.sheet == nil { session.editPointTrace.end() }
						#endif
						editActionsFocused = true
					}) { editorSheet($0) }
				if !session.canUndo && session.canRedo {
					Menu { Button("Redo") { session.redo() } } label: { Text("Undo") }
						.accessibilityAction(named: "Redo") { session.redo() }
				} else {
					Button { session.undo() } label: { Text("Undo") }
						.accessibilityActions {
							if session.canRedo { Button("Redo") { session.redo() } }
						}
						.disabled(!session.canUndo)
				}
				if projectActions == nil {
					Button {
						session.releaseAudio()
						exporting = true
					} label: { Text("Export") }
					.accessibilityFocused($exportFocused)
				}
			}
			if let projectActions {
				ViewThatFits(in: .horizontal) {
					EditorCommandRow { placementControls(projectActions) }
					VStack(spacing: 0) { placementControls(projectActions) }
				}
			}
		}
		.buttonStyle(EditorButtonStyle())
		.background(EditorTheme.surface)
	}

	@ViewBuilder private func placementControls(_ projectActions: BoardProjectActions) -> some View {
		Button(action: projectActions.append) { Text("Append") }
		Button { session.stop(); session.choosingPlacement = true } label: { Text("Add at Playhead") }
			.accessibilityFocused($placementFocused)
		if let update = projectActions.update { Button(action: update) { Text("Save Changes") } }
	}

	@ViewBuilder private func editorSheet(_ sheet: BoardSheet) -> some View {
		switch sheet {
		case .trimSilences:
			TrimSilencesView(session: session)
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

	private func stepButton(forward: Bool) -> some View {
		let direction = forward ? "Step Forward " : "Step Back "
		let single = session.hasVideo ? "One Frame" : "One Thirtieth of a Second"
		let ten = session.hasVideo ? "10 Frames" : "One Third of a Second"
		return Button { session.step(forward ? 1 : -1) } label: {
			Text(direction + single)
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
			Text("Mark " + name + (time.map { ", " + session.timecode($0, format: format) } ?? ""))
		}
			.accessibilityActions {
				if let time {
					Button("Go to " + name) { session.seek(time) }
					Button("Clear " + name) { session.clear(isIn) }
				}
			}
	}

	private func editCommands(fromMenu: Bool) -> [EditorMenuAction] {
		var actions: [EditorMenuAction] = []
		if session.canRedo { actions.append(EditorMenuAction("Redo") { session.redo() }) }
		actions.append(EditorMenuAction("Mark In Here") { session.mark(true) })
		actions.append(EditorMenuAction("Mark Out Here") { session.mark(false) })
		if session.state.markIn != nil { actions.append(EditorMenuAction("Clear In") { session.clear(true) }) }
		if session.state.markOut != nil { actions.append(EditorMenuAction("Clear Out") { session.clear(false) }) }
		if let range = session.selection {
			actions.append(EditorMenuAction("Play Marked Range") { session.playMarked() })
			if range.duration < session.duration {
				actions.append(EditorMenuAction("Delete Marked Range") { session.delete(range) })
			}
		}
		if session.currentJoin != nil {
			actions.append(EditorMenuAction("Adjust Edit Point") { sheetFromMenu = fromMenu; session.showJoin() })
		}
		actions.append(EditorMenuAction("Previous Edit Point") { session.navigate(false) })
		actions.append(EditorMenuAction("Next Edit Point") { session.navigate(true) })
		if session.position > .zero && session.position < session.duration {
			actions.append(EditorMenuAction("Trim Head to Playhead") { session.trim(head: true) })
			actions.append(EditorMenuAction("Trim Tail to Playhead") { session.trim(head: false) })
		}
		if session.hasAudio {
			actions.append(EditorMenuAction("Trim Silences") {
				session.releaseAudio()
				sheetFromMenu = fromMenu
				session.sheet = .trimSilences
			})
		}
		return actions
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
	@FocusState private var typing: Bool
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
						.focused($typing)
						.autocorrectionDisabled()
						.onSubmit { jump() }
				}
				Button("Jump") { jump() }
				if let error { Text(error) }
			}
			.editorListMargins()
			.dismissKeyboardToolbar(while: typing) { typing = false }
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
	private enum Boundary: String, Identifiable {
		case outgoing = "Outgoing Out Point"
		case incoming = "Incoming In Point"
		var id: Self { self }
	}

	let session: CuttingBoardSession
	let point: ClipEditTimeline.EditPoint
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@Environment(\.dismiss) private var dismiss
	// The buttons edit this draft in place. Saving is the only operation that applies it to the timeline.
	private final class Draft {
		var outgoing: CMTime
		var incoming: CMTime
		weak var entryButton: UIButton?

		init(point: ClipEditTimeline.EditPoint) {
			outgoing = point.inTime
			incoming = point.outTime
		}
	}

	@State private var draft: Draft
	@State private var editor: Boundary?
	@State private var error: String?

	init(session: CuttingBoardSession, point: ClipEditTimeline.EditPoint) {
		self.session = session
		self.point = point
		_draft = State(initialValue: Draft(point: point))
	}

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(spacing: 0) {
					button(.outgoing)
					Divider()
					button(.incoming)
					if let error { Text(error) }
				}
			}
			.navigationTitle(point.name)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
			}
		}
		#if DEBUG
		.onAppear { session.editPointTrace.event("Edit Point appeared") }
		#endif
		.sheet(item: $editor, onDismiss: {
			#if DEBUG
			session.editPointTrace.event("Time entry dismissal callback")
			#endif
			if UIAccessibility.isVoiceOverRunning, let button = draft.entryButton {
				#if DEBUG
				session.editPointTrace.event("Posting layoutChanged to \(button.accessibilityLabel ?? "boundary")")
				#endif
				UIAccessibility.post(notification: .layoutChanged, argument: button)
			}
			draft.entryButton = nil
		}) { boundary in
			BoundaryTimeEditor(title: boundary.rawValue, session: session, format: format, time: time(for: boundary)) { time in
				update(time, for: boundary)
			}
		}
		.onReceive(session.$message) { if let message = $0 { error = message } }
		.onDisappear {
			#if DEBUG
			session.editPointTrace.event("Edit Point disappeared")
			#endif
			session.stopAudioPreview()
			if session.message != nil { session.message = nil }
		}
	}

	private func time(for boundary: Boundary) -> CMTime {
		boundary == .outgoing ? draft.outgoing : draft.incoming
	}

	private func button(_ boundary: Boundary) -> some View {
		func reading() -> String {
			session.timecode(time(for: boundary), format: format, sourceTime: true)
		}

		let longestValue = session.timecode(point.followingEnd, format: format, sourceTime: true)
		return EditPointButton(name: boundary.rawValue, value: reading(), longestValue: longestValue) { count in
			#if DEBUG
			let previous = reading()
			session.editPointTrace.event("\(boundary.rawValue) adjustment began, step \(count), value \(previous)")
			#endif
			let next = session.stepped(from: time(for: boundary), by: count, sourceTime: true)
			_ = update(next, for: boundary)
			let value = reading()
			#if DEBUG
			session.editPointTrace.event("Adjustment returning value \(value), visible value changed = \(previous != value)")
			#endif
			return value
		} activate: { button in
			#if DEBUG
			session.editPointTrace.event("Opening time entry for \(boundary.rawValue)")
			#endif
			draft.entryButton = button
			editor = boundary
		}
		.frame(maxWidth: .infinity, minHeight: 48)
	}

	private func update(_ next: CMTime, for boundary: Boundary) -> Bool {
		let lower = boundary == .outgoing ? point.precedingStart : draft.outgoing
		let upper = boundary == .outgoing ? draft.incoming : point.followingEnd
		guard next.isNumeric, next > lower, next < upper else { return false }
		guard next != time(for: boundary) else { return true }
		if boundary == .outgoing { draft.outgoing = next } else { draft.incoming = next }
		if error != nil { error = nil }
		session.previewBoundary(at: next, preceding: boundary == .outgoing)
		return true
	}

	private func save() {
		do {
			try session.saveJoin(point, inTime: draft.outgoing, outTime: draft.incoming)
			dismiss()
		} catch { self.error = error.localizedDescription }
	}
}

private struct EditPointButton: UIViewRepresentable {
	let name: String
	let value: String
	let longestValue: String
	let adjust: (Int) -> String
	let activate: (UIButton) -> Void

	func makeUIView(context: Context) -> Control {
		let button = Control(type: .system)
		button.configureLabels(name: name)
		button.accessibilityLabel = name
		button.accessibilityTraits.insert(.adjustable)
		button.addTarget(button, action: #selector(Control.openEditor), for: .primaryActionTriggered)
		return button
	}

	func updateUIView(_ button: Control, context: Context) {
		button.adjust = adjust
		button.activate = activate
		button.display(value)
	}

	func sizeThatFits(_ proposal: ProposedViewSize, uiView: Control, context: Context) -> CGSize? {
		guard let width = proposal.width, width > 0 else { return nil }
		return uiView.rowSize(width: width, longestValue: longestValue)
	}

	final class Control: UIButton {
		var adjust: ((Int) -> String)?
		var activate: ((UIButton) -> Void)?

		private let nameLabel = UILabel()
		private let valueLabel = UILabel()

		func configureLabels(name: String) {
			directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
			nameLabel.text = name
			nameLabel.font = .preferredFont(forTextStyle: .body)
			let base = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)
			valueLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: base)
			valueLabel.lineBreakMode = .byCharWrapping
			for label in [nameLabel, valueLabel] {
				label.adjustsFontForContentSizeCategory = true
				label.numberOfLines = 0
				label.isAccessibilityElement = false
				label.textColor = .tintColor
				label.translatesAutoresizingMaskIntoConstraints = false
				addSubview(label)
			}
			let margins = layoutMarginsGuide
			NSLayoutConstraint.activate([
				nameLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
				nameLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
				nameLabel.topAnchor.constraint(equalTo: margins.topAnchor),
				valueLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
				valueLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
				valueLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
				valueLabel.bottomAnchor.constraint(equalTo: margins.bottomAnchor)
			])
			nameLabel.setContentHuggingPriority(.required, for: .vertical)
		}

		func rowSize(width: CGFloat, longestValue: String) -> CGSize {
			let margins = directionalLayoutMargins
			let available = CGSize(width: max(1, width - margins.leading - margins.trailing), height: .greatestFiniteMagnitude)
			let titleHeight = nameLabel.sizeThatFits(available).height
			let paragraph = NSMutableParagraphStyle()
			paragraph.lineBreakMode = valueLabel.lineBreakMode
			let valueHeight = (longestValue as NSString).boundingRect(with: available,
				options: [.usesLineFragmentOrigin, .usesFontLeading],
				attributes: [.font: valueLabel.font as Any, .paragraphStyle: paragraph], context: nil).height
			return CGSize(width: width, height: max(48, margins.top + ceil(titleHeight) + 2 + ceil(valueHeight) + margins.bottom))
		}

		func display(_ value: String) {
			guard valueLabel.text != value else { return }
			valueLabel.text = value
			accessibilityValue = value
		}

		override func accessibilityIncrement() {
			if let value = adjust?(1) { display(value) }
		}

		override func accessibilityDecrement() {
			if let value = adjust?(-1) { display(value) }
		}

		@objc func openEditor() { activate?(self) }
	}
}

private struct BoundaryTimeEditor: View {
	let title: String
	let session: CuttingBoardSession
	let format: TimecodeFormat
	let confirm: (CMTime) -> Bool
	@Environment(\.dismiss) private var dismiss
	@State private var entry: TimeEntry
	@State private var error: String?
	@FocusState private var typing: Bool

	init(title: String, session: CuttingBoardSession, format: TimecodeFormat, time: CMTime, confirm: @escaping (CMTime) -> Bool) {
		self.title = title
		self.session = session
		self.format = format
		self.confirm = confirm
		_entry = State(initialValue: TimeEntry(time, session: session, format: format, source: true))
	}

	var body: some View {
		NavigationStack {
			Form {
				TextField(format == .frames ? "Source frame" : "Source time", text: $entry.text)
					.focused($typing)
					.autocorrectionDisabled()
					.onSubmit { accept() }
				if let error { Text(error) }
			}
			.dismissKeyboardToolbar(while: typing) { typing = false }
			.editorListMargins()
			.navigationTitle(title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) { Button("Done") { accept() } }
			}
		}
		.onAppear { typing = true }
	}

	private func accept() {
		guard let time = entry.value(session: session, format: format, source: true) else {
			error = format == .frames ? "Enter a valid source frame number." : "Enter a valid source time."
			return
		}
		guard confirm(time) else {
			error = "Enter a position inside the adjoining media with the Outgoing Out Point before the Incoming In Point."
			return
		}
		dismiss()
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
						.accessibilityAction(named: "Photos") { destination = .photos }
						.accessibilityAction(named: "Files") { destination = .files }
					} else {
						Button("Save as New Clip") { destination = .files }
					}
				}
			}
			.editorListMargins()
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
			FileSavePicker(file: rendered.url) { _ in output = nil }
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

final class ExportFile: Identifiable {
	let url: URL
	init(url: URL) { self.url = url }
	deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct FileSavePicker: UIViewControllerRepresentable {
	let file: URL
	let finish: (Bool) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(finish) }
	func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
		let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
		picker.delegate = context.coordinator
		return picker
	}
	func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

	final class Coordinator: NSObject, UIDocumentPickerDelegate {
		let finish: (Bool) -> Void
		init(_ finish: @escaping (Bool) -> Void) { self.finish = finish }
		func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(!urls.isEmpty) }
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
								.editorTouchRow(alignment: .leading)
								.accessibilityElement(children: .combine)
						}
					} header: {
						Text(section.title).accessibilityAddTraits(.isHeader)
					}
					.listRowBackground(EditorTheme.surface)
				}
			}
			.editorListMargins()
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
	@AccessibilityFocusState private var infoFocused: Bool

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 0) {
				Button {
					session.stop()
					if session.hasTimelineEdits { confirmClose = true } else { close() }
				} label: { Text("Close").padding(.horizontal).frame(minHeight: 48).contentShape(Rectangle()) }
				.accessibilityIdentifier("sharedBoardClose")
				.alert("Close this clip and discard unsaved edits?", isPresented: $confirmClose) {
					Button("Close Clip", role: .destructive, action: close)
					Button("Keep Editing", role: .cancel) {}
				}
				Text(session.hasVideo ? "Video Cutting Board" : "Audio Cutting Board")
					.font(.headline)
					.frame(maxWidth: .infinity, minHeight: 48)
					.contentShape(Rectangle())
					.accessibilityAddTraits(.isHeader)
				Button { session.stop(); showingInfo = true } label: {
					Text("Clip Info").padding(.horizontal).frame(minHeight: 48).contentShape(Rectangle())
				}
				.accessibilityFocused($infoFocused)
				.sheet(isPresented: $showingInfo, onDismiss: { infoFocused = true }) { ClipInfoView(session: session) }
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
	var title = "Full Screen Preview"
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var phase
	@State private var ready = false
	@State private var failed = false

	var body: some View {
		NavigationStack {
			VideoPlayer(player: playback.player)
				.disabled(!ready)
				.navigationTitle(title)
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .topBarLeading) {
						Button("Close") {
							playback.finish()
							dismiss()
						}
					}
					ToolbarItem(placement: .principal) {
						Text(title).font(.headline).accessibilityAddTraits(.isHeader)
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
			Text("Reopen the preview to try again.")
		}
		.interactiveDismissDisabled()
	}
}
