import CoreMedia
import SwiftUI
import UIKit

struct CuttingBoardKeyboard: UIViewControllerRepresentable {
	let session: CuttingBoardSession

	func makeUIViewController(context: Context) -> BoardController {
		BoardController(session)
	}

	func updateUIViewController(_ controller: BoardController, context: Context) {}
}

final class BoardController: UIHostingController<CuttingBoardView> {
	let session: CuttingBoardSession
	init(_ session: CuttingBoardSession) {
		self.session = session
		super.init(rootView: CuttingBoardView(session: session))
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override var canBecomeFirstResponder: Bool { true }

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		becomeFirstResponder()
	}

	override func accessibilityPerformMagicTap() -> Bool {
		session.toggle()
		return true
	}

	override var keyCommands: [UIKeyCommand]? {
		guard presentedViewController == nil else { return [] }
		let bindings: [(String, UIKeyModifierFlags, String)] = [
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
			("z", .command, "Undo"), ("t", [], "Current Time"), ("\r", [], "Adjust Edit Point")
		]
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
		case "z": session.undo()
		case "t": UIAccessibility.post(notification: .announcement, argument: CuttingBoardSession.timecode(session.position))
		case "\r": session.showJoin()
		default: break
		}
	}
}
