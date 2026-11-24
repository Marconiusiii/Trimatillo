import AVFoundation
import CoreImage
import CoreText

private let linear2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
private let hlg2020 = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
private let colorProperties: [String: Any] = [
	AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
	AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
	AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
]

final class HDRInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
	let timeRange: CMTimeRange
	let enablePostProcessing = false
	let containsTweening = true
	let requiredSourceTrackIDs: [NSValue]?
	let passthroughTrackID = kCMPersistentTrackID_Invalid
	let ids: [CMPersistentTrackID]
	init(range: CMTimeRange, ids: [CMPersistentTrackID]) {
		timeRange = range
		self.ids = ids
		requiredSourceTrackIDs = ids.map { NSNumber(value: $0) }
	}
}

final class HDRCompositor: NSObject, AVVideoCompositing {
	let supportsHDRSourceFrames = true
	let supportsWideColorSourceFrames = true
	let sourcePixelBufferAttributes: [String: any Sendable]? = [
		kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
	]
	let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
		kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
		kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
	]
	private let context = CIContext(options: [.workingColorSpace: linear2020, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
	private let queue = DispatchQueue(label: "Trimatillo.HDRPrototype")
	private let overlay: CIImage = {
		let space = CGColorSpace(name: CGColorSpace.sRGB)!
		let bitmap = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
			bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		for (text, y) in [("Generated title", 145.0), ("Burned-in caption", 12.0)] {
			let string = NSAttributedString(string: text, attributes: [
				NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil),
				NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
			])
			bitmap.textPosition = CGPoint(x: 16, y: y)
			CTLineDraw(CTLineCreateWithAttributedString(string), bitmap)
		}
		return CIImage(cgImage: bitmap.makeImage()!, options: [.colorSpace: space])
	}()

	func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
	func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
		queue.async {
			autoreleasepool {
				guard let instruction = request.videoCompositionInstruction as? HDRInstruction,
					let buffer = request.renderContext.newPixelBuffer() else {
					request.finish(with: ProbeFailure("Missing HDR render buffer or instruction")); return
				}
				let frames = instruction.ids.compactMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
				guard var result = frames.first else { request.finish(with: ProbeFailure("Missing HDR source frame")); return }
				if frames.count == 2 {
					let fraction = (request.compositionTime - instruction.timeRange.start).seconds / instruction.timeRange.duration.seconds
					result = result.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: frames[1], kCIInputTimeKey: fraction])
				}
				let size = request.renderContext.size
				result = self.overlay.transformed(by: CGAffineTransform(scaleX: size.width / 320, y: size.height / 180)).composited(over: result)
				CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
				CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
				CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
				self.context.render(result, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: hlg2020)
				request.finish(withComposedVideoFrame: buffer)
			}
		}
	}
}

enum HDRProbe {
	static func camera(_ source: URL, root: URL) async throws {
		let asset = AVURLAsset(url: source)
		let track = try await asset.loadTracks(withMediaType: .video)[0]
		let size = try await track.load(.naturalSize)
		let transform = try await track.load(.preferredTransform)
		try require(transform.isIdentity, "Camera probe currently requires an unrotated landscape video")
		let frame = try await track.load(.minFrameDuration)
		try require(frame.isNumeric && frame.seconds > 0, "Missing camera frame timing")
		let composition = AVMutableComposition()
		let first = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
		let second = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
		let time: (Double) -> CMTime = { CMTimeMultiply(frame, multiplier: Int32(($0 / frame.seconds).rounded())) }
		let half = time(0.5)
		let secondTime = time(1)
		try first.insertTimeRange(CMTimeRange(start: time(0.25), duration: secondTime), of: track, at: .zero)
		try second.insertTimeRange(CMTimeRange(start: secondTime, duration: secondTime), of: track, at: half)
		var config = AVVideoComposition.Configuration()
		config.customVideoCompositorClass = HDRCompositor.self
		config.perFrameHDRDisplayMetadataPolicy = .generate
		config.renderSize = size
		config.frameDuration = frame
		config.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
		config.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
		config.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
		config.instructions = [
			HDRInstruction(range: CMTimeRange(start: .zero, duration: half), ids: [first.trackID]),
			HDRInstruction(range: CMTimeRange(start: half, end: secondTime), ids: [first.trackID, second.trackID]),
			HDRInstruction(range: CMTimeRange(start: secondTime, duration: half), ids: [second.trackID])
		]
		let destination = root.appendingPathComponent("camera-hdr-edited.mov")
		guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else { throw ProbeFailure("Camera HDR export unavailable") }
		exporter.videoComposition = AVVideoComposition(configuration: config)
		try await exporter.export(to: destination, as: .mov)
		let result = AVURLAsset(url: destination)
		let outputTrack = try await result.loadTracks(withMediaType: .video)[0]
		let format = try await outputTrack.load(.formatDescriptions)[0]
		let properties = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
		try require(properties[kCMFormatDescriptionExtension_TransferFunction] as? String == AVVideoTransferFunction_ITU_R_2100_HLG, "Camera HDR transfer function lost")
		try require(properties[kCMFormatDescriptionExtension_ColorPrimaries] as? String == AVVideoColorPrimaries_ITU_R_2020, "Camera HDR primaries lost")
		try require(properties["BitsPerComponent"] as? Int == 10, "Camera HDR bit depth lost")
		try require(try await outputTrack.load(.naturalSize) == size, "Camera resolution changed")
		try require(abs(try await result.load(.duration).seconds - (secondTime + half).seconds) < frame.seconds / 2, "Camera edit duration changed")
		let reader = try AVAssetReader(asset: result)
		let output = AVAssetReaderTrackOutput(track: outputTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
		reader.add(output)
		try require(reader.startReading(), "Cannot decode edited camera HDR")
		let context = CIContext(options: [.workingColorSpace: linear2020])
		var count = 0
		var peak: Float = 0
		while let sample = output.copyNextSampleBuffer() {
			guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw ProbeFailure("Missing edited camera frame") }
			let image = CIImage(cvPixelBuffer: pixel)
			let area = CGRect(x: size.width * 0.2, y: size.height * 0.3, width: size.width * 0.6, height: size.height * 0.4)
			let maximum = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: area)])
			var values = [Float](repeating: 0, count: 4)
			values.withUnsafeMutableBytes { bytes in
				context.render(maximum, toBitmap: bytes.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear2020)
			}
			try require(values.allSatisfy { $0.isFinite }, "Nonfinite HDR pixels")
			peak = max(peak, values[0], values[1], values[2])
			count += 1
		}
		try require(reader.status == .completed, "Camera HDR output failed to decode")
		try require(count == Int(((secondTime + half).seconds / frame.seconds).rounded()), "Camera HDR output frame count changed")
		print("PASS camera HDR: \(Int(size.width))x\(Int(size.height)), \(count) frames, \(1 / frame.seconds) fps, 10-bit HLG/BT.2020; central image peak=\(peak)")
	}

	static func run(_ root: URL) async throws {
		let source = root.appendingPathComponent("hdr-source.mov")
		let output = root.appendingPathComponent("hdr-edited.mov")
		try await fixture(source)
		let asset = AVURLAsset(url: source)
		let sourceTrack = try await asset.loadTracks(withMediaType: .video)[0]
		let composition = AVMutableComposition()
		let first = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
		let second = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
		let time: (Double) -> CMTime = { CMTime(seconds: $0, preferredTimescale: 24) }
		try first.insertTimeRange(CMTimeRange(start: time(0.25), duration: time(1)), of: sourceTrack, at: .zero)
		try second.insertTimeRange(CMTimeRange(start: time(1), duration: time(1)), of: sourceTrack, at: time(0.5))
		var video = AVVideoComposition.Configuration()
		video.customVideoCompositorClass = HDRCompositor.self
		video.perFrameHDRDisplayMetadataPolicy = .generate
		video.renderSize = CGSize(width: 320, height: 180)
		video.frameDuration = CMTime(value: 1, timescale: 24)
		video.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
		video.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
		video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
		video.instructions = [
			HDRInstruction(range: CMTimeRange(start: .zero, duration: time(0.5)), ids: [first.trackID]),
			HDRInstruction(range: CMTimeRange(start: time(0.5), duration: time(0.5)), ids: [first.trackID, second.trackID]),
			HDRInstruction(range: CMTimeRange(start: time(1), duration: time(0.5)), ids: [second.trackID])
		]
		guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
			throw ProbeFailure("HEVC exporter unavailable")
		}
		exporter.videoComposition = AVVideoComposition(configuration: video)
		try await exporter.export(to: output, as: .mov)
		try await inspect(output)
		try await verify(source, expectedDuration: 2)
		try await verify(output, expectedDuration: 1.5)
		print("PASS: HDR cut, dissolve, title and caption retain HLG/BT.2020 and decoded highlight headroom")
	}

	static func fixture(_ url: URL) async throws {
		let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
		let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
			AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
			AVVideoColorPropertiesKey: colorProperties,
			AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel"]
		])
		let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
			kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
			kCVPixelBufferIOSurfacePropertiesKey as String: [:]
		])
		writer.add(input)
		try require(writer.startWriting(), "Cannot start HDR fixture writer: \(String(describing: writer.error))")
		writer.startSession(atSourceTime: .zero)
		let context = CIContext(options: [.workingColorSpace: linear2020])
		for frame in 0..<48 {
			try await ready(input, writer: writer)
			var pixel: CVPixelBuffer?
			try require(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel) == kCVReturnSuccess, "Cannot allocate HDR fixture buffer")
			let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
			let base = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, colorSpace: linear2020)!).cropped(to: bounds)
			let light: CGFloat = frame < 24 ? 4 : 2
			let patch = CIImage(color: CIColor(red: light, green: light, blue: light, colorSpace: linear2020)!).cropped(to: CGRect(x: 160, y: 0, width: 160, height: 180))
			context.render(patch.composited(over: base), to: pixel!, bounds: bounds, colorSpace: hlg2020)
			try require(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)), "HDR fixture append failed")
		}
		input.markAsFinished()
		try await finish(writer)
	}

	static func verify(_ url: URL, expectedDuration: Double) async throws {
		let asset = AVURLAsset(url: url)
		try require(abs(try await asset.load(.duration).seconds - expectedDuration) < 0.05, "HDR duration changed")
		let track = try await asset.loadTracks(withMediaType: .video)[0]
		let format = try await track.load(.formatDescriptions)[0]
		let extensions = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
		try require(extensions[kCMFormatDescriptionExtension_TransferFunction] as? String == AVVideoTransferFunction_ITU_R_2100_HLG, "HDR transfer function lost")
		try require(extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String == AVVideoColorPrimaries_ITU_R_2020, "BT.2020 primaries lost")
		let reader = try AVAssetReader(asset: asset)
		let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
		reader.add(output)
		try require(reader.startReading(), "Cannot decode HDR output")
		let context = CIContext(options: [.workingColorSpace: linear2020])
		var count = 0
		var low = Float.greatestFiniteMagnitude
		var dissolveSample: Float?
		var textPeak: Float = 0
		while let sample = output.copyNextSampleBuffer() {
			guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw ProbeFailure("No HDR decoded image") }
			let image = CIImage(cvPixelBuffer: pixel)
			var values = [Float](repeating: 0, count: 4)
			values.withUnsafeMutableBytes { bytes in
				context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 16, bounds: CGRect(x: 240, y: 90, width: 1, height: 1), format: .RGBAf, colorSpace: linear2020)
			}
			low = min(low, values[0])
			if count == 16 { dissolveSample = values[0] }
			if count == 0 {
				var text = [Float](repeating: 0, count: 140 * 24 * 4)
				for y in [10, 140] {
					text.withUnsafeMutableBytes { bytes in
						context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 140 * 16,
							bounds: CGRect(x: 16, y: y, width: 140, height: 24), format: .RGBAf, colorSpace: linear2020)
					}
					let peak = stride(from: 0, to: text.count, by: 4).map { text[$0] }.max() ?? 0
					if expectedDuration == 1.5 {
						try require(peak > 0.7 && peak < 1.3, "SDR title or caption brightness incorrect: \(peak)")
					}
					textPeak = max(textPeak, peak)
				}
			}
			count += 1
		}
		try require(reader.status == .completed, "HDR decoding failed")
		try require(count == Int((expectedDuration * 24).rounded()), "Unexpected HDR frame count \(count)")
		try require(low > 1.2, "HDR highlight clipped: minimum linear value \(low)")
		if expectedDuration == 1.5 {
			try require(abs((dissolveSample ?? 0) - 3.3333) < 0.2, "Dissolve did not blend in linear light: \(String(describing: dissolveSample))")
			print("CHECK title/caption white=\(textPeak), dissolve highlight=\(String(describing: dissolveSample))")
		}
		print("CHECK \(url.lastPathComponent): \(count) frames; minimum decoded highlight \(low)")
	}
}
