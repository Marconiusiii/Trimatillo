import SwiftUI
import AVFoundation
import UIKit

struct CuttingBoardTouchSurface: UIViewRepresentable {
	let session: CuttingBoardSession

	func makeUIView(context: Context) -> TimelineSurface { TimelineSurface(session) }
	func updateUIView(_ view: TimelineSurface, context: Context) {
		view.updatePosition()
	}
}

final class TimelineSurface: UIView {
	let session: CuttingBoardSession
	private let video = AVPlayerLayer()
	private let selection = CALayer()
	private let cursor = CALayer()
	private var origin: CMTime = .zero
	private var horizontal: Bool?
	private var previousSize = CGSize.zero
	private var lastScrub = -Double.infinity

	init(_ session: CuttingBoardSession) {
		self.session = session
		super.init(frame: .zero)
		isAccessibilityElement = true
		accessibilityLabel = "Clip timeline"
		accessibilityTraits = [.allowsDirectInteraction]
		accessibilityDirectTouchOptions = [.requiresActivation, .silentOnTouch]
		isMultipleTouchEnabled = true
		layer.cornerRadius = 12
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

		let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
		pan.maximumNumberOfTouches = 1
		addGestureRecognizer(pan)
		for (count, directions) in [(2, [UISwipeGestureRecognizer.Direction.left, .right, .down]),
			(3, [.left, .right]), (4, [.left, .right])] {
			for direction in directions {
				let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:)))
				swipe.numberOfTouchesRequired = count
				swipe.direction = direction
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

	private func applyColors() {
		backgroundColor = UIColor(EditorTheme.surface)
		cursor.backgroundColor = UIColor(EditorTheme.playhead).resolvedColor(with: traitCollection).cgColor
		selection.backgroundColor = UIColor(EditorTheme.selection).resolvedColor(with: traitCollection).withAlphaComponent(0.65).cgColor
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		if bounds.size != previousSize {
			for gesture in gestureRecognizers ?? [] where gesture.state == .began || gesture.state == .changed || gesture.state == .possible {
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
		accessibilityValue = session.positionLabel
	}

	@objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
		let offset = gesture.translation(in: self)
		if gesture.state == .began {
			horizontal = abs(offset.x) > abs(offset.y)
			if horizontal == true { session.stop() }
			origin = session.position
			lastScrub = -.infinity
		}
		guard gesture.state == .began || gesture.state == .changed || gesture.state == .ended else { return }
		if horizontal == true {
			let now = CACurrentMediaTime()
			guard now - lastScrub >= 0.075 || gesture.state == .ended else { return }
			lastScrub = now
			let delta = Double(offset.x / max(1, bounds.width)) * min(10, session.duration.seconds)
			session.seek(origin + CMTime(seconds: delta, preferredTimescale: 600000), audible: true)
		} else if gesture.state == .ended, abs(offset.y) >= 28 {
			session.mark(offset.y > 0)
		}
	}

	@objc private func swipe(_ gesture: UISwipeGestureRecognizer) {
		let right = gesture.direction == .right
		switch gesture.numberOfTouchesRequired {
		case 2:
			if gesture.direction == .down { session.delete(session.selection) }
			else { session.shuttle(right ? 1 : -1) }
		case 3: session.navigate(right)
		case 4: session.trim(head: right)
		default: break
		}
	}

	@objc private func toggle() { session.toggle() }
	override func accessibilityPerformMagicTap() -> Bool { toggle(); return true }
}
