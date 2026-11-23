import AVFoundation
import CoreImage
import CoreText
import UIKit

nonisolated struct GeneratorDefinition: Codable, Equatable {
	enum Kind: String, Codable, CaseIterable { case text = "Text", black = "Black", color = "Solid Color", gradient = "Gradient", silence = "Silence" }
	enum Preset: String, Codable, CaseIterable {
		case title = "Centered Title", subtitle = "Title and Subheading", lowerLeft = "Lower Third Left", lowerCenter = "Lower Third Center", lowerRight = "Lower Third Right", name = "Name and Role", subtitles = "Subtitle"
	}
	enum Font: String, Codable, CaseIterable { case sans = "Sans Serif", serif = "Serif", mono = "Monospace" }
	enum Position: String, Codable, CaseIterable {
		case topLeft = "Top Left", top = "Top Center", topRight = "Top Right", left = "Center Left", center = "Center", right = "Center Right", bottomLeft = "Bottom Left", bottom = "Bottom Center", bottomRight = "Bottom Right"
		var x: Double { [.topLeft, .left, .bottomLeft].contains(self) ? -1 : [.topRight, .right, .bottomRight].contains(self) ? 1 : 0 }
		var y: Double { [.topLeft, .top, .topRight].contains(self) ? 1 : [.bottomLeft, .bottom, .bottomRight].contains(self) ? -1 : 0 }
	}
	var kind = Kind.text
	var preset = Preset.title
	var text = ""
	var subheading = ""
	var seconds = 5.0
	var picture = ProjectPicture(width: 1920, height: 1080, frame: ProjectTime(CMTime(value: 1, timescale: 30)))
	var foreground = GeneratorColor.white
	var background = GeneratorColor.black
	var secondColor = GeneratorColor.blue
	var transparent = true
	var verticalGradient = true
	var font = Font.sans
	var bold = true
	var fontSize = 8.0
	var position = Position.center
	var margin = 5.0
	var width = 90.0
	var lineSpacing = 1.0
	var outline = true
	var shadow = false
	var panel = false
	var panelOpacity = 70.0
	var isValid: Bool {
		seconds.isFinite && (0.01...86400).contains(seconds) && (2...8192).contains(picture.width) && (2...8192).contains(picture.height)
			&& picture.frame.time.isNumeric && picture.frame.time > .zero && picture.frame.time.seconds >= 1 / 1000
			&& text.utf8.count <= 20000 && subheading.utf8.count <= 20000 && foreground.isValid && background.isValid && secondColor.isValid
			&& (1...30).contains(fontSize) && (0...25).contains(margin) && (10...100).contains(width)
			&& (0.5...3).contains(lineSpacing) && (0...100).contains(panelOpacity)
	}
	mutating func apply(_ preset: Preset) {
		self.preset = preset
		fontSize = preset == .title || preset == .subtitle ? 8 : 4.5
		position = preset == .lowerLeft || preset == .name ? .bottomLeft : preset == .lowerRight ? .bottomRight : preset == .lowerCenter || preset == .subtitles ? .bottom : .center
		transparent = true
		bold = preset != .subtitles
		outline = true
	}
	var source: ProjectMediaSource {
		ProjectMediaSource(name: kind == .text ? preset.rawValue : kind.rawValue, reference: .generated(self), duration: ProjectTime(seconds: seconds), picture: kind == .silence ? nil : picture, hasAudio: kind == .silence)
	}
}

nonisolated struct GeneratorColor: Codable, Equatable {
	var red: Double
	var green: Double
	var blue: Double
	static let white = Self(red: 1, green: 1, blue: 1)
	static let black = Self(red: 0, green: 0, blue: 0)
	static let blue = Self(red: 0.1, green: 0.3, blue: 0.9)
	var isValid: Bool { [red, green, blue].allSatisfy { (0...1).contains($0) } }
	var cg: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
	var ci: CIColor { CIColor(red: red, green: green, blue: blue) }
}

nonisolated struct ClipCompositing: Codable, Equatable {
	enum Blend: String, Codable, CaseIterable {
		case normal = "Normal", multiply = "Multiply", screen = "Screen", overlay = "Overlay"
		var filter: String { switch self { case .normal: "CISourceOverCompositing"; case .multiply: "CIMultiplyBlendMode"; case .screen: "CIScreenBlendMode"; case .overlay: "CIOverlayBlendMode" } }
	}
	var opacity = 100.0
	var scale = 100.0
	var horizontal = 0.0
	var vertical = 0.0
	var position = GeneratorDefinition.Position.center
	var blend = Blend.normal
	var isValid: Bool { (0...100).contains(opacity) && (1...400).contains(scale) && (-100...100).contains(horizontal) && (-100...100).contains(vertical) }
	func apply(_ image: CIImage, rect: CGRect) -> CIImage {
		let s = scale / 100
		let x = (rect.width - rect.width * s) / 2 * (1 + position.x) + horizontal / 100 * rect.width
		let y = (rect.height - rect.height * s) / 2 * (1 + position.y) + vertical / 100 * rect.height
		return image.transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(.init(translationX: x, y: y)))
			.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity / 100)]).cropped(to: rect)
	}
}

private actor GeneratorAssetCache {
	static let shared = GeneratorAssetCache()
	private var entries: [(GeneratorDefinition, ProjectMediaAccess)] = []
	func get(_ definition: GeneratorDefinition) -> ProjectMediaAccess? { entries.first { $0.0 == definition }?.1 }
	func put(_ definition: GeneratorDefinition, access: ProjectMediaAccess) {
		entries.removeAll { $0.0 == definition }
		entries.append((definition, access))
		if entries.count > 4 { entries.removeFirst(entries.count - 4) }
	}
}

nonisolated enum GeneratorRenderer {
	@concurrent static func preparedImage(_ definition: GeneratorDefinition, size: CGSize) async throws -> CIImage {
		try Task.checkCancellation()
		return try image(definition, size: size)
	}
	static func image(_ definition: GeneratorDefinition, size: CGSize? = nil) throws -> CIImage {
		guard definition.isValid else { throw ProjectFailure("Could not create the clip. Check its duration and appearance settings.") }
		let size = size ?? CGSize(width: definition.picture.width, height: definition.picture.height)
		let rect = CGRect(origin: .zero, size: size)
		switch definition.kind {
		case .black, .silence: return CIImage(color: .black).cropped(to: rect)
		case .color: return CIImage(color: definition.background.ci).cropped(to: rect)
		case .gradient:
			return CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: definition.verticalGradient ? rect.height : 0),
				"inputPoint1": CIVector(x: definition.verticalGradient ? 0 : rect.width, y: 0), "inputColor0": definition.background.ci, "inputColor1": definition.secondColor.ci])!.outputImage!.cropped(to: rect)
		case .text: break
		}
		guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteOutOfSpace) }
		if !definition.transparent { context.setFillColor(definition.background.cg); context.fill(rect) }
		let fontName: String = switch definition.font {
		case .sans: definition.bold ? "Helvetica-Bold" : "Helvetica"
		case .serif: definition.bold ? "Georgia-Bold" : "Georgia"
		case .mono: definition.bold ? "Courier-Bold" : "Courier"
		}
		let fontSize = size.height * definition.fontSize / 100
		let paragraph = NSMutableParagraphStyle()
		paragraph.alignment = definition.position.x < 0 ? .left : definition.position.x > 0 ? .right : .center
		paragraph.lineHeightMultiple = definition.lineSpacing
		var attributes: [NSAttributedString.Key: Any] = [.font: CTFontCreateWithName(fontName as CFString, fontSize, nil), .foregroundColor: definition.foreground.cg, .paragraphStyle: paragraph]
		if definition.outline { attributes[.strokeColor] = GeneratorColor.black.cg; attributes[.strokeWidth] = -3 }
		let text = NSMutableAttributedString(string: definition.text, attributes: attributes)
		if [.subtitle, .name].contains(definition.preset), !definition.subheading.isEmpty {
			attributes[.font] = CTFontCreateWithName(fontName as CFString, fontSize * 0.6, nil)
			text.append(NSAttributedString(string: "\n" + definition.subheading, attributes: attributes))
		}
		let setter = CTFramesetterCreateWithAttributedString(text)
		let inset = min(size.width, size.height) * definition.margin / 100
		let width = min(size.width - inset * 2, size.width * definition.width / 100)
		let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: size.height - inset * 2), nil)
		let height = min(size.height - inset * 2, ceil(measured.height) + fontSize * 0.2)
		let x = inset + (size.width - inset * 2 - width) * (definition.position.x + 1) / 2
		let y = inset + (size.height - inset * 2 - height) * (definition.position.y + 1) / 2
		let textRect = CGRect(x: x, y: y, width: width, height: height)
		if definition.panel { context.setFillColor(definition.background.cg.copy(alpha: definition.panelOpacity / 100)!); context.fill(textRect.insetBy(dx: -fontSize * 0.2, dy: -fontSize * 0.1)) }
		if definition.shadow { context.setShadow(offset: CGSize(width: fontSize * 0.05, height: -fontSize * 0.05), blur: fontSize * 0.1, color: GeneratorColor.black.cg) }
		CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: textRect, transform: nil), nil), context)
		guard let output = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
		return CIImage(cgImage: output)
	}

	@concurrent static func access(_ definition: GeneratorDefinition) async throws -> ProjectMediaAccess {
		guard definition.isValid else { throw CocoaError(.fileReadCorruptFile) }
		if let cached = await GeneratorAssetCache.shared.get(definition) { return cached }
		let file = try ExportFile(name: "Generated Clip", suffix: definition.kind == .silence ? "caf" : "mov")
		if definition.kind == .silence {
			let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
			let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
			for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 48000) }
			let output = try AVAudioFile(forWriting: file.url, settings: [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16])
			var remaining = Int64((definition.seconds * 48000).rounded(.up))
			while remaining > 0 {
				try Task.checkCancellation()
				buffer.frameLength = AVAudioFrameCount(min(48000, remaining))
				try output.write(from: buffer)
				remaining -= Int64(buffer.frameLength)
			}
			output.close()
		} else {
			// A short carrier supplies sample timing; the project compositor draws the original transparent image.
			let width = definition.picture.width + definition.picture.width % 2
			let height = definition.picture.height + definition.picture.height % 2
			let writer = try AVAssetWriter(outputURL: file.url, fileType: .mov)
			let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
			let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
			writer.add(input)
			guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
			writer.startSession(atSourceTime: .zero)
			do {
				var pixel: CVPixelBuffer?
				guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw CocoaError(.fileWriteOutOfSpace) }
				let bounds = CGRect(x: 0, y: 0, width: width, height: height)
				let image = try image(definition, size: bounds.size).composited(over: CIImage(color: .black)).cropped(to: bounds)
				CIContext().render(image, to: pixel, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
				for index in 0..<2 {
					while !input.isReadyForMoreMediaData {
						try Task.checkCancellation()
						guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
						try await Task.sleep(for: .milliseconds(5))
					}
					guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
				}
				writer.endSession(atSourceTime: CMTime(value: 2, timescale: 30))
				input.markAsFinished()
				await writer.finishWriting()
				guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
			} catch { writer.cancelWriting(); throw error }
		}
		try Task.checkCancellation()
		let asset = AVURLAsset(url: file.url)
		if definition.kind == .silence {
			let access = ProjectMediaAccess(asset: asset, generatedFile: file)
			await GeneratorAssetCache.shared.put(definition, access: access)
			return access
		}
		let type: AVMediaType = .video
		guard let input = try await asset.loadTracks(withMediaType: type).first else { throw CocoaError(.fileReadCorruptFile) }
		let range = try await input.load(.timeRange)
		let composition = AVMutableComposition()
		guard let output = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.featureUnsupported) }
		try output.insertTimeRange(range, of: input, at: .zero)
		output.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: ProjectTime(seconds: definition.seconds).time)
		let access = ProjectMediaAccess(asset: composition, generatedFile: file)
		try Task.checkCancellation()
		await GeneratorAssetCache.shared.put(definition, access: access)
		return access
	}
}
