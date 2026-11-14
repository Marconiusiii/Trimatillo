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

extension View {
	func editorAppearance() -> some View { modifier(AppearanceModifier()) }
}
