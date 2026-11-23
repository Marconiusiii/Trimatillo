import AVFoundation
import CoreMedia
import SwiftUI
import UIKit
#if DEBUG
import OSLog
#endif

struct CuttingBoardKeyboard: UIViewControllerRepresentable {
	let session: CuttingBoardSession
	var projectActions: BoardProjectActions? = nil
	let close: () -> Void

	func makeUIViewController(context: Context) -> BoardController {
		BoardController(session, projectActions: projectActions, close: close)
	}

	func updateUIViewController(_ controller: BoardController, context: Context) {
		controller.routing.projectActions = projectActions
		controller.routing.close = close
	}
}

@MainActor final class BoardKeyboardRouting {
	var projectActions: BoardProjectActions?
	var close: () -> Void

	init(projectActions: BoardProjectActions?, close: @escaping () -> Void) {
		self.projectActions = projectActions
		self.close = close
	}

	var forwardedActions: BoardProjectActions? {
		guard let projectActions else { return nil }
		return BoardProjectActions(append: { self.projectActions?.append() },
			split: { self.projectActions?.split() }, overwrite: { self.projectActions?.overwrite() },
			update: projectActions.update == nil ? nil : { self.projectActions?.update?() },
			placementSheet: { directTouch, placed in
				self.projectActions?.placementSheet(directTouch, placed) ?? AnyView(EmptyView())
			}, compositingSheet: projectActions.compositingSheet == nil ? nil : { self.projectActions?.compositingSheet?() ?? AnyView(EmptyView()) })
	}
}

final class BoardController: UIHostingController<PrimaryCuttingBoard> {
	let session: CuttingBoardSession
	let routing: BoardKeyboardRouting
	#if DEBUG
	private let keyboardTrace = EditorKeyboardTrace("Cutting Board")
	#endif
	private var commandCache: [Int: [UIKeyCommand]] = [:]
	init(_ session: CuttingBoardSession, projectActions: BoardProjectActions? = nil, close: @escaping () -> Void) {
		self.session = session
		let routing = BoardKeyboardRouting(projectActions: projectActions, close: close)
		self.routing = routing
		super.init(rootView: PrimaryCuttingBoard(session: session, projectActions: routing.forwardedActions, close: { routing.close() }))
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

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
		#if DEBUG
		keyboardTrace.availability(commandsEnabled, typing: EditorKeyMap.isTyping(in: view.window), presented: presentedViewController != nil)
		#endif
		guard commandsEnabled else { return [] }
		let kind = routing.projectActions == nil ? 0 : (routing.projectActions?.update == nil ? 1 : 2)
		if let cached = commandCache[kind] { return cached }
		var bindings = EditorKeyMap.bindings
		if let actions = routing.projectActions {
			bindings += [("e", [], "Append"), ("w", [], "Split at Playhead"), ("d", [], "Overwrite at Playhead"),
				("w", .alternate, "Add at Playhead")]
			if actions.update != nil { bindings.append(("u", .command, "Save Changes")) }
		}
		let commands = EditorKeyMap.commands(bindings, action: #selector(trimatilloBoardCommand(_:)))
		commandCache[kind] = commands
		return commands
	}

	private var commandsEnabled: Bool {
		presentedViewController == nil && session.sheet == nil && !session.choosingPlacement && session.message == nil && !EditorKeyMap.isTyping(in: view.window)
	}

	override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
		if action == #selector(trimatilloBoardCommand(_:)) { return commandsEnabled }
		return super.canPerformAction(action, withSender: sender)
	}

	@objc private func trimatilloBoardCommand(_ command: UIKeyCommand) {
		#if DEBUG
		let began = keyboardTrace.command(command, enabled: commandsEnabled, controller: self)
		defer {
			keyboardTrace.finished(began, state: session.keyboardPlaybackState)
			keyboardTrace.sample(after: began) { [weak session] in session?.keyboardPlaybackState ?? "closed" }
		}
		#endif
		guard commandsEnabled, let input = EditorKeyMap.normalizedInput(command.input) else { return }
		let flags = command.modifierFlags
		switch input {
		case " ", "k": session.toggle()
		case "j": session.shuttle(-1)
		case "l": session.shuttle(1)
		case "i", "o":
			let isIn = input == "i"
			if flags.contains(.alternate) { session.clear(isIn, spoken: true) } else { session.mark(isIn, spoken: true) }
		case UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow:
			let forward = input == UIKeyCommand.inputRightArrow
			if flags.contains(.command) { session.navigate(forward, spoken: true) }
			else { session.step((forward ? 1 : -1) * (flags.contains(.shift) ? 10 : 1)) }
		case ";", "'": session.navigate(input == "'", spoken: true)
		case UIKeyCommand.inputHome, UIKeyCommand.inputUpArrow: session.goToBoundary(end: false)
		case UIKeyCommand.inputEnd, UIKeyCommand.inputDownArrow: session.goToBoundary(end: true)
		case "[", "]": session.trim(head: input == "[", spoken: true)
		case "\u{8}", UIKeyCommand.inputDelete: session.delete(session.selection, spoken: true)
		case "z": if flags.contains(.shift) { session.redo() } else { session.undo() }
		case "e": routing.projectActions?.append()
		case "w":
			if flags.contains(.alternate) { session.stop(); session.choosingPlacement = true }
			else { routing.projectActions?.split() }
		case "d": routing.projectActions?.overwrite()
		case "u": routing.projectActions?.update?()
		case "t":
			let format = EditorPreferences.shared.string(forKey: "timecodeFormat").flatMap(TimecodeFormat.init(rawValue:)) ?? .milliseconds
			UIAccessibility.post(notification: .announcement, argument: session.timecode(session.currentPosition, format: format))
		case "\r": session.showJoin()
		default: break
		}
	}
}

enum EditorKeyMap {
	static func normalizedInput(_ input: String?) -> String? {
		guard let input, input.count == 1, input.first?.isLetter == true else { return input }
		return input.lowercased()
	}

	static func commands(_ bindings: [(String, UIKeyModifierFlags, String)], action: Selector) -> [UIKeyCommand] {
		bindings.map { input, flags, title in
			let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
			command.discoverabilityTitle = title
			command.wantsPriorityOverSystemBehavior = true
			command.allowsAutomaticMirroring = false
			if #available(iOS 26.0, *) {
				let stepping = [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow].contains(input)
					&& (flags.isEmpty || flags == .shift)
				command.repeatBehavior = stepping ? .repeatable : .nonRepeatable
			}
			return command
		}
	}

	static func isTyping(in view: UIView?) -> Bool {
		guard let view else { return false }
		// VoiceOver and SwiftUI can use text-input responders for navigation.
		// Suppress editor shortcuts only while a real editable field is active.
		if let field = view as? UITextField, field.isFirstResponder, field.isEditing { return true }
		if let text = view as? UITextView, text.isFirstResponder, text.isEditable { return true }
		return view.subviews.contains { isTyping(in: $0) }
	}

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

#if DEBUG
/// Logs native command delivery and subsequent focus changes without recording field contents.
final class EditorKeyboardTrace: NSObject {
	private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Trimatillo", category: "EditorKeyboard")
	private let screen: String
	private var previousAvailability: String?
	private var latestCommand: TimeInterval = 0

	init(_ screen: String) {
		self.screen = screen
		super.init()
		NotificationCenter.default.addObserver(self, selector: #selector(focusChanged(_:)), name: UIAccessibility.elementFocusedNotification, object: nil)
	}

	deinit { NotificationCenter.default.removeObserver(self) }

	func availability(_ enabled: Bool, typing: Bool, presented: Bool) {
		let state = "enabled=\(enabled), editingText=\(typing), presented=\(presented)"
		guard state != previousAvailability else { return }
		previousAvailability = state
		logger.notice("\(self.screen, privacy: .public): commands \(state, privacy: .public)")
	}

	func command(_ command: UIKeyCommand, enabled: Bool, controller: UIViewController) -> TimeInterval {
		latestCommand = ProcessInfo.processInfo.systemUptime
		logger.notice("\(self.screen, privacy: .public): received \(command.discoverabilityTitle ?? "command", privacy: .public), enabled=\(enabled), controller=\(String(describing: ObjectIdentifier(controller)), privacy: .public), firstResponder=\(controller.isFirstResponder), uptime=\(self.latestCommand)")
		return latestCommand
	}

	func finished(_ start: TimeInterval, state: String) {
		let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
		logger.notice("\(self.screen, privacy: .public): handled in \(milliseconds) ms, \(state, privacy: .public)")
	}

	func sample(after command: TimeInterval, state: @escaping @MainActor () -> String) {
		Task { @MainActor [weak self] in
			try? await Task.sleep(for: .milliseconds(150))
			guard let self, latestCommand == command else { return }
			logger.notice("\(self.screen, privacy: .public): after 150 ms: \(state(), privacy: .public)")
		}
	}

	func presses(_ presses: Set<UIPress>, phase: String) {
		// Record physical codes, never typed characters or field contents.
		for press in presses where press.key != nil {
			logger.notice("\(self.screen, privacy: .public): press \(phase, privacy: .public), code=\(press.key!.keyCode.rawValue), timestamp=\(press.timestamp)")
		}
	}

	@objc private func focusChanged(_ notification: Notification) {
		guard ProcessInfo.processInfo.systemUptime - latestCommand < 2,
			let element = notification.userInfo?[UIAccessibility.focusedElementUserInfoKey] as? NSObject else { return }
		let known = ["Close", "Play", "Pause", "Rewind", "Fast Forward", "Clip Info", "Direct Touch Editor"]
		let label = element.accessibilityLabel.flatMap { known.contains($0) ? $0 : nil } ?? "other control"
		logger.notice("\(self.screen, privacy: .public): focus after command: \(label, privacy: .public), type=\(String(describing: type(of: element)), privacy: .public)")
	}
}
#endif
