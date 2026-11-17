import Accelerate
import AVFoundation

nonisolated enum ClipLoudnessAnalyzer {
	// Read the stereo edit at 192 kHz to include intersample peaks in the ceiling.
	static let sampleRate = 192_000

	@concurrent static func gain(asset: AVAsset, ranges: [ProjectRange], target: Double, ceiling: Double) async throws -> Float {
		try Task.checkCancellation()
		guard let input = try await asset.loadTracks(withMediaType: .audio).first else {
			throw ProjectFailure("Could not read the clip's audio. Reconnect it in Project Media.")
		}
		let available = try await input.load(.timeRange)
		let edit = AVMutableComposition()
		guard let track = edit.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
			throw CocoaError(.featureUnsupported)
		}
		var position = CMTime.zero
		for retained in ranges {
			try Task.checkCancellation()
			let range = retained.range
			let overlap = available.intersection(range)
			if overlap.isValid && !overlap.isEmpty {
				try track.insertTimeRange(overlap, of: input, at: position + (overlap.start - range.start))
			}
			position = position + range.duration
		}
		guard !track.segments.isEmpty else { return 1 }
		if edit.duration < position { edit.insertEmptyTimeRange(CMTimeRange(start: edit.duration, end: position)) }

		let reader = try AVAssetReader(asset: edit)
		let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
			AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 2, AVSampleRateKey: sampleRate,
			AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
		])
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output),
			let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 2, interleaved: true) else {
			throw CocoaError(.featureUnsupported)
		}
		reader.add(output)
		guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
		defer { reader.cancelReading() }
		let meter = try LoudnessMeter()
		var buffer: AVAudioPCMBuffer?
		while let sample = output.copyNextSampleBuffer() {
			try Task.checkCancellation()
			let frames = sample.numSamples
			guard frames > 0 else { continue }
			if Int(buffer?.frameCapacity ?? 0) < frames {
				buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
			}
			guard let buffer, let audio = buffer.floatChannelData else { throw CocoaError(.fileReadTooLarge) }
			buffer.frameLength = AVAudioFrameCount(frames)
			let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
			guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
			meter.measure(audio[0], frames: frames)
		}
		guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
		return meter.gain(target: target, ceiling: ceiling)
	}
}

nonisolated private final class LoudnessMeter {
	private let filter: vDSP_biquad_SetupD
	private var leftDelay = [Double](repeating: 0, count: 6)
	private var rightDelay = [Double](repeating: 0, count: 6)
	private let hop = ClipLoudnessAnalyzer.sampleRate / 10
	private var samples = [Double](repeating: 0, count: ClipLoudnessAnalyzer.sampleRate / 10)
	private var framesInHop = 0
	private var energy = 0.0
	private var hops: [Double] = []
	private var blocks: [Double] = []
	private var peak: Float = 0

	init() throws {
		// BS.1770 K-weighting: high shelf followed by the RLB high-pass filter.
		let rate = Double(ClipLoudnessAnalyzer.sampleRate)
		let shelf = tan(.pi * 1681.974450955533 / rate)
		let high = pow(10, 3.999843853973347 / 20)
		let middle = pow(high, 0.4996667741545416)
		let q = 0.7071752369554196
		let square = shelf * shelf
		let denominator = 1 + shelf / q + square
		let low = tan(.pi * 38.13547087602444 / rate)
		let lowQ = 0.5003270373238773
		let lowDenominator = 1 + low / lowQ + low * low
		let coefficients = [
			(high + middle * shelf / q + square) / denominator, 2 * (square - high) / denominator,
			(high - middle * shelf / q + square) / denominator, 2 * (square - 1) / denominator,
			(1 - shelf / q + square) / denominator,
			1, -2, 1, 2 * (low * low - 1) / lowDenominator, (1 - low / lowQ + low * low) / lowDenominator
		]
		guard let setup = vDSP_biquad_CreateSetupD(coefficients, 2) else { throw CocoaError(.featureUnsupported) }
		filter = setup
	}

	deinit { vDSP_biquad_DestroySetupD(filter) }

	func measure(_ interleaved: UnsafePointer<Float>, frames: Int) {
		var maximum: Float = 0
		vDSP_maxmgv(interleaved, 1, &maximum, vDSP_Length(frames * 2))
		peak = max(peak, maximum)
		var offset = 0
		while offset < frames {
			let count = min(frames - offset, hop - framesInHop)
			let input = interleaved.advanced(by: offset * 2)
			let length = vDSP_Length(count)
			samples.withUnsafeMutableBufferPointer { scratch in
				let values = scratch.baseAddress!
				for channel in 0..<2 {
					vDSP_vspdp(input.advanced(by: channel), 2, values, 1, length)
					if channel == 0 { vDSP_biquadD(filter, &leftDelay, values, 1, values, 1, length) }
					else { vDSP_biquadD(filter, &rightDelay, values, 1, values, 1, length) }
					var sum = 0.0
					vDSP_svesqD(values, 1, &sum, length)
					energy += sum
				}
			}
			offset += count
			framesInHop += count
			if framesInHop == hop {
				hops.append(energy)
				if hops.count == 4 {
					blocks.append(hops.reduce(0, +) / Double(4 * hop))
					hops.removeFirst()
				}
				framesInHop = 0
				energy = 0
			}
		}
	}

	func gain(target: Double, ceiling: Double) -> Float {
		guard peak > 0 else { return 1 }
		// A shorter edit has no complete gating block. Measure its retained frames.
		if blocks.isEmpty {
			let count = hops.count * hop + framesInHop
			if count > 0 { blocks.append((hops.reduce(0, +) + energy) / Double(count)) }
		}
		func mean(above gate: Double) -> Double? {
			var energy = 0.0
			var count = 0
			for block in blocks where block > gate {
				energy += block
				count += 1
			}
			return count == 0 ? nil : energy / Double(count)
		}
		let absoluteGate = pow(10, (-70 + 0.691) / 10)
		var adjustment = 0.0
		if let first = mean(above: absoluteGate), let gated = mean(above: max(absoluteGate, first / 10)) {
			adjustment = target - (-0.691 + 10 * log10(gated))
		}
		let headroom = ceiling - 20 * log10(Double(peak))
		return Float(pow(10, min(adjustment, headroom) / 20))
	}
}
