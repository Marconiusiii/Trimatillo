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
	static let accent = adaptive(
		light: 0x004E47,
		dark: 0xA6CCC8,
		highLight: 0x003C36,
		highDark: 0xCCE2E0
	)
	static let selection = adaptive(
		light: 0xE0EDEC,
		dark: 0x0F2523,
		highLight: 0xCCE2E0,
		highDark: 0x0A2926
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
