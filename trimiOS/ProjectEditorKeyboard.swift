import SwiftUI
import UIKit

struct ProjectEditorKeyboard<Content: View>: UIViewControllerRepresentable {
	let playback: ProjectPlayback
	let enabled: Bool
	var tool = ProjectTool.editor
	let undoShake: () -> Bool
	let perform: (String, UIKeyModifierFlags) -> Void
	@ViewBuilder let content: () -> Content

	func makeUIViewController(context: Context) -> Controller {
		Controller(rootView: content(), playback: playback)
	}

	func updateUIViewController(_ controller: Controller, context: Context) {
		controller.rootView = content()
		controller.tool = tool
		controller.undoShake = enabled ? undoShake : nil
		controller.performKey = enabled ? perform : nil
	}

	final class Controller: UIHostingController<Content> {
		#if DEBUG
		private let keyboardTrace = EditorKeyboardTrace("Project")
		#endif
		private let playback: ProjectPlayback

		init(rootView: Content, playback: ProjectPlayback) {
			self.playback = playback
			super.init(rootView: rootView)
		}

		@available(*, unavailable)
		required init?(coder: NSCoder) { fatalError() }

		private var commandCache: [ProjectTool: [UIKeyCommand]] = [:]
		var tool = ProjectTool.editor
		var undoShake: (() -> Bool)?
		var performKey: ((String, UIKeyModifierFlags) -> Void)?
		override var canBecomeFirstResponder: Bool { true }

		#if DEBUG
		override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
			if commandsEnabled { keyboardTrace.presses(presses, phase: "began") }
			super.pressesBegan(presses, with: event)
		}

		override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
			if commandsEnabled { keyboardTrace.presses(presses, phase: "ended") }
			super.pressesEnded(presses, with: event)
		}

		override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
			if commandsEnabled { keyboardTrace.presses(presses, phase: "cancelled") }
			super.pressesCancelled(presses, with: event)
		}
		#endif


		override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
			guard motion == .motionShake, presentedViewController == nil,
				UIAccessibility.isShakeToUndoEnabled, EditorPreferences.shakeEnabled, undoShake?() == true else {
				super.motionEnded(motion, with: event)
				return
			}
		}

		override var keyCommands: [UIKeyCommand]? {
			#if DEBUG
			keyboardTrace.availability(commandsEnabled, typing: EditorKeyMap.isTyping(in: view.window), presented: presentedViewController != nil)
			#endif
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
			let commands = EditorKeyMap.commands(bindings, action: #selector(trimatilloProjectCommand(_:)))
			commandCache[tool] = commands
			return commands
		}

		private var commandsEnabled: Bool {
			performKey != nil && presentedViewController == nil && !EditorKeyMap.isTyping(in: view.window)
		}

		@objc private func trimatilloProjectCommand(_ key: UIKeyCommand) {
			#if DEBUG
			let began = keyboardTrace.command(key, enabled: commandsEnabled, controller: self)
			defer {
				keyboardTrace.finished(began, state: playback.keyboardPlaybackState)
				keyboardTrace.sample(after: began) { [weak playback] in playback?.keyboardPlaybackState ?? "closed" }
			}
			#endif
			guard commandsEnabled, let input = key.input else { return }
			performKey?(input, key.modifierFlags)
		}
	}
}
