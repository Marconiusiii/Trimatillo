import AVFoundation
import SwiftUI

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

	var body: some View {
		GeometryReader { geometry in
			let wide = geometry.size.width > geometry.size.height && geometry.size.width > 550
			let layout = wide ? AnyLayout(HStackLayout(alignment: .top)) : AnyLayout(VStackLayout())
			layout {
				VStack(spacing: 4) {
					CuttingBoardTouchSurface(session: session)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
					transport
				}
				.frame(height: wide ? geometry.size.height : max(100, geometry.size.height * 0.48))
				ScrollView {
					controls.padding(.vertical, 4)
				}
				.frame(maxWidth: .infinity)
			}
		}
		.padding(.horizontal, 8)
		.background(EditorTheme.workspace)
		.tint(EditorTheme.accent)
		.accessibilityAction(.magicTap) { session.toggle() }
		.sheet(item: $session.sheet) { sheet in
			BoardEditSheet(session: session, sheet: sheet)
				.accessibilityAction(.magicTap) { session.toggle() }
		}
		.alert("Cutting Board", isPresented: Binding(get: { session.message != nil && session.sheet == nil }, set: { if !$0 { session.message = nil } })) {
			Button("OK") { session.message = nil }
		} message: { Text(session.message ?? "") }
	}

	private var transport: some View {
		HStack {
			transportButton("Rewind", "backward.fill") { session.shuttle(-1) }
			transportButton(session.rate == 0 ? "Play" : "Pause", session.rate == 0 ? "play.fill" : "pause.fill") { session.toggle() }
			transportButton("Fast Forward", "forward.fill") { session.shuttle(1) }
		}
		.background(EditorTheme.surface, in: RoundedRectangle(cornerRadius: 10))
	}

	private func transportButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Label { Text(title) } icon: { Image(systemName: symbol) }
				.labelStyle(.iconOnly)
				.frame(maxWidth: .infinity, minHeight: 48)
				.contentShape(Rectangle())
		}
	}

	private var controls: some View {
		VStack(alignment: .leading, spacing: 8) {
			Stepper("Clip playhead, " + session.positionLabel, onIncrement: { move(true) }, onDecrement: { move(false) })
				.accessibilityActions { editActions }
			Picker("Step by", selection: $increment) {
				Text(session.hasVideo ? "One frame" : "1/30 second").tag(1)
				Text(session.hasVideo ? "Ten frames" : "10/30 second").tag(10)
				Text("Edit point").tag(0)
			}
			.pickerStyle(.menu)
			Button("Jump to Time") { session.stop(); session.sheet = .jump }
			markButton(true)
			markButton(false)
			HStack {
				Menu("Edit") { editActions }
				Spacer()
				Button("Undo") { session.undo() }.disabled(!session.canUndo)
			}
			if session.rate != 0 {
				Text(session.rate < 0 ? "Reverse, \(-session.rate)×" : "Forward, \(session.rate)×")
			}
		}
		.buttonStyle(.bordered)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func move(_ forward: Bool) {
		if increment == 0 { session.navigate(forward) }
		else { session.step(forward ? increment : -increment) }
	}

	private func markButton(_ isIn: Bool) -> some View {
		let time = isIn ? session.state.markIn : session.state.markOut
		let name = isIn ? "In" : "Out"
		return Button("Mark " + name + (time.map { ", " + CuttingBoardSession.timecode($0) } ?? "")) { session.mark(isIn) }
			.accessibilityActions {
				if let time {
					Button("Go to " + name) { session.seek(time) }
					Button("Clear " + name) { session.clear(isIn) }
				}
			}
	}

	@ViewBuilder private var editActions: some View {
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
			Button("Adjust Edit Point") { session.showJoin() }
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
