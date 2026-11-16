import SwiftUI
import UIKit

enum EditorTheme {
	static let workspace = adaptive(
		light: 0xE5E5E7,
		dark: 0x1B1C1E,
		highLight: 0xDDDDDF,
		highDark: 0x101113
	)
	static let surface = adaptive(
		light: 0xF5F5F6,
		dark: 0x262729,
		highLight: 0xFFFFFF,
		highDark: 0x202123
	)
	static let playhead = adaptive(
		light: 0xC43124,
		dark: 0xFF7968,
		highLight: 0xAA2418,
		highDark: 0xFF9688
	)

	static let faceTop = adaptive(light: 0xFCFCFD, dark: 0x37393D, highLight: 0xFFFFFF, highDark: 0x252629)
	static let faceBottom = adaptive(light: 0xE5E6E8, dark: 0x2B2D31, highLight: 0xF0F1F2, highDark: 0x17181A)
	static let pressedBottom = adaptive(light: 0xD4D6D9, dark: 0x202226, highLight: 0xE3E4E5, highDark: 0x101113)
	static let controlOutline = adaptive(light: 0x67696D, dark: 0x9C9FA4, highLight: 0x44464A, highDark: 0xD2D4D8)
	static let disabledInk = adaptive(light: 0x505256, dark: 0xB8BABE, highLight: 0x44464A, highDark: 0xD2D4D8)

	static func adaptive(light: Int, dark: Int, highLight: Int, highDark: Int) -> Color {
		Color(uiColor: UIColor { traits in
			let high = traits.accessibilityContrast == .high
			let value = traits.userInterfaceStyle == .dark ? (high ? highDark : dark) : (high ? highLight : light)
			return UIColor(red: CGFloat(value >> 16) / 255,
				green: CGFloat((value >> 8) & 255) / 255,
				blue: CGFloat(value & 255) / 255, alpha: 1)
		})
	}
}

enum ControlColor: String, CaseIterable {
	case teal = "Teal"
	case blue = "Blue"
	case indigo = "Indigo"
	case purple = "Purple"
	case rose = "Rose"
	case amber = "Amber"

	var accent: Color {
		switch self {
		case .teal: EditorTheme.adaptive(light: 0x004E47, dark: 0xA6CCC8, highLight: 0x003C36, highDark: 0xCCE2E0)
		case .blue: EditorTheme.adaptive(light: 0x0F438A, dark: 0xADC6E9, highLight: 0x0C336A, highDark: 0xD0DFF2)
		case .indigo: EditorTheme.adaptive(light: 0x423A8C, dark: 0xC4C0E3, highLight: 0x322C6B, highDark: 0xDEDCEF)
		case .purple: EditorTheme.adaptive(light: 0x602D83, dark: 0xD4BDE3, highLight: 0x4A2365, highDark: 0xE6D8EF)
		case .rose: EditorTheme.adaptive(light: 0x7A2643, dark: 0xE3BAC9, highLight: 0x5F1D34, highDark: 0xEFD9E1)
		case .amber: EditorTheme.adaptive(light: 0x603E00, dark: 0xD6C39E, highLight: 0x493000, highDark: 0xE7DCC7)
		}
	}

	var selection: Color {
		switch self {
		case .teal: EditorTheme.adaptive(light: 0xE0EDEC, dark: 0x0F2523, highLight: 0xCCE2E0, highDark: 0x0A2926)
		case .blue: EditorTheme.adaptive(light: 0xE3ECF7, dark: 0x142236, highLight: 0xD0DFF2, highDark: 0x102440)
		case .indigo: EditorTheme.adaptive(light: 0xEAE9F5, dark: 0x1F1D32, highLight: 0xDCDAEF, highDark: 0x211E3B)
		case .purple: EditorTheme.adaptive(light: 0xF0E8F5, dark: 0x291B32, highLight: 0xE6D8EF, highDark: 0x2E1B3B)
		case .rose: EditorTheme.adaptive(light: 0xF5E7EC, dark: 0x321A22, highLight: 0xEED7DF, highDark: 0x3A1925)
		case .amber: EditorTheme.adaptive(light: 0xF2ECE0, dark: 0x2D220F, highLight: 0xE9DFCC, highDark: 0x33250A)
		}
	}

	var fill: Color {
		switch self {
		case .teal: Color(red: 0x00 / 255.0, green: 0x64 / 255.0, blue: 0x5B / 255.0)
		case .blue: Color(red: 0x13 / 255.0, green: 0x56 / 255.0, blue: 0xB1 / 255.0)
		case .indigo: Color(red: 0x51 / 255.0, green: 0x47 / 255.0, blue: 0xAD / 255.0)
		case .purple: Color(red: 0x7B / 255.0, green: 0x3A / 255.0, blue: 0xA7 / 255.0)
		case .rose: Color(red: 0x9D / 255.0, green: 0x30 / 255.0, blue: 0x56 / 255.0)
		case .amber: Color(red: 0x7A / 255.0, green: 0x50 / 255.0, blue: 0x00 / 255.0)
		}
	}
}

enum DirectTouchScrubbing: String, CaseIterable {
	case absolute = "Absolute"
	case relative = "Relative"
}

enum TimecodeFormat: String, CaseIterable {
	case milliseconds = "Milliseconds"
	case standard = "Standard"
	case frames = "Frames"
}

enum EditorPreferences {
	static let shared = UserDefaults(suiteName: "group.com.marconius.trimato-ios")!
	static var shakeEnabled: Bool {
		shared.object(forKey: "shakeToUndo") as? Bool ?? true
	}
}

enum EditorAppearance: String, CaseIterable {
	case system = "System"
	case light = "Light"
	case dark = "Dark"

	var scheme: ColorScheme? {
		switch self {
		case .system: nil
		case .light: .light
		case .dark: .dark
		}
	}
}

private struct AppearanceModifier: ViewModifier {
	@AppStorage("appearance", store: EditorPreferences.shared) var appearance = EditorAppearance.system

	@AppStorage("controlColor", store: EditorPreferences.shared) var color = ControlColor.teal

	func body(content: Content) -> some View {
		content.tint(color.accent).preferredColorScheme(appearance.scheme)
	}
}

private struct KeyboardAccessory: UIViewRepresentable {
	let endEditing: () -> Void

	func makeUIView(context: Context) -> Attachment { Attachment() }

	func updateUIView(_ attachment: Attachment, context: Context) {
		attachment.endEditing = endEditing
		attachment.installIfNeeded()
	}

	final class Attachment: UIView {
		var endEditing: (() -> Void)?
		private lazy var toolbar: UIToolbar = {
			let bar = UIToolbar()
			let dismiss = UIBarButtonItem(title: "Dismiss Keyboard", primaryAction: UIAction { [weak self] _ in
				self?.endEditing?()
			})
			bar.items = [.flexibleSpace(), dismiss]
			bar.sizeToFit()
			return bar
		}()

		override func didMoveToWindow() {
			super.didMoveToWindow()
			let center = NotificationCenter.default
			center.removeObserver(self)
			guard window != nil else { return }
			for event in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
				center.addObserver(self, selector: #selector(editingBegan(_:)), name: event, object: nil)
			}
			installIfNeeded()
		}

		func installIfNeeded() {
			guard let window, let responder = firstResponder(in: window) else { return }
			install(on: responder)
		}

		@objc private func editingBegan(_ notification: Notification) {
			guard let responder = notification.object as? UIView, responder.window === window else { return }
			install(on: responder)
		}

		private func install(on responder: UIView) {
			if let field = responder as? UITextField, field.inputAccessoryView !== toolbar {
				field.inputAccessoryView = toolbar
				field.reloadInputViews()
			} else if let editor = responder as? UITextView, editor.inputAccessoryView !== toolbar {
				editor.inputAccessoryView = toolbar
				editor.reloadInputViews()
			}
		}

		private func firstResponder(in view: UIView) -> UIView? {
			if view.isFirstResponder { return view }
			for child in view.subviews {
				if let responder = firstResponder(in: child) { return responder }
			}
			return nil
		}
	}
}

extension View {
	func dismissKeyboardToolbar(while editing: Bool, _ endEditing: @escaping () -> Void) -> some View {
		background {
			if editing {
				KeyboardAccessory(endEditing: endEditing)
					.frame(width: 0, height: 0)
					.accessibilityHidden(true)
			}
		}
	}
}

extension View {
	func editorAppearance() -> some View { modifier(AppearanceModifier()) }
}

extension View {
	func editorTouchRow(alignment: Alignment = .center) -> some View {
		frame(maxWidth: .infinity, minHeight: 48, alignment: alignment)
			.contentShape(Rectangle())
	}

	func editorListMargins() -> some View {
		contentMargins(.all, 0, for: .scrollContent)
			.listSectionSpacing(0)
	}
}

struct EditorButtonStyle: ButtonStyle {
	let square: Bool
	let badge: String?
	let reservesBadgeSpace: Bool
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal
	@Environment(\.isEnabled) private var enabled
	@Environment(\.colorSchemeContrast) private var contrast
	@ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 19

	init(square: Bool = false, badge: String? = nil, reservesBadgeSpace: Bool = false) {
		self.square = square
		self.badge = badge
		self.reservesBadgeSpace = reservesBadgeSpace
	}

	func makeBody(configuration: Configuration) -> some View {
		let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
		let pressed = configuration.isPressed
		let top = pressed ? EditorTheme.faceBottom : EditorTheme.faceTop
		let bottom = pressed ? EditorTheme.pressedBottom : EditorTheme.faceBottom
		VStack(spacing: 0) {
			Group {
				if square {
					configuration.label
						.font(.system(size: min(symbolSize, 32), weight: .medium))
						.frame(width: 44, height: 44)
				} else {
					configuration.label
						.multilineTextAlignment(.center)
						.fixedSize(horizontal: false, vertical: true)
						.padding(.horizontal, 8)
						.padding(.vertical, 4)
						.frame(minWidth: 44, minHeight: 44)
				}
			}
			.foregroundStyle(enabled ? color.accent : EditorTheme.disabledInk)
			.background(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom), in: shape)
			.overlay {
				shape.inset(by: contrast == .increased ? 2 : 1)
					.strokeBorder(LinearGradient(colors: [.white.opacity(pressed ? 0.02 : 0.06), .black.opacity(0.04)],
						startPoint: .top, endPoint: .bottom), lineWidth: 1)
					.allowsHitTesting(false)
			}
			.overlay {
				shape.strokeBorder(EditorTheme.controlOutline, style: StrokeStyle(lineWidth: contrast == .increased ? 2 : 1, dash: enabled ? [] : [3, 2]))
					.allowsHitTesting(false)
			}
			if reservesBadgeSpace || badge != nil {
				Text(badge ?? "1x")
					.font(.caption.weight(.semibold))
					.foregroundStyle(EditorTheme.surface)
					.padding(.horizontal, 4)
					.background(color.accent, in: Capsule())
					.opacity(badge == nil ? 0 : 1)
					.accessibilityHidden(true)
			}
		}
		.padding(2)
		.frame(minWidth: 48, maxWidth: .infinity, minHeight: 48, maxHeight: .infinity)
		.contentShape(Rectangle())
	}
}

struct EditorCommandRow<Content: View>: View {
	@Environment(\.dynamicTypeSize) private var textSize
	@ViewBuilder var content: () -> Content

	var body: some View {
		let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
		layout { content() }
	}
}
