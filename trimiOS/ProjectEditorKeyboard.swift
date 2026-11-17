import SwiftUI
import UIKit

struct ProjectEditorKeyboard<Content: View>: UIViewControllerRepresentable {
	let enabled: Bool
	var tool = ProjectTool.editor
	let undoShake: () -> Bool
	let perform: (String, UIKeyModifierFlags) -> Void
	@ViewBuilder let content: () -> Content

	func makeUIViewController(context: Context) -> Controller {
		Controller(rootView: content())
	}

	func updateUIViewController(_ controller: Controller, context: Context) {
		controller.rootView = content()
		controller.tool = tool
		controller.undoShake = enabled ? undoShake : nil
		controller.performKey = enabled ? perform : nil
	}

	final class Controller: UIHostingController<Content> {
		var tool = ProjectTool.editor
		var undoShake: (() -> Bool)?
		var performKey: ((String, UIKeyModifierFlags) -> Void)?
		override var canBecomeFirstResponder: Bool { true }

		override func viewDidAppear(_ animated: Bool) {
			super.viewDidAppear(animated)
			becomeFirstResponder()
		}

		override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
			guard motion == .motionShake, presentedViewController == nil,
				UIAccessibility.isShakeToUndoEnabled, EditorPreferences.shakeEnabled, undoShake?() == true else {
				super.motionEnded(motion, with: event)
				return
			}
		}

		override var keyCommands: [UIKeyCommand]? {
			guard performKey != nil, presentedViewController == nil else { return [] }
			var bindings = EditorKeyMap.bindings.map { input, flags, title in
				switch input {
				case "\r": return (input, flags, "Open Cutting Board")
				case "\u{8}", UIKeyCommand.inputDelete: return (input, flags, "Remove Clips")
				default: return (input, flags, title)
				}
			}
			if tool != .editor {
				bindings.removeAll { ["[", "]", "\u{8}", UIKeyCommand.inputDelete, "\r"].contains($0.0) }
				if tool != .voicer {
					bindings += [(tool == .captioner ? "c" : "d", [.command, .shift], tool == .captioner ? "New Caption" : "New Description"),
						("\r", [], tool == .captioner ? "Edit Caption" : "Edit Description")]
				}
			} else {
				bindings += [("d", [.command, .shift], "New Description"), (UIKeyCommand.inputUpArrow, [.alternate, .command], "Previous Track"),
				(UIKeyCommand.inputDownArrow, [.alternate, .command], "Next Track"),
				(UIKeyCommand.inputLeftArrow, [.command, .alternate], "Move Earlier"),
				(UIKeyCommand.inputRightArrow, [.command, .alternate], "Move Later"),
				("s", .shift, "Add to Drag"), ("s", [], "Mark for Editing"), ("c", [], "Open Cutting Board"),
				("b", .command, "Split Clip"), ("v", [.command, .alternate], "Drop After"),
				(UIKeyCommand.inputEscape, [], "Cancel Drag")]
			}
			bindings.append(("v", [.command, .shift], "Record Voice Over"))
			return bindings.map { key, flags, title in
				let command = UIKeyCommand(input: key, modifierFlags: flags, action: #selector(handle(_:)))
				command.discoverabilityTitle = title
				return command
			}
		}

		@objc private func handle(_ key: UIKeyCommand) {
			guard presentedViewController == nil, let input = key.input else { return }
			performKey?(input, key.modifierFlags)
		}
	}
}
