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
		private var commandCache: [ProjectTool: [UIKeyCommand]] = [:]
		var tool = ProjectTool.editor
		var undoShake: (() -> Bool)?
		var performKey: ((String, UIKeyModifierFlags) -> Void)?
		override var canBecomeFirstResponder: Bool { true }

		override func viewDidAppear(_ animated: Bool) {
			super.viewDidAppear(animated)
			if !EditorKeyMap.isTyping(in: view.window) { becomeFirstResponder() }
		}

		override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
			guard motion == .motionShake, presentedViewController == nil,
				UIAccessibility.isShakeToUndoEnabled, EditorPreferences.shakeEnabled, undoShake?() == true else {
				super.motionEnded(motion, with: event)
				return
			}
		}

		override var keyCommands: [UIKeyCommand]? {
			guard commandsEnabled else { return [] }
			if let cached = commandCache[tool] { return cached }
			var bindings = EditorKeyMap.bindings.map { input, flags, title in
				switch input {
				case "\r": return (input, flags, "Open Cutting Board")
				case "\u{8}", UIKeyCommand.inputDelete: return (input, flags, "Remove Clips")
				default: return (input, flags, title)
				}
			}
			if tool != .editor {
				bindings.removeAll { ["[", "]", "\u{8}", UIKeyCommand.inputDelete, "\r"].contains($0.0) }
				if tool == .mixer {
					bindings += [(UIKeyCommand.inputUpArrow, [.alternate, .command], "Previous Audio Track"),
						(UIKeyCommand.inputDownArrow, [.alternate, .command], "Next Audio Track")]
				} else if tool != .voicer {
					bindings += [(tool == .captioner ? "c" : "d", [.command, .shift], tool == .captioner ? "New Caption" : "New Description"),
						("\r", [], tool == .captioner ? "Edit Caption" : "Edit Description")]
				}
			} else {
				bindings += [("x", [], "Quick Crossfade"), ("f", [], "Quick Fade"), ("t", [.command, .shift], "Transitions"), ("d", [.command, .shift], "New Description"), (UIKeyCommand.inputUpArrow, [.alternate, .command], "Previous Track"),
				(UIKeyCommand.inputDownArrow, [.alternate, .command], "Next Track"),
				(UIKeyCommand.inputLeftArrow, [.command, .alternate], "Move Earlier"),
				(UIKeyCommand.inputRightArrow, [.command, .alternate], "Move Later"),
				("s", .shift, "Add to Drag"), ("s", [], "Mark for Editing"), ("c", [], "Open Cutting Board"),
				("b", .command, "Split Clip"), ("v", [.command, .alternate], "Drop After"),
				(UIKeyCommand.inputEscape, [], "Cancel Drag")]
			}
			bindings.append(("m", [.command, .shift], "Open Mixer"))
			bindings.append(("v", [.command, .shift], "Record Voice Over"))
			let commands = EditorKeyMap.commands(bindings, action: #selector(handle(_:)))
			commandCache[tool] = commands
			return commands
		}

		private var commandsEnabled: Bool {
			performKey != nil && presentedViewController == nil && !EditorKeyMap.isTyping(in: view.window)
		}

		@objc private func handle(_ key: UIKeyCommand) {
			guard commandsEnabled, let input = key.input else { return }
			performKey?(input, key.modifierFlags)
		}
	}
}
