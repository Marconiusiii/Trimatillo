import AVFoundation
import CoreImage

nonisolated struct TransitionVideoLayer {
	let id: CMPersistentTrackID
	let clipID: UUID
	let trackID: String
	let range: CMTimeRange
	let transform: CGAffineTransform
	var generatedImage: CIImage? = nil
	var compositing: ClipCompositing = ClipCompositing()
}

nonisolated final class TransitionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
	let timeRange: CMTimeRange
	let enablePostProcessing = true
	let containsTweening = true
	let passthroughTrackID = kCMPersistentTrackID_Invalid
	let requiredSourceTrackIDs: [NSValue]?
	let layers: [TransitionVideoLayer]
	let effects: [(ProjectTransition, CMTimeRange)]
	let trackOrder: [String]
	let size: CGSize
	let panels: CaptionPanelTimeline?

	init(range: CMTimeRange, layers: [TransitionVideoLayer], project: EditingProject, size: CGSize, panels: CaptionPanelTimeline? = nil) {
		timeRange = range
		self.layers = layers
		self.size = size
		self.panels = panels
		let order = project.tracks.filter { $0.kind == .video }.map(\.id)
		trackOrder = order
		effects = (project.transitions ?? []).compactMap { effect in
			guard order.contains(effect.trackID), let range = effect.range(in: project) else { return nil }
			return (effect, range)
		}
		requiredSourceTrackIDs = layers.map { NSNumber(value: $0.id) }
	}
	init(_ original: TransitionInstruction, panels: CaptionPanelTimeline) {
		timeRange = original.timeRange
		layers = original.layers
		size = original.size
		trackOrder = original.trackOrder
		effects = original.effects
		requiredSourceTrackIDs = original.requiredSourceTrackIDs
		self.panels = panels
	}

}

nonisolated final class TransitionCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
	let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
	let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
		kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		kCVPixelBufferMetalCompatibilityKey as String: true
	]
	private let queue = DispatchQueue(label: "com.marconius.trimato.transitions")
	private let context = CIContext(options: [.cacheIntermediates: false])
	private let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
	private let lock = NSLock()
	private let panels = NSCache<NSData, CIImage>()
	private var generation = 0

	func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

	func cancelAllPendingVideoCompositionRequests() { lock.withLock { generation += 1 } }

	func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
		let current = lock.withLock { generation }
		queue.async { [self] in
			guard lock.withLock({ generation == current }) else { request.finishCancelledRequest(); return }
			autoreleasepool {
				guard let instruction = request.videoCompositionInstruction as? TransitionInstruction,
					let buffer = request.renderContext.newPixelBuffer() else {
					request.finish(with: CocoaError(.fileReadCorruptFile))
					return
				}
				let rect = CGRect(origin: .zero, size: instruction.size)
				let black = CIImage(color: .black).cropped(to: rect)
				func image(_ layer: TransitionVideoLayer?) -> CIImage {
					guard let layer else { return CIImage.empty() }
					if let generated = layer.generatedImage { return layer.compositing.apply(generated, rect: rect) }
					guard let frame = request.sourceFrame(byTrackID: layer.id) else { return CIImage.empty() }
					let source = CIImage(cvPixelBuffer: frame)
					let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: source.extent.height)
					let flipOutput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.height)
					return layer.compositing.apply(source.transformed(by: flipSource.concatenating(layer.transform).concatenating(flipOutput)).cropped(to: rect), rect: rect)
				}
				let time = request.compositionTime
				var result = black
				for track in instruction.trackOrder.reversed() {
					let active = instruction.layers.filter { $0.trackID == track && $0.range.containsTime(time) }
					guard !active.isEmpty else { continue }
					let foreground: CIImage
					if let (effect, range) = instruction.effects.first(where: { $0.0.trackID == track && $0.1.containsTime(time) }) {
						let raw = min(1, max(0, (time - range.start).seconds / range.duration.seconds))
						let progress = effect.style.supportsEase ? effect.ease.progress(raw) : raw
						let outgoing = active.first { $0.clipID == effect.outgoing }
						let incoming = active.first { $0.clipID == effect.incoming }
						foreground = render(effect, outgoing: image(outgoing), incoming: image(incoming), progress: progress, rect: rect)
					} else { foreground = image(active.first) }
					let mode = active.last?.compositing.blend ?? .normal
					result = foreground.applyingFilter(mode.filter, parameters: [kCIInputBackgroundImageKey: result]).cropped(to: rect)
				}
				if let data = instruction.panels?.image(at: time), let panel = panels.object(forKey: data as NSData) ?? CIImage(data: data) {
					panels.countLimit = 3
					panels.setObject(panel, forKey: data as NSData)
					let offset = CGAffineTransform(translationX: (rect.width - panel.extent.width) / 2, y: rect.height * CaptionPanel.bottomFraction)
					result = panel.transformed(by: offset).composited(over: result)
				}
				context.render(result, to: buffer, bounds: rect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
				guard lock.withLock({ generation == current }) else { request.finishCancelledRequest(); return }
				request.finish(withComposedVideoFrame: buffer)
			}
		}
	}

	private func render(_ effect: ProjectTransition, outgoing: CIImage, incoming: CIImage, progress: Double, rect: CGRect) -> CIImage {
		let p = CGFloat(progress)
		let black = CIImage(color: .clear).cropped(to: rect)
		func blend(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
			a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: t]).cropped(to: rect)
		}
		if effect.edge == .intro { return blend(black, incoming, progress) }
		if effect.edge == .outro { return blend(outgoing, black, progress) }
		switch effect.style {
		case .fade, .crossDissolve: return blend(outgoing, incoming, progress)
		case .fadeOutIn, .fadeThroughWhite:
			let middle = effect.style == .fadeThroughWhite ? CIImage(color: .white).cropped(to: rect) : black
			return progress < 0.5 ? blend(outgoing, middle, progress * 2) : blend(middle, incoming, (progress - 0.5) * 2)
		case .circleOpen, .circleClose:
			let radius = hypot(rect.width, rect.height) / 2
			let opening = effect.style == .circleOpen
			let r = opening ? radius * p : radius * (1 - p)
			let mask = CIFilter(name: "CIRadialGradient", parameters: [
				kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY), "inputRadius0": r, "inputRadius1": r + 1,
				"inputColor0": opening ? CIColor.white : CIColor.black, "inputColor1": opening ? CIColor.black : CIColor.white
			])!.outputImage!
			return incoming.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: outgoing, kCIInputMaskImageKey: mask]).cropped(to: rect)
		case .pixelDissolve:
			let random = noise.cropped(to: rect)
				.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 12])
				.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
				.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 1 - progress])
			return incoming.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: outgoing, kCIInputMaskImageKey: random]).cropped(to: rect)
		default:
			let name = effect.style.rawValue
			let dx: CGFloat = name.hasSuffix("Left") ? -1 : name.hasSuffix("Right") ? 1 : 0
			let dy: CGFloat = name.hasSuffix("Up") ? 1 : name.hasSuffix("Down") ? -1 : 0
			if name.hasPrefix("wipe") {
				let width = dx == 0 ? rect.width : rect.width * p
				let height = dy == 0 ? rect.height : rect.height * p
				let reveal = CGRect(x: dx < 0 ? rect.width - width : 0, y: dy < 0 ? rect.height - height : 0, width: width, height: height)
				return incoming.cropped(to: reveal).composited(over: outgoing).cropped(to: rect)
			}
			let shiftedOut = outgoing.transformed(by: .init(translationX: dx * rect.width * p, y: dy * rect.height * p))
			let shiftedIn = incoming.transformed(by: .init(translationX: -dx * rect.width * (1 - p), y: -dy * rect.height * (1 - p)))
			if name.hasPrefix("cover") { return shiftedIn.composited(over: outgoing).cropped(to: rect) }
			if name.hasPrefix("reveal") { return shiftedOut.composited(over: incoming).cropped(to: rect) }
			return shiftedIn.composited(over: shiftedOut).composited(over: black).cropped(to: rect)
		}
	}
}

nonisolated struct TransitionAudioEnvelope {
	let range: CMTimeRange
	let incoming: Bool
	let equalPower: Bool
	func value(at time: CMTime) -> Float {
		let fraction = min(1, max(0, (time - range.start).seconds / range.duration.seconds))
		let progress = incoming ? fraction : 1 - fraction
		return Float(equalPower ? sin(progress * .pi / 2) : progress)
	}
}

extension EditingProject {
	func audioEnvelopes(for clip: ProjectPlacement, channel: String) -> [TransitionAudioEnvelope] {
		transitions(for: clip, channel: channel).compactMap { effect in
			guard var range = effect.range(in: self) else { return nil }
			let incoming = effect.incoming == clip.id
			if effect.edge == .between && !effect.style.extendsMedia {
				let middle = range.start + CMTimeMultiplyByFloat64(range.duration, multiplier: 0.5)
				range = incoming ? CMTimeRange(start: middle, end: range.end) : CMTimeRange(start: range.start, end: middle)
			}
			return TransitionAudioEnvelope(range: range, incoming: incoming, equalPower: effect.equalPower)
		}
	}
}

// Build a single volume schedule before installing any AVFoundation ramps.
nonisolated struct AudioVolumeRamp {
	let range: CMTimeRange
	let start: Float
	let end: Float

	func value(at time: CMTime) -> Float {
		guard range.duration > .zero else { return end }
		let progress = Float(min(1, max(0, (time - range.start).seconds / range.duration.seconds)))
		return start + (end - start) * progress
	}
}

nonisolated enum TransitionAudioSchedule {
	static func ramps(_ envelopes: [TransitionAudioEnvelope], base: Float,
		ducking: [AudioVolumeRamp], duration: CMTime) -> [AudioVolumeRamp] {
		guard duration.isNumeric, duration > .zero else { return [] }
		// Binary ticks also remain exact when AVFoundation converts times to seconds.
		// Reuse each boundary for both adjacent ramps rather than rounding their ends independently.
		let scale: CMTimeScale = 1_048_576
		func ticks(_ time: CMTime) -> Int64 {
			CMTimeConvertScale(time, timescale: scale, method: .roundHalfAwayFromZero).value
		}
		let end = ticks(duration)
		guard end > 0 else { return [] }
		let fades = envelopes.filter { $0.range.start.isNumeric && $0.range.duration.isNumeric && $0.range.duration > .zero }
		let ducks = ducking.filter { $0.range.start.isNumeric && $0.range.duration.isNumeric && $0.range.duration >= .zero }
			.sorted { $0.range.start < $1.range.start }
		var boundaries: Set<Int64> = [0, end]
		for range in fades.map(\.range) + ducks.map(\.range) {
			let first = max(0, min(end, ticks(range.start)))
			let last = max(first, min(end, ticks(range.end)))
			boundaries.insert(first)
			boundaries.insert(last)
			let steps = max(1, Int(min(512, ceil(Double(last - first) / Double(scale) * 60))))
			for step in 1..<steps {
				boundaries.insert(first + (last - first) * Int64(step) / Int64(steps))
			}
		}
		let ordered = boundaries.sorted()
		return zip(ordered, ordered.dropFirst()).map { first, last in
			let start = CMTime(value: first, timescale: scale)
			let stop = CMTime(value: last, timescale: scale)
			let middle = CMTime(value: first + last, timescale: scale * 2)
			let active = fades.filter { $0.range.containsTime(middle) }
			let duck = ducks.last { $0.range.start <= middle }
			func volume(_ time: CMTime) -> Float {
				let value = active.reduce(base * (duck?.value(at: time) ?? 1)) { $0 * $1.value(at: time) }
				return value.isFinite ? min(1, max(0, value)) : 0
			}
			return AudioVolumeRamp(range: CMTimeRange(start: start, duration: CMTime(value: last - first, timescale: scale)),
				start: volume(start), end: volume(stop))
		}
	}
}

extension AVMutableAudioMixInputParameters {
	// Call on fresh parameters; volume, ducking, and transitions are installed together.
	func applyTransitions(_ envelopes: [TransitionAudioEnvelope], base: Float,
		ducking: [AudioVolumeRamp] = [], duration: CMTime) {
		let ramps = TransitionAudioSchedule.ramps(envelopes, base: base, ducking: ducking, duration: duration)
		if ramps.isEmpty { setVolume(base, at: .zero); return }
		for ramp in ramps {
			setVolumeRamp(fromStartVolume: ramp.start, toEndVolume: ramp.end, timeRange: ramp.range)
		}
	}
}
