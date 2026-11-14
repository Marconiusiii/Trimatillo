import CoreMedia
import SwiftUI
import UIKit

struct CuttingBoardKeyboard: UIViewControllerRepresentable {
	let session: CuttingBoardSession
	var projectActions: BoardProjectActions? = nil
	let close: () -> Void

	func makeUIViewController(context: Context) -> BoardController {
		BoardController(session, projectActions: projectActions, close: close)
	}

	func updateUIViewController(_ controller: BoardController, context: Context) {
		controller.rootView = PrimaryCuttingBoard(session: session, projectActions: projectActions, close: close)
	}
}

final class BoardController: UIHostingController<PrimaryCuttingBoard> {
	let session: CuttingBoardSession
	init(_ session: CuttingBoardSession, projectActions: BoardProjectActions? = nil, close: @escaping () -> Void) {
		self.session = session
		super.init(rootView: PrimaryCuttingBoard(session: session, projectActions: projectActions, close: close))
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override var canBecomeFirstResponder: Bool { true }

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		becomeFirstResponder()
	}

	override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
		guard motion == .motionShake, presentedViewController == nil, session.sheet == nil,
			UIAccessibility.isShakeToUndoEnabled,
			EditorPreferences.shakeEnabled,
			session.canUndo else {
			super.motionEnded(motion, with: event)
			return
		}
		session.undo()
	}

	override func accessibilityPerformMagicTap() -> Bool {
		session.toggle()
		return true
	}

	override var keyCommands: [UIKeyCommand]? {
		guard presentedViewController == nil else { return [] }
		var bindings = EditorKeyMap.bindings
		if let actions = rootView.projectActions {
			bindings += [("e", [], "Append"), ("w", [], "Split at Playhead"), ("d", [], "Overwrite at Playhead"),
				("w", .alternate, "Add at Playhead")]
			if actions.update != nil { bindings.append(("u", .command, "Save Changes")) }
		}
		return bindings.map { input, modifiers, title in
			let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: #selector(performCommand(_:)))
			command.discoverabilityTitle = title
			return command
		}
	}

	@objc private func performCommand(_ command: UIKeyCommand) {
		guard presentedViewController == nil else { return }
		let flags = command.modifierFlags
		switch command.input {
		case " ", "k": session.toggle()
		case "j": session.shuttle(-1)
		case "l": session.shuttle(1)
		case "i", "o":
			let isIn = command.input == "i"
			if flags.contains(.alternate) { session.clear(isIn) } else { session.mark(isIn) }
		case UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow:
			let forward = command.input == UIKeyCommand.inputRightArrow
			if flags.contains(.command) { session.navigate(forward) }
			else { session.step((forward ? 1 : -1) * (flags.contains(.shift) ? 10 : 1)) }
		case ";", "'": session.navigate(command.input == "'")
		case UIKeyCommand.inputHome, UIKeyCommand.inputUpArrow: session.seek(.zero)
		case UIKeyCommand.inputEnd, UIKeyCommand.inputDownArrow: session.seek(session.duration)
		case "[", "]": session.trim(head: command.input == "[")
		case "\u{8}", UIKeyCommand.inputDelete: session.delete(session.selection)
		case "z": if flags.contains(.shift) { session.redo() } else { session.undo() }
		case "e": rootView.projectActions?.append()
		case "w":
			if flags.contains(.alternate) { session.stop(); session.choosingPlacement = true }
			else { rootView.projectActions?.split() }
		case "d": rootView.projectActions?.overwrite()
		case "u": rootView.projectActions?.update?()
		case "t":
			let format = EditorPreferences.shared.string(forKey: "timecodeFormat").flatMap(TimecodeFormat.init(rawValue:)) ?? .milliseconds
			UIAccessibility.post(notification: .announcement, argument: session.timecode(session.position, format: format))
		case "\r": session.showJoin()
		default: break
		}
	}
}

enum EditorKeyMap {
	static let bindings: [(String, UIKeyModifierFlags, String)] = [
		(" ", [], "Play or Pause"), ("k", [], "Play or Pause"),
		("j", [], "Rewind"), ("l", [], "Play Forward"),
		("i", [], "Mark In"), ("o", [], "Mark Out"),
		("i", .alternate, "Clear In"), ("o", .alternate, "Clear Out"),
		(UIKeyCommand.inputLeftArrow, [], "Step Back"),
		(UIKeyCommand.inputRightArrow, [], "Step Forward"),
		(UIKeyCommand.inputLeftArrow, .shift, "Back Ten Steps"),
		(UIKeyCommand.inputRightArrow, .shift, "Forward Ten Steps"),
		(";", [], "Previous Edit Point"), ("'", [], "Next Edit Point"),
		(UIKeyCommand.inputLeftArrow, .command, "Previous Edit Point"),
		(UIKeyCommand.inputRightArrow, .command, "Next Edit Point"),
		(UIKeyCommand.inputHome, [], "Start"), (UIKeyCommand.inputEnd, [], "End"),
		(UIKeyCommand.inputUpArrow, .command, "Start"), (UIKeyCommand.inputDownArrow, .command, "End"),
		("[", .command, "Trim Head"), ("]", .command, "Trim Tail"),
		("\u{8}", [], "Delete Marked Range"), (UIKeyCommand.inputDelete, [], "Delete Marked Range"),
		("z", .command, "Undo"), ("z", [.command, .shift], "Redo"), ("t", [], "Current Time"), ("\r", [], "Adjust Edit Point")
	]
}
