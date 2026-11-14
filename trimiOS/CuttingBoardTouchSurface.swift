import SwiftUI
import AVFoundation
import UIKit

extension DirectTouchScrubbing {
	func time(at x: CGFloat, width: CGFloat, startX: CGFloat, origin: CMTime, duration: CMTime) -> CMTime {
		guard width > 0 else { return origin }
		let fraction = Double(min(width, max(0, x)) / width)
		switch self {
		case .absolute:
			if fraction == 0 { return .zero }
			if fraction == 1 { return duration }
			return CMTime(seconds: fraction * duration.seconds, preferredTimescale: 600000)
		case .relative:
			let delta = (fraction - Double(startX / width)) * min(10, duration.seconds)
			let time = origin + CMTime(seconds: delta, preferredTimescale: 600000)
			return min(duration, max(.zero, time))
		}
	}
}

struct CuttingBoardTouchSurface: UIViewRepresentable {
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal
	@AppStorage("directTouchScrubbing", store: EditorPreferences.shared) private var scrubbing = DirectTouchScrubbing.absolute
	let session: CuttingBoardSession
	let onClose: (() -> Void)?

	func makeUIView(context: Context) -> TimelineSurface { TimelineSurface(session, onClose: onClose) }
	func updateUIView(_ view: TimelineSurface, context: Context) {
		view.controlColor = color
		view.scrubbing = scrubbing
		view.updatePosition()
	}
}

final class TimelineSurface: UIView {
	let session: CuttingBoardSession
	private let video = AVPlayerLayer()
	private let selection = CALayer()
	private let cursor = CALayer()
	private var origin: CMTime = .zero
	private let onClose: (() -> Void)?
	var scrubbing = DirectTouchScrubbing.absolute
	private var scrubStartX: CGFloat = 0
	private var scrubGeneration: Int?
	private var previousSize = CGSize.zero

	init(_ session: CuttingBoardSession, onClose: (() -> Void)?) {
		self.onClose = onClose
		self.session = session
		super.init(frame: .zero)
		isAccessibilityElement = true
		accessibilityLabel = onClose == nil ? "Clip preview" : "Direct Touch Editor"
		accessibilityTraits = onClose == nil ? [.image] : [.allowsDirectInteraction]
		layer.cornerRadius = 0
		layer.masksToBounds = true
		video.player = session.hasVideo ? session.player : nil
		video.videoGravity = .resizeAspect
		layer.addSublayer(video)
		layer.addSublayer(selection)
		layer.addSublayer(cursor)
		applyColors()
		registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: TimelineSurface, _: UITraitCollection) in
			view.applyColors()
		}

		guard onClose != nil else { return }
		accessibilityDirectTouchOptions = [.silentOnTouch]
		isMultipleTouchEnabled = true

		let closeTap = UITapGestureRecognizer(target: self, action: #selector(closeEditor))
		closeTap.numberOfTapsRequired = 3
		addGestureRecognizer(closeTap)

		let joinTap = UITapGestureRecognizer(target: self, action: #selector(openJoin))
		joinTap.numberOfTapsRequired = 2
		joinTap.require(toFail: closeTap)
		addGestureRecognizer(joinTap)

		let hold = UILongPressGestureRecognizer(target: self, action: #selector(scrub(_:)))
		hold.numberOfTapsRequired = 1
		hold.minimumPressDuration = 0.35
		joinTap.require(toFail: hold)
		closeTap.require(toFail: hold)
		addGestureRecognizer(hold)
		for (count, directions) in [(1, [UISwipeGestureRecognizer.Direction.left, .right, .up, .down]),
			(2, [.left, .right, .down]),
			(3, [.left, .right, .down, .up]), (4, [.left, .right])] {
			for direction in directions {
				let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:)))
				swipe.numberOfTouchesRequired = count
				swipe.direction = direction
				if count == 1 { swipe.require(toFail: hold) }
				addGestureRecognizer(swipe)
			}
		}
		let tap = UITapGestureRecognizer(target: self, action: #selector(toggle))
		tap.numberOfTouchesRequired = 2
		tap.numberOfTapsRequired = 2
		addGestureRecognizer(tap)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	@objc private func openJoin() { session.showJoin() }

	@objc private func closeEditor() { onClose?() }

	var controlColor = ControlColor.teal {
		didSet { if oldValue != controlColor { applyColors() } }
	}

	private func applyColors() {
		backgroundColor = UIColor(EditorTheme.surface)
		cursor.backgroundColor = UIColor(EditorTheme.playhead).resolvedColor(with: traitCollection).cgColor
		selection.backgroundColor = UIColor(controlColor.selection).resolvedColor(with: traitCollection).withAlphaComponent(0.65).cgColor
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		if bounds.size != previousSize {
			for gesture in gestureRecognizers ?? [] where gesture.state == .began || gesture.state == .changed || gesture.numberOfTouches > 0 {
				gesture.isEnabled = false
				gesture.isEnabled = true
			}
			previousSize = bounds.size
		}
		updatePosition()
	}

	func updatePosition() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		video.frame = bounds
		func x(_ time: CMTime) -> CGFloat { bounds.width * CGFloat(time.seconds / session.duration.seconds) }
		cursor.frame = CGRect(x: min(max(0, bounds.width - 3), x(session.position)), y: 0, width: 3, height: bounds.height)
		if let range = session.selection {
			selection.frame = CGRect(x: x(range.start), y: bounds.height - 12, width: x(range.duration), height: 12)
		} else { selection.frame = .zero }
		CATransaction.commit()
	}

	@objc private func scrub(_ hold: UILongPressGestureRecognizer) {
		let x = hold.location(in: self).x
		func target() -> CMTime {
			scrubbing.time(at: x, width: bounds.width, startX: scrubStartX, origin: origin, duration: session.duration)
		}
		switch hold.state {
		case .began:
			let generation = session.beginScrub()
			scrubGeneration = generation
			scrubStartX = x
			origin = session.position
			session.scrub(to: target(), generation: generation, initial: true)
		case .changed:
			guard let generation = scrubGeneration else { return }
			session.scrub(to: target(), generation: generation)
		case .ended:
			guard let generation = scrubGeneration else { return }
			session.endScrub(at: target(), generation: generation)
			scrubGeneration = nil
		case .cancelled, .failed:
			if let generation = scrubGeneration {
				session.endScrub(at: session.position, generation: generation)
				scrubGeneration = nil
			}
		default: break
		}
	}

	@objc private func swipe(_ gesture: UISwipeGestureRecognizer) {
		let right = gesture.direction == .right
		switch gesture.numberOfTouchesRequired {
		case 1:
			switch gesture.direction {
			case .left: session.step(-1)
			case .right: session.step(1)
			case .down: session.mark(true, toggleAtPlayhead: true)
			case .up: session.mark(false, toggleAtPlayhead: true)
			default: break
			}
		case 2:
			if gesture.direction == .down { session.delete(session.selection, spoken: true) }
			else { session.shuttle(right ? 1 : -1) }
		case 3:
			if gesture.direction == .down { session.undo() }
			else if gesture.direction == .up { session.redo() }
			else { session.navigate(right, spoken: true) }
		case 4: session.trim(head: right, spoken: true)
		default: break
		}
	}

	@objc private func toggle() { session.toggle() }
	override func accessibilityPerformMagicTap() -> Bool { toggle(); return true }
}
