import Accelerate
import AVFoundation

nonisolated enum ClipLoudnessAnalyzer {
	// Read the retained edit at 192 kHz to include intersample peaks in the ceiling.
	static let sampleRate = 192_000

	@concurrent static func measure(asset: AVAsset, ranges: [ProjectRange]) async throws -> Measurement {
		try Task.checkCancellation()
		guard let input = try await MediaQuality.playbackAudioTrack(asset) else {
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
		guard !track.segments.isEmpty else { return Measurement() }
		if edit.duration < position { edit.insertEmptyTimeRange(CMTimeRange(start: edit.duration, end: position)) }

		let reader = try AVAssetReader(asset: edit)
		guard let description = try await input.load(.formatDescriptions).first else { throw CocoaError(.fileReadCorruptFile) }
		let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
		let channels = sourceFormat.channelCount
		var settings: [String: Any] = [
			AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: channels, AVSampleRateKey: sampleRate,
			AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
		]
		var layoutSize = 0
		if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize) {
			settings[AVChannelLayoutKey] = Data(bytes: layout, count: layoutSize)
		}
		let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output),
			let format = AVAudioFormat(settings: settings) else {
			throw CocoaError(.featureUnsupported)
		}
		reader.add(output)
		guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
		defer { reader.cancelReading() }
		let meter = try LoudnessMeter(weights: channelWeights(sourceFormat))
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
		return meter.result()
	}

	private static func channelWeights(_ format: AVAudioFormat) -> [Double] {
		let count = Int(format.channelCount)
		let ordinary = [Double](repeating: 1, count: count)
		guard count > 2, let channelLayout = format.channelLayout else { return ordinary }
		defer { withExtendedLifetime(channelLayout) {} }
		let layout = channelLayout.layout
		func weights(_ layout: UnsafePointer<AudioChannelLayout>) -> [Double] {
			guard layout.pointee.mNumberChannelDescriptions == count else { return ordinary }
			let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
			let first = UnsafeRawPointer(layout).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
			return UnsafeBufferPointer(start: first, count: count).map { channel in
				switch channel.mChannelLabel {
				case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: 0
				case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
					kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,
					kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
					kAudioChannelLabel_CenterSurround: 1.41
				default: 1
				}
			}
		}
		var tag = layout.pointee.mChannelLayoutTag
		if tag == kAudioChannelLayoutTag_UseChannelDescriptions { return weights(layout) }
		let bitmap = tag == kAudioChannelLayoutTag_UseChannelBitmap
		let property = bitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
		if bitmap { tag = layout.pointee.mChannelBitmap.rawValue }
		let specifierSize = UInt32(MemoryLayout.size(ofValue: tag))
		var bytes: UInt32 = 0
		guard AudioFormatGetPropertyInfo(property, specifierSize, &tag, &bytes) == noErr, bytes >= MemoryLayout<AudioChannelLayout>.size else { return ordinary }
		let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioChannelLayout>.alignment)
		defer { storage.deallocate() }
		guard AudioFormatGetProperty(property, specifierSize, &tag, &bytes, storage) == noErr else { return ordinary }
		return weights(UnsafePointer(storage.assumingMemoryBound(to: AudioChannelLayout.self)))
	}

	struct Measurement: Hashable {
		var loudness: Double?
		var peak: Double = 0

		func gain(for settings: TrackAudioEffects.Loudness) -> Float {
			guard let loudness else { return 1 }
			return Float(pow(10, min(settings.target - loudness, settings.peak - peak) / 20))
		}
	}
}

nonisolated private final class LoudnessMeter {
	private let filter: vDSP_biquad_SetupD
	private let weights: [Double]
	private var delays: [[Double]]
	private let hop = ClipLoudnessAnalyzer.sampleRate / 10
	private var samples = [Double](repeating: 0, count: ClipLoudnessAnalyzer.sampleRate / 10)
	private var framesInHop = 0
	private var energy = 0.0
	private var hops: [Double] = []
	private var blocks: [Double] = []
	private var peak: Float = 0

	init(weights: [Double]) throws {
		self.weights = weights
		delays = Array(repeating: Array(repeating: 0, count: 6), count: weights.count)
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
		vDSP_maxmgv(interleaved, 1, &maximum, vDSP_Length(frames * weights.count))
		peak = max(peak, maximum)
		var offset = 0
		while offset < frames {
			let count = min(frames - offset, hop - framesInHop)
			let input = interleaved.advanced(by: offset * weights.count)
			let length = vDSP_Length(count)
			samples.withUnsafeMutableBufferPointer { scratch in
				let values = scratch.baseAddress!
				for channel in weights.indices where weights[channel] > 0 {
					vDSP_vspdp(input.advanced(by: channel), vDSP_Stride(weights.count), values, 1, length)
					vDSP_biquadD(filter, &delays[channel], values, 1, values, 1, length)
					var sum = 0.0
					vDSP_svesqD(values, 1, &sum, length)
					energy += sum * weights[channel]
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

	func result() -> ClipLoudnessAnalyzer.Measurement {
		guard peak > 0 else { return .init() }
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
		guard let first = mean(above: absoluteGate), let gated = mean(above: max(absoluteGate, first / 10)) else { return .init() }
		return .init(loudness: -0.691 + 10 * log10(gated), peak: 20 * log10(Double(peak)))
	}
}

// Share measurements between a project and its effects preview for the current editing session.
@MainActor final class ClipLoudnessMeasurements {
	private struct Entry {
		let ranges: [ProjectRange]
		let reference: ProjectMediaSource.Reference
		let url: URL?
		let modified: Date?
		let result: ClipLoudnessAnalyzer.Measurement
	}
	private var entries: [UUID: Entry] = [:]

	func retainClips(in project: EditingProject) {
		let ids = Set(project.placements.map(\.id))
		entries = entries.filter { ids.contains($0.key) }
	}

	func measure(_ clip: ProjectPlacement, source: ProjectMediaSource, asset: AVAsset) async throws -> ClipLoudnessAnalyzer.Measurement {
		let url = (asset as? AVURLAsset)?.url
		let modified = try? url?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
		if let url, let entry = entries[clip.id], entry.url == url, entry.modified == modified,
			entry.reference == source.reference, entry.ranges == clip.ranges { return entry.result }
		let result = try await ClipLoudnessAnalyzer.measure(asset: asset, ranges: clip.ranges)
		try Task.checkCancellation()
		entries[clip.id] = Entry(ranges: clip.ranges, reference: source.reference, url: url, modified: modified, result: result)
		return result
	}
}
