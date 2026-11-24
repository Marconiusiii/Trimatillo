import SwiftUI
import UIKit

struct EditorMenuButton: UIViewRepresentable {
	let title: String
	let actions: [EditorMenuAction]
	@Environment(\.isEnabled) private var enabled
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal

	func makeUIView(context: Context) -> MenuButton {
		MenuButton(type: .system)
	}

	func updateUIView(_ button: MenuButton, context: Context) {
		button.configure(title: title, actions: actions, enabled: enabled, tint: UIColor(color.accent))
	}

	func sizeThatFits(_ proposal: ProposedViewSize, uiView: MenuButton, context: Context) -> CGSize? {
		let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: uiView.traitCollection)
		let width = max(48, proposal.width ?? ceil((title as NSString).size(withAttributes: [.font: font]).width) + 20)
		let size = (title as NSString).boundingRect(with: CGSize(width: max(1, width - 20), height: .greatestFiniteMagnitude),
			options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
		return CGSize(width: width, height: max(48, ceil(size.height) + 12))
	}

	final class MenuButton: UIButton {
		private var actions: [EditorMenuAction] = []
		private var menuTitles: [String] = []
		private var selectedAction = false
		private var returnFocus = false
		private var menuVisible = false
		private let face = CAGradientLayer()
		private let bevel = CAGradientLayer()
		private let bevelMask = CAShapeLayer()
		private let outline = CAShapeLayer()

		override init(frame: CGRect) {
			super.init(frame: frame)
			showsMenuAsPrimaryAction = true
			preferredMenuElementOrder = .fixed
			var appearance = UIButton.Configuration.plain()
			appearance.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
			appearance.titleAlignment = .center
			appearance.titleLineBreakMode = .byWordWrapping
			configuration = appearance
			titleLabel?.numberOfLines = 0
			titleLabel?.adjustsFontForContentSizeCategory = true
			face.cornerRadius = 4
			face.cornerCurve = .continuous
			layer.insertSublayer(face, at: 0)
			bevel.mask = bevelMask
			layer.insertSublayer(bevel, above: face)
			layer.insertSublayer(outline, above: bevel)
			registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, UITraitPreferredContentSizeCategory.self]) { (button: MenuButton, _: UITraitCollection) in
				button.setNeedsUpdateConfiguration()
				button.setNeedsLayout()
				button.invalidateIntrinsicContentSize()
			}
		}

		required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

		func configure(title: String, actions: [EditorMenuAction], enabled: Bool, tint: UIColor) {
			self.actions = actions
			isEnabled = enabled
			tintColor = tint
			if configuration?.title != title { configuration?.title = title }
			let titles = actions.map(\.title)
			if menuTitles != titles {
				menuTitles = titles
				menu = UIMenu(children: titles.map { name in
					UIAction(title: name) { [weak self] _ in self?.performAction(named: name) }
				})
				accessibilityCustomActions = titles.map { name in
					UIAccessibilityCustomAction(name: name) { [weak self] _ in
						guard let self, self.isEnabled else { return false }
						self.performAction(named: name)
						return true
					}
				}
			}
			setNeedsUpdateConfiguration()
		}

		private func performAction(named name: String) {
			selectedAction = true
			actions.first { $0.title == name }?.perform()
		}

		override func updateConfiguration() {
			super.updateConfiguration()
			let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
			let ink = isEnabled ? tintColor : UIColor(EditorTheme.disabledInk)
			configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
				var result = attributes
				result.font = font
				result.foregroundColor = ink
				return result
			}
			setNeedsLayout()
		}

		override func layoutSubviews() {
			super.layoutSubviews()
			let highContrast = traitCollection.accessibilityContrast == .high
			let pressed = isHighlighted || menuVisible
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			face.frame = bounds.insetBy(dx: 2, dy: 2)
			face.colors = [UIColor(pressed ? EditorTheme.faceBottom : EditorTheme.faceTop), UIColor(pressed ? EditorTheme.pressedBottom : EditorTheme.faceBottom)]
				.map { $0.resolvedColor(with: traitCollection).cgColor }
			bevel.frame = face.frame
			bevel.colors = [UIColor.white.withAlphaComponent(pressed ? 0.02 : 0.06).cgColor, UIColor.black.withAlphaComponent(0.04).cgColor]
			bevelMask.frame = bevel.bounds
			bevelMask.path = UIBezierPath(roundedRect: bevel.bounds.insetBy(dx: highContrast ? 2 : 1, dy: highContrast ? 2 : 1), cornerRadius: 4).cgPath
			bevelMask.fillColor = UIColor.clear.cgColor
			bevelMask.strokeColor = UIColor.white.cgColor
			bevelMask.lineWidth = 1
			outline.frame = face.frame
			outline.path = UIBezierPath(roundedRect: outline.bounds.insetBy(dx: 1, dy: 1), cornerRadius: 4).cgPath
			outline.fillColor = UIColor.clear.cgColor
			outline.strokeColor = UIColor(EditorTheme.controlOutline).resolvedColor(with: traitCollection).cgColor
			outline.lineWidth = highContrast ? 2 : 1
			outline.lineDashPattern = isEnabled ? nil : [3, 2]
			CATransaction.commit()
		}

		override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
			selectedAction = false
			returnFocus = UIAccessibility.isVoiceOverRunning
			menuVisible = true
			super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
			setNeedsLayout()
		}

		override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
			super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
			let completion = { [weak self] in
				guard let self else { return }
				self.menuVisible = false
				self.setNeedsLayout()
				defer { self.returnFocus = false }
				guard self.returnFocus, !self.selectedAction, UIAccessibility.isVoiceOverRunning,
					self.window != nil, !self.isHidden, self.isEnabled else { return }
				UIAccessibility.post(notification: .layoutChanged, argument: self)
			}
			if let animator { animator.addCompletion(completion) } else { completion() }
		}
	}
}
