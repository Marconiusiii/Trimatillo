// Experimental project mixer. Not included in the app target.
// APAC channel-isolation validation currently fails; see PROJECT_AUDIO.md.
import AVFoundation

// ACN/SN3D W,Y,Z,X followed by a discrete front-center channel.
// Keep the original soundfield intact; encode ordinary stereo at +/-30 degrees.
nonisolated enum SpatialChannelMap {
	static let channelCount = 5
	static let rate = 48_000.0

	static var layout: AVAudioChannelLayout {
		let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
		let size = offset + channelCount * MemoryLayout<AudioChannelDescription>.size
		let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
		defer { raw.deallocate() }
		raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
		let header = raw.assumingMemoryBound(to: AudioChannelLayout.self)
		header.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
		header.pointee.mNumberChannelDescriptions = UInt32(channelCount)
		let labels = raw.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
		for index in 0..<channelCount {
			labels[index].mChannelLabel = index < 4 ? kAudioChannelLabel_HOA_ACN_0 + UInt32(index) : kAudioChannelLabel_Center
		}
		labels[4].mChannelFlags = .sphericalCoordinates
		labels[4].mCoordinates = (0, 0, 1)
		return AVAudioChannelLayout(layout: header)
	}

	static var layoutData: Data {
		let value = layout
		return withExtendedLifetime(value) {
			Data(bytes: value.layout, count: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)! + channelCount * MemoryLayout<AudioChannelDescription>.size)
		}
	}

	static func settings(channels: Int, pcm: Bool) -> [String: Any] {
		var result: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
			AVFormatIDKey: pcm ? kAudioFormatLinearPCM : kAudioFormatAPAC]
		if channels == 5 { result[AVChannelLayoutKey] = layoutData }
		if pcm {
			result[AVLinearPCMBitDepthKey] = 32
			result[AVLinearPCMIsFloatKey] = true
			result[AVLinearPCMIsNonInterleaved] = false
		}
		return result
	}

	static func supports(_ format: CMAudioFormatDescription) -> Bool {
		guard let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format),
			let source = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: nil) else { return false }
		if audio.pointee.mChannelsPerFrame == 4 {
			return source.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
		}
		return audio.pointee.mChannelsPerFrame == 5 && AVAudioChannelLayout(layout: source) == layout
	}

	static func add(_ input: UnsafePointer<Float>, channels: Int, gain: Float = 1, to output: UnsafeMutablePointer<Float>) {
		switch channels {
		case 1:
			output[4] += input[0] * gain
		case 2:
			// Half-gain per plane wave avoids doubling coherent left/right material.
			let sum = (input[0] + input[1]) * 0.5 * gain
			output[0] += sum
			output[1] += (input[0] - input[1]) * 0.25 * gain
			output[3] += sum * Float(0.8660254037844386)
		case 4, 5:
			for channel in 0..<channels { output[channel] += input[channel] * gain }
		default:
			preconditionFailure("Unsupported spatial input layout")
		}
	}
}

nonisolated struct SpatialGainRamp: Sendable {
	let first: Int64
	let end: Int64
	let startGain: Float
	let endGain: Float

	init(range: CMTimeRange, start: Float, end: Float) {
		first = Int64((range.start.seconds * SpatialChannelMap.rate).rounded())
		self.end = Int64((range.end.seconds * SpatialChannelMap.rate).rounded())
		startGain = start
		endGain = end
	}
}

// Each input retains its own track effects and envelope. Samples are aligned by
// presentation time, including gaps, rather than by the decoder's block sizes.
nonisolated struct SpatialProjectAudio {
	let asset: AVComposition
	let mix: AVAudioMix
	let nativeTrackIDs: Set<CMPersistentTrackID>
	let monoTrackIDs: Set<CMPersistentTrackID>
	let nativeGains: [CMPersistentTrackID: [SpatialGainRamp]]

	@available(iOS 26, *)
	@concurrent func render(stereoMovie: URL, duration: CMTime, name: String,
		inspectPCM: (@Sendable (AVAudioPCMBuffer, Int64) throws -> Void)? = nil) async throws -> ExportFile {
		let output = try ExportFile(name: name, suffix: "mov")
		let writer = try AVAssetWriter(outputURL: output.url, fileType: .mov)
		let settings = SpatialChannelMap.settings(channels: 5, pcm: false)
		guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw MediaExportFailure.spatialProcessing }
		let spatial = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
		guard writer.canAdd(spatial) else { throw MediaExportFailure.spatialProcessing }
		writer.add(spatial)
		let rendered = AVURLAsset(url: stereoMovie)
		let pictureReader = try AVAssetReader(asset: rendered)
		var copies: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
		var stereo: AVAssetWriterInput?
		for track in try await rendered.load(.tracks) where track.mediaType == .audio || track.mediaType == .video {
			let source = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
			source.alwaysCopiesSampleData = false
			let destination = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil,
				sourceFormatHint: try await track.load(.formatDescriptions).first)
			if track.mediaType == .video { destination.transform = try await track.load(.preferredTransform) }
			if track.mediaType == .audio { guard stereo == nil else { throw MediaExportFailure.invalidOutput }; stereo = destination }
			guard pictureReader.canAdd(source), writer.canAdd(destination) else { throw MediaExportFailure.invalidOutput }
			pictureReader.add(source)
			writer.add(destination)
			copies.append((source, destination))
		}
		guard let stereo else { throw MediaExportFailure.invalidOutput }
		spatial.marksOutputTrackAsEnabled = false
		spatial.addTrackAssociation(withTrackOf: stereo, type: AVAssetTrack.AssociationType.audioFallback.rawValue)
		writer.add(AVAssetWriterInputGroup(inputs: [stereo, spatial], defaultInput: stereo))
		var streams: [SpatialAudioStream] = []
		var finished = false
		defer {
			streams.forEach { $0.reader.cancelReading() }
			if !finished { pictureReader.cancelReading(); writer.cancelWriting() }
		}
		for track in try await asset.loadTracks(withMediaType: .audio) {
			let stream = try SpatialAudioStream(asset: asset, track: track, mix: mix,
				channels: nativeTrackIDs.contains(track.trackID) ? 5 : 2, mono: monoTrackIDs.contains(track.trackID), nativeGains: nativeGains[track.trackID], duration: duration)
			streams.append(stream)
		}
		guard writer.startWriting() else { throw writer.error ?? MediaExportFailure.invalidOutput }
		writer.startSession(atSourceTime: .zero)
		guard pictureReader.startReading() else { throw pictureReader.error ?? MediaExportFailure.invalidOutput }
		for stream in streams { try stream.start() }
		let total = Int64((duration.seconds * SpatialChannelMap.rate).rounded())
		let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SpatialChannelMap.rate,
			interleaved: true, channelLayout: SpatialChannelMap.layout)
		guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { throw MediaExportFailure.invalidOutput }
		var cursor: Int64 = 0
		var pending = Set(copies.indices)
		var spatialFinished = false
		var lastProgress = Date()
		while !pending.isEmpty || !spatialFinished {
			try Task.checkCancellation()
			var advanced = false
			if !spatialFinished && spatial.isReadyForMoreMediaData {
				if cursor < total {
					let count = Int(min(1024, total - cursor))
					buffer.frameLength = AVAudioFrameCount(count)
					let data = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
					data.update(repeating: 0, count: count * 5)
					for stream in streams { try stream.add(to: data, start: cursor, frames: count) }
					try inspectPCM?(buffer, cursor)
					let sample = try Self.sample(buffer, at: cursor)
					guard spatial.append(sample) else { throw writer.error ?? MediaExportFailure.invalidOutput }
					cursor += Int64(count)
				} else {
					for stream in streams { try stream.finish() }
					spatial.markAsFinished()
					spatialFinished = true
				}
				advanced = true
			}
			for index in pending.sorted() where copies[index].1.isReadyForMoreMediaData {
				if let sample = copies[index].0.copyNextSampleBuffer() {
					guard copies[index].1.append(sample) else { throw writer.error ?? MediaExportFailure.invalidOutput }
				} else { copies[index].1.markAsFinished(); pending.remove(index) }
				advanced = true
			}
			guard writer.status == .writing else { throw writer.error ?? MediaExportFailure.invalidOutput }
			if advanced { lastProgress = Date() }
			else {
				guard Date().timeIntervalSince(lastProgress) < 30 else { throw MediaExportFailure.invalidOutput }
				try await Task.sleep(for: .milliseconds(5))
			}
		}
		guard pictureReader.status == .completed else { throw pictureReader.error ?? MediaExportFailure.invalidOutput }
		writer.endSession(atSourceTime: duration)
		await writer.finishWriting()
		guard writer.status == .completed else { throw writer.error ?? MediaExportFailure.invalidOutput }
		finished = true
		let result = AVURLAsset(url: output.url)
		let tracks = try await result.loadTracks(withMediaType: .audio)
		guard tracks.count == 2,
			abs(try await result.load(.duration).seconds - duration.seconds) < 0.05 else { throw MediaExportFailure.invalidOutput }
		var checked = false
		for track in tracks {
			if let format = try await track.load(.formatDescriptions).first,
				CMFormatDescriptionGetMediaSubType(format) == kAudioFormatAPAC, SpatialChannelMap.supports(format) {
				let fallback = try await track.loadAssociatedTracks(ofType: .audioFallback)
				let groups = try await result.load(.trackGroups)
				checked = fallback.count == 1 && groups.contains {
					Set($0.trackIDs.map(\.int32Value)) == Set([track.trackID, fallback[0].trackID])
				}
			}
		}
		guard checked else { throw MediaExportFailure.invalidOutput }
		return output
	}

	static func sample(_ buffer: AVAudioPCMBuffer, at frame: Int64) throws -> CMSampleBuffer {
		var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
			presentationTimeStamp: CMTime(value: frame, timescale: 48000), decodeTimeStamp: .invalid)
		var sample: CMSampleBuffer?
		let status = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false,
			makeDataReadyCallback: nil, refcon: nil, formatDescription: buffer.format.formatDescription,
			sampleCount: Int(buffer.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
			sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
		guard status == noErr, let sample,
			CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil,
				blockBufferMemoryAllocator: nil, flags: 0, bufferList: buffer.audioBufferList) == noErr else { throw MediaExportFailure.invalidOutput }
		guard CMSampleBufferSetDataReady(sample) == noErr else { throw MediaExportFailure.invalidOutput }
		return sample
	}
}

nonisolated private final class SpatialAudioStream {
	let reader: AVAssetReader
	private let output: AVAssetReaderAudioMixOutput
	private let channels: Int
	private let mono: Bool
	private let nativeGains: [SpatialGainRamp]?
	private var rampIndex = 0
	private var buffer: AVAudioPCMBuffer?
	private var first: Int64 = 0
	private var count = 0
	private var ended = false

	init(asset: AVAsset, track: AVAssetTrack, mix: AVAudioMix, channels: Int, mono: Bool, nativeGains: [SpatialGainRamp]?, duration: CMTime) throws {
		self.channels = channels
		self.mono = mono
		self.nativeGains = nativeGains
		reader = try AVAssetReader(asset: asset)
		reader.timeRange = CMTimeRange(start: .zero, duration: duration)
		output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: SpatialChannelMap.settings(channels: channels, pcm: true))
		let selectedMix = AVMutableAudioMix()
		selectedMix.inputParameters = mix.inputParameters.filter { $0.trackID == track.trackID }
		// AVFoundation's processing-tap path can negotiate stereo before the
		// requested output conversion. Apply native spatial envelopes to PCM
		// directly so the soundfield never passes through that downmix.
		if nativeGains == nil { output.audioMix = selectedMix }
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else { throw MediaExportFailure.spatialProcessing }
		reader.add(output)
	}

	func start() throws {
		guard reader.startReading() else { throw reader.error ?? MediaExportFailure.invalidOutput }
	}

	private func next() throws {
		guard let sample = output.copyNextSampleBuffer() else {
			guard reader.status == .completed else { throw reader.error ?? MediaExportFailure.invalidOutput }
			ended = true
			buffer = nil
			return
		}
		guard let description = CMSampleBufferGetFormatDescription(sample) else { throw MediaExportFailure.invalidOutput }
		let format = AVAudioFormat(cmAudioFormatDescription: description)
		guard format.commonFormat == .pcmFormatFloat32, format.isInterleaved,
			format.channelCount == channels, format.sampleRate == SpatialChannelMap.rate else { throw MediaExportFailure.invalidOutput }
		count = CMSampleBufferGetNumSamples(sample)
		let time = CMSampleBufferGetPresentationTimeStamp(sample)
		guard time.isNumeric, count > 0 else { throw MediaExportFailure.invalidOutput }
		first = Int64((time.seconds * SpatialChannelMap.rate).rounded())
		guard let next = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw MediaExportFailure.invalidOutput }
		next.frameLength = AVAudioFrameCount(count)
		guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: next.mutableAudioBufferList) == noErr else { throw MediaExportFailure.invalidOutput }
		buffer = next
	}

	func add(to destination: UnsafeMutablePointer<Float>, start: Int64, frames: Int) throws {
		let end = start + Int64(frames)
		while !ended {
			if buffer == nil { try next(); if ended { break } }
			guard let buffer else { throw MediaExportFailure.invalidOutput }
			if first >= end { break }
			let lo = max(start, first), hi = min(end, first + Int64(count))
			if hi > lo {
				let source = buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
				for frame in lo..<hi {
					let input = source + Int(frame - first) * channels
					let output = destination + Int(frame - start) * 5
					if mono {
						// Stereo preparation duplicates mono at unity gain on both channels.
						output[4] += (input[0] + input[1]) * 0.5
					} else { SpatialChannelMap.add(input, channels: channels, gain: gain(at: frame), to: output) }
				}
			}
			if first + Int64(count) <= end { self.buffer = nil } else { break }
		}
	}

	private func gain(at frame: Int64) -> Float {
		guard let nativeGains, !nativeGains.isEmpty else { return 1 }
		while rampIndex + 1 < nativeGains.count && nativeGains[rampIndex].end <= frame { rampIndex += 1 }
		let ramp = nativeGains[rampIndex]
		if frame < ramp.first { return rampIndex == 0 ? 1 : nativeGains[rampIndex-1].endGain }
		guard ramp.end > ramp.first, frame < ramp.end else { return ramp.endGain }
		let progress = Float(frame - ramp.first) / Float(ramp.end - ramp.first)
		return ramp.startGain + (ramp.endGain - ramp.startGain) * progress
	}

	func finish() throws {
		while !ended { try Task.checkCancellation(); try next() }
	}
}
