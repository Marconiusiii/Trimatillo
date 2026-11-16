import AVFoundation

nonisolated struct SilencePause: Identifiable {
	let id: Int
	let limits: CMTimeRange
	var cut: CMTimeRange
	var included = true
}

nonisolated struct SilenceDetector {
	let threshold: Float
	let minimumFrames: Int64
	let retainedFrames: Int64
	var collectsPauses = true
	private(set) var quietStart: Int64
	private(set) var cuts: [CMTimeRange] = []

	init(decibels: Int, minimum: Double, retained: Double, start: Int64) {
		threshold = pow(10, Float(decibels) / 20)
		minimumFrames = Int64((minimum * 48_000).rounded())
		retainedFrames = Int64((retained * 48_000).rounded())
		quietStart = start
	}

	mutating func consume(_ samples: [Float], first: Int64, bounds: Range<Int64>) {
		for frame in 0..<(samples.count / 2) {
			let time = first + Int64(frame)
			guard bounds.contains(time) else { continue }
			if abs(samples[frame * 2]) > threshold || abs(samples[frame * 2 + 1]) > threshold {
				if collectsPauses && time > quietStart { finish(at: time) }
				quietStart = time + 1
			}
		}
	}

	mutating func finish(at end: Int64) {
		guard end - quietStart >= minimumFrames, end - quietStart > retainedFrames else { return }
		cuts.append(CMTimeRange(start: CMTime(value: quietStart + retainedFrames / 2, timescale: 48_000),
			end: CMTime(value: end - (retainedFrames - retainedFrames / 2), timescale: 48_000)))
	}
}

nonisolated enum SilenceReviewError: LocalizedError {
	case entirelyQuiet
	case retainedTooLong

	var errorDescription: String? {
		switch self {
		case .entirelyQuiet: "The entire passage is below the silence threshold. Lower the threshold or select another passage."
		case .retainedTooLong: "Set retained silence below the minimum silence duration."
		}
	}
}

nonisolated enum ClipSilenceTrimming {
	@concurrent static func analyze(asset: AVAsset, range: CMTimeRange, decibels: Int,
		minimum: Double, retained: Double) async throws -> [CMTimeRange] {
		guard retained < minimum else { throw SilenceReviewError.retainedTooLong }
		let start = range.start.convertScale(48_000, method: .roundTowardPositiveInfinity).value
		let end = range.end.convertScale(48_000, method: .roundTowardNegativeInfinity).value
		guard end > start else { return [] }
		var detector = SilenceDetector(decibels: decibels, minimum: minimum, retained: retained, start: start)
		detector = try await scan(asset: asset, range: range, bounds: start..<end, detector: detector)
		guard detector.quietStart != start else { throw SilenceReviewError.entirelyQuiet }
		detector.finish(at: end)
		return detector.cuts
	}

	@concurrent static func narrationLength(url: URL, length: CMTime) async throws -> CMTime {
		let asset = AVURLAsset(url: url)
		let end = length.convertScale(48_000, method: .roundTowardPositiveInfinity).value
		guard end > 0 else { throw CocoaError(.fileReadCorruptFile) }
		var detector = SilenceDetector(decibels: -40, minimum: 0, retained: 0, start: 0)
		detector.collectsPauses = false
		detector = try await scan(asset: asset, range: CMTimeRange(start: .zero, duration: length), bounds: 0..<end, detector: detector)
		// Keep very quiet recordings intact if no sample crossed the threshold.
		guard detector.quietStart > 0 else { return length }
		return min(length, CMTime(value: detector.quietStart, timescale: 48_000))
	}

	private static func scan(asset: AVAsset, range: CMTimeRange, bounds: Range<Int64>, detector initial: SilenceDetector) async throws -> SilenceDetector {
		var detector = initial
		guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadUnsupportedScheme) }
		let reader = try AVAssetReader(asset: asset)
		reader.timeRange = range
		let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
			AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
			AVNumberOfChannelsKey: 2, AVLinearPCMIsFloatKey: true,
			AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
		])
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else { throw CocoaError(.fileReadUnknown) }
		reader.add(output)
		guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
		defer { reader.cancelReading() }
		while let buffer = output.copyNextSampleBuffer() {
			try Task.checkCancellation()
			let count = CMSampleBufferGetNumSamples(buffer)
			guard count > 0 else { continue }
			guard let data = CMSampleBufferGetDataBuffer(buffer) else { throw CocoaError(.fileReadCorruptFile) }
			var samples = [Float](repeating: 0, count: count * 2)
			let status = samples.withUnsafeMutableBytes {
				CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
			}
			guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
			let first = CMSampleBufferGetPresentationTimeStamp(buffer).convertScale(48_000, method: .roundHalfAwayFromZero).value
			detector.consume(samples, first: first, bounds: bounds)
		}
		try Task.checkCancellation()
		guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
		return detector
	}
}
