import AVFoundation

enum SpatialProbe {
	static let rate = 48_000.0
	static let spatialTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
	static func layout(_ channels: Int) -> AVAudioChannelLayout {
		if channels == 5 {
			let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
			let raw = UnsafeMutableRawPointer.allocate(byteCount: offset + 5 * MemoryLayout<AudioChannelDescription>.size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
			defer { raw.deallocate() }
			raw.initializeMemory(as: UInt8.self, repeating: 0, count: offset + 5 * MemoryLayout<AudioChannelDescription>.size)
			let header = raw.assumingMemoryBound(to: AudioChannelLayout.self)
			header.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
			header.pointee.mNumberChannelDescriptions = 5
			let descriptions = raw.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
			for index in 0..<5 { descriptions[index].mChannelLabel = index < 4 ? kAudioChannelLabel_HOA_ACN_0 + UInt32(index) : kAudioChannelLabel_Center }
			return AVAudioChannelLayout(layout: header)
		}
		return AVAudioChannelLayout(layoutTag: channels == 4 ? spatialTag : kAudioChannelLayoutTag_Stereo)!
	}
	static func layoutData(_ channels: Int) -> Data {
		let value = layout(channels)
		let size = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)! + Int(value.layout.pointee.mNumberChannelDescriptions) * MemoryLayout<AudioChannelDescription>.size
		return Data(bytes: value.layout, count: size)
	}
	static func pcmSettings(_ channels: Int) -> [String: Any] {
		[AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
		 AVChannelLayoutKey: layoutData(channels), AVLinearPCMBitDepthKey: 32,
		 AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
	}
	static func encoding(_ channels: Int) -> [String: Any] {
		[AVFormatIDKey: channels > 2 ? kAudioFormatAPAC : kAudioFormatMPEG4AAC,
		 AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVChannelLayoutKey: layoutData(channels)]
	}

	static func run(_ root: URL) async throws {
		let frames = Int(rate * 2)
		var spatial = [Float](repeating: 0, count: frames * 4)
		var stereo = [Float](repeating: 0, count: frames * 2)
		for frame in 0..<frames {
			let phase = 2 * Double.pi * 440 * Double(frame) / rate
			let signal = Float(sin(phase) * 0.1)
			// A stationary front-facing plane wave in ACN/SN3D order W,Y,Z,X.
			spatial[frame * 4] = signal
			spatial[frame * 4 + 3] = signal
			stereo[frame * 2] = signal
			stereo[frame * 2 + 1] = signal
		}
		let original = root.appendingPathComponent("spatial-source.mov")
		try await write(original, spatial: spatial, stereo: stereo)
		try await inspect(original)
		let asset = AVURLAsset(url: original)
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		let spatialTrack = try await channelTrack(tracks, channels: 4)
		let stereoTrack = try await channelTrack(tracks, channels: 2)
		let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 48000), duration: CMTime(seconds: 1, preferredTimescale: 48000))
		let decodedSpatial = try await read(asset, track: spatialTrack, channels: 4, range: range)
		let decodedStereo = try await read(asset, track: stereoTrack, channels: 2, range: range)
		for narration in [false, true] {
			let out = root.appendingPathComponent(narration ? "spatial-cut-gain-narration.mov" : "spatial-cut-gain.mov")
			let processedSpatial = processed(decodedSpatial, channels: 4, narration: narration)
			let processedStereo = processed(decodedStereo, channels: 2, narration: narration)
			try await write(out, spatial: processedSpatial, stereo: processedStereo,
				video: narration ? root.appendingPathComponent("hdr-edited.mov") : nil)
			try await verify(out, reference: processedSpatial, expectedDuration: 1, narration: narration)
			if narration { try await HDRProbe.verify(out, expectedDuration: 1) }
		}
		print("PASS: synthetic first-order ambisonic cut, gain and centered narration; APAC plus stereo alternate")
		print("NOT PROVEN: camera Audio Mix metadata, device spatial rendering, arbitrary multitrack effects")
	}

	static func channelTrack(_ tracks: [AVAssetTrack], channels: UInt32) async throws -> AVAssetTrack {
		for track in tracks {
			if let format = try await track.load(.formatDescriptions).first,
				CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame == channels { return track }
		}
		throw ProbeFailure("Missing \(channels)-channel audio track")
	}

	static func read(_ asset: AVAsset, track: AVAssetTrack, channels: Int, range: CMTimeRange) async throws -> [Float] {
		try require(range.duration.seconds <= 3, "Prototype decoding is limited to three seconds")
		let reader = try AVAssetReader(asset: asset)
		reader.timeRange = range
		let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcmSettings(channels))
		reader.add(output)
		try require(reader.startReading(), "Audio decode could not start: \(String(describing: reader.error))")
		let frames = Int((range.duration.seconds * rate).rounded())
		var samples = [Float](repeating: 0, count: frames * channels)
		var covered = [Bool](repeating: false, count: frames)
		var received = 0
		while let sample = output.copyNextSampleBuffer() {
			try Task.checkCancellation()
			guard let description = CMSampleBufferGetFormatDescription(sample),
				let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
				format.commonFormat == .pcmFormatFloat32, format.isInterleaved,
				format.channelCount == UInt32(channels) else { throw ProbeFailure("Unexpected decoded PCM layout") }
			let count = CMSampleBufferGetNumSamples(sample)
			let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
			buffer.frameLength = AVAudioFrameCount(count)
			try require(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr, "Cannot copy decoded PCM")
			let data = buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
			let offset = Int(((CMSampleBufferGetPresentationTimeStamp(sample) - range.start).seconds * rate).rounded())
			let first = max(0, offset)
			let end = min(frames, offset + count)
			if first < end {
				for frame in first..<end {
					for channel in 0..<channels {
						samples[frame * channels + channel] = data[(frame - offset) * channels + channel]
					}
					covered[frame] = true
				}
			}
			received += count
		}
		try require(reader.status == .completed, "Audio decode failed: \(String(describing: reader.error))")
		let missing = covered.filter { !$0 }.count
		print("CHECK PCM \(channels) channels: received=\(received), requested=\(frames), missing=\(missing)")
		try require(missing == 0, "Decoded audio has \(missing) missing frames in the requested interval")
		return samples
	}

	static func processed(_ input: [Float], channels: Int, narration: Bool) -> [Float] {
		var result = input.map { $0 * 0.5 }
		if narration {
			for frame in 0..<(result.count / channels) {
				// Distinct 880 Hz mono probe, positioned in front for FOA and centered for stereo.
				let voice = Float(sin(2 * Double.pi * 880 * Double(frame) / rate) * 0.025)
				if channels == 5 {
					result[frame * channels + 4] += voice
				} else {
					result[frame * channels] += voice
					result[frame * channels + (channels == 4 ? 3 : 1)] += voice
				}
			}
		}
		return result
	}

	static func write(_ url: URL, spatial: [Float], stereo: [Float], spatialSettings: [String: Any]? = nil,
		stereoSettings: [String: Any]? = nil, video: URL? = nil, spatialChannels: Int = 4) async throws {
		try require(spatial.count / spatialChannels == stereo.count / 2, "Spatial and stereo frame counts differ")
		let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
		let a = AVAssetWriterInput(mediaType: .audio, outputSettings: stereoSettings ?? encoding(2))
		let b = AVAssetWriterInput(mediaType: .audio, outputSettings: spatialSettings ?? encoding(spatialChannels))
		try require(writer.canAdd(a) && writer.canAdd(b), "Spatial writer inputs unsupported")
		b.marksOutputTrackAsEnabled = false
		b.addTrackAssociation(withTrackOf: a, type: AVAssetTrack.AssociationType.audioFallback.rawValue)
		writer.add(a)
		writer.add(b)
		writer.add(AVAssetWriterInputGroup(inputs: [a, b], defaultInput: a))
		var picture: (AVAssetReader, AVAssetReaderTrackOutput, AVAssetWriterInput)?
		if let video {
			let asset = AVURLAsset(url: video)
			let track = try await asset.loadTracks(withMediaType: .video)[0]
			let reader = try AVAssetReader(asset: asset)
			reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: Int64(spatial.count / spatialChannels), timescale: 48000))
			let source = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
			reader.add(source)
			let destination = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: try await track.load(.formatDescriptions).first)
			destination.transform = try await track.load(.preferredTransform)
			writer.add(destination)
			picture = (reader, source, destination)
		}
		try require(writer.startWriting(), "Spatial encoder could not start: \(String(describing: writer.error))")
		writer.startSession(atSourceTime: .zero)
		let frames = spatial.count / spatialChannels
		for offset in stride(from: 0, to: frames, by: 1024) {
			let count = min(1024, frames - offset)
			for (input, values, channels) in [(a, stereo, 2), (b, spatial, spatialChannels)] {
				try await ready(input, writer: writer)
				let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: true, channelLayout: layout(channels))
				let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
				buffer.frameLength = AVAudioFrameCount(count)
				values.withUnsafeBufferPointer { pointer in
					buffer.mutableAudioBufferList.pointee.mBuffers.mData!.copyMemory(from: pointer.baseAddress! + offset * channels, byteCount: count * channels * 4)
				}
				var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: Int64(offset), timescale: 48000), decodeTimeStamp: .invalid)
				var sample: CMSampleBuffer?
				try require(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
					formatDescription: format.formatDescription, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
					sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, "Cannot create PCM sample")
				try require(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
					flags: 0, bufferList: buffer.audioBufferList) == noErr, "Cannot attach PCM sample")
				try require(input.append(sample!), "Spatial append failed: \(String(describing: writer.error))")
			}
		}
		a.markAsFinished()
		b.markAsFinished()
		if let (reader, source, destination) = picture {
			try require(reader.startReading(), "Cannot read rendered HDR video for combined output")
			while let sample = source.copyNextSampleBuffer() {
				try await ready(destination, writer: writer)
				try require(destination.append(sample), "Cannot append rendered HDR video")
			}
			try require(reader.status == .completed, "Rendered HDR read failed")
			destination.markAsFinished()
		}
		try await finish(writer)
	}

	static func verify(_ url: URL, reference: [Float], expectedDuration: Double, narration: Bool, spatialChannels: Int = 4) async throws {
		try await inspect(url)
		let asset = AVURLAsset(url: url)
		try require(abs(try await asset.load(.duration).seconds - expectedDuration) < 0.05, "Spatial duration changed")
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		try require(tracks.count == 2, "Expected spatial and stereo alternatives")
		let spatial = try await channelTrack(tracks, channels: UInt32(spatialChannels))
		let stereo = try await channelTrack(tracks, channels: 2)
		let groups = try await asset.load(.trackGroups)
		try require(groups.contains { Set($0.trackIDs.map { $0.int32Value }) == Set([spatial.trackID, stereo.trackID]) }, "Alternate group lost")
		let fallback = try await spatial.loadAssociatedTracks(ofType: .audioFallback)
		try require(fallback.contains { $0.trackID == stereo.trackID }, "Stereo fallback relationship lost")
		let formats = try await spatial.load(.formatDescriptions)
		try require(CMFormatDescriptionGetMediaSubType(formats[0]) == kAudioFormatAPAC, "APAC encoding lost")
		var size = 0
		guard let channelLayout = CMAudioFormatDescriptionGetChannelLayout(formats[0], sizeOut: &size) else { throw ProbeFailure("Missing spatial channel layout") }
		try require(AVAudioChannelLayout(layout: channelLayout) == layout(spatialChannels), "Spatial channel layout changed")
		let output = try await read(asset, track: spatial, channels: spatialChannels, range: CMTimeRange(start: .zero, duration: CMTime(seconds: expectedDuration, preferredTimescale: 48000)))
		func rms(_ values: [Float]) -> Double {
			sqrt(values.reduce(0.0) { $0 + Double($1 * $1) } / Double(values.count))
		}
		let actual = rms(output)
		let expected = rms(reference)
		try require(abs(actual / expected - 1) < 0.12, "Spatial signal level mismatch: \(actual) vs \(expected)")
		for channel in 0..<spatialChannels {
			let decodedChannel = stride(from: channel, to: output.count, by: spatialChannels).map { output[$0] }
			let referenceChannel = stride(from: channel, to: reference.count, by: spatialChannels).map { reference[$0] }
			let desired = rms(referenceChannel)
			let observed = rms(decodedChannel)
			try require(abs(observed - desired) < max(0.002, desired * 0.12), "Spatial channel \(channel) level mismatch")
		}
		let stereoSamples = try await read(asset, track: stereo, channels: 2,
			range: CMTimeRange(start: .zero, duration: CMTime(seconds: expectedDuration, preferredTimescale: 48000)))
		try require(!stereoSamples.isEmpty && rms(stereoSamples) > 0.001, "Stereo fallback is silent")
		print("CHECK spatial output RMS=\(actual), expected=\(expected), narration=\(narration)")
	}

	static func camera(_ url: URL, root: URL) async throws {
		let asset = AVURLAsset(url: url)
		let length = min(3, try await asset.load(.duration).seconds - 0.25)
		try require(length > 0, "Camera fixture is too short")
		let range = CMTimeRange(start: CMTime(seconds: 0.25, preferredTimescale: 48000), duration: CMTime(seconds: length, preferredTimescale: 48000))
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		for channels in [5, 4] {
			guard let track = try? await channelTrack(tracks, channels: UInt32(channels)) else { continue }
			let format = try await track.load(.formatDescriptions)[0]
			var size = 0
			guard CMFormatDescriptionGetMediaSubType(format) == kAudioFormatAPAC,
				let sourceLayout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size),
				AVAudioChannelLayout(layout: sourceLayout) == layout(channels) else { throw ProbeFailure("Unrecognized camera spatial layout") }
			let alternatives = try await track.loadAssociatedTracks(ofType: .audioFallback)
			let stereoTrack = try await channelTrack(alternatives, channels: 2)
			print("Camera spatial input: preserving \(channels) source channels and its associated stereo fallback")
			let spatial = processed(try await read(asset, track: track, channels: channels, range: range), channels: channels, narration: true)
			let stereo = processed(try await read(asset, track: stereoTrack, channels: 2, range: range), channels: 2, narration: true)
			let output = root.appendingPathComponent("camera-audio-cut-gain-narration.mov")
			try await write(output, spatial: spatial, stereo: stereo, spatialChannels: channels)
			try await verify(output, reference: spatial, expectedDuration: length, narration: true, spatialChannels: channels)
			print("PASS camera spatial: \(channels)-channel APAC layout and stereo fallback retained; Camera Audio Mix parameter editing not tested")
			return
		}
		throw ProbeFailure("No supported four- or five-channel camera spatial track")
	}
}
