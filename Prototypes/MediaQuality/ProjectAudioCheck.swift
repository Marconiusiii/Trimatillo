import AVFoundation
@main struct Check {
	static let rate = 48000.0
	static func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48000) }
	static func require(_ condition: Bool, _ message: String) throws { if !condition { throw ProjectFailure(message) } }
	static func tone(channels: Int, frequencies: [Double]) throws -> URL {
		let url = ProbeFiles.root.appendingPathComponent("Tone-" + UUID().uuidString + ".caf")
		let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: UInt32(channels))!
		let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
		buffer.frameLength = 48000
		for channel in 0..<channels { for frame in 0..<48000 {
			buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * frequencies[channel] / rate) * 0.02)
		} }
		do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
		return url
	}
	static func read(_ asset: AVAsset, track: AVAssetTrack, channels: Int, start: Double = 0, duration: Double = 2, requiredStart: Double? = nil, requiredEnd: Double? = nil) async throws -> [Float] {
		let reader = try AVAssetReader(asset: asset)
		reader.timeRange = CMTimeRange(start: t(start), duration: t(duration))
		let output = AVAssetReaderTrackOutput(track: track, outputSettings: SpatialChannelMap.decodingSettings(channels: channels))
		reader.add(output)
		try require(reader.startReading(), "reader start: \(String(describing: reader.error))")
		let total = Int((duration * rate).rounded())
		var result = [Float](repeating: 0, count: total * channels)
		var coverage = Set<Int>()
		while let sample = output.copyNextSampleBuffer() {
			let format = AVAudioFormat(cmAudioFormatDescription: CMSampleBufferGetFormatDescription(sample)!)
			let count = CMSampleBufferGetNumSamples(sample)
			let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!; buffer.frameLength = UInt32(count)
			try require(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == 0, "PCM copy")
			let data = buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
			let offset = Int(((CMSampleBufferGetPresentationTimeStamp(sample).seconds - start) * rate).rounded())
			for frame in max(0,offset)..<max(0,min(total, offset+count)) {
				for channel in 0..<channels { result[frame*channels+channel] = data[(frame-offset)*channels+channel] }
				coverage.insert(frame)
			}
		}
		try require(reader.status == .completed, "reader finish: \(String(describing: reader.error))")
		let available = try await track.load(.timeRange)
		let requiredFirst = max(0, Int(((max(available.start.seconds, requiredStart ?? start) - start) * rate).rounded()))
		let requiredEnd = min(total, Int(((min(available.end.seconds, requiredEnd ?? (start + duration)) - start) * rate).rounded()))
		try require(requiredFirst >= requiredEnd || (requiredFirst..<requiredEnd).allSatisfy { coverage.contains($0) }, "missing frames \(total-coverage.count), source range \(available)")
		return result
	}
	static func checkIsolation(active: Int) async throws {
		let file = try ExportFile(name: "Isolated-\(active)", suffix: "mov")
		let writer = try AVAssetWriter(outputURL: file.url, fileType: .mov)
		let input = AVAssetWriterInput(mediaType: .audio, outputSettings: SpatialChannelMap.settings(channels: 5, pcm: false))
		try require(writer.canAdd(input), "Cannot add APAC writer input")
		writer.add(input)
		try require(writer.startWriting(), "Cannot start APAC writer")
		writer.startSession(atSourceTime: .zero)
		var complete = false
		defer { if !complete { writer.cancelWriting() } }
		let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: true, channelLayout: SpatialChannelMap.layout)
		let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
		for first in stride(from: 0, to: 96000, by: 1024) {
			let deadline = Date().addingTimeInterval(30)
			while !input.isReadyForMoreMediaData {
				try require(writer.status == .writing && Date() < deadline, "APAC writer stalled")
				try await Task.sleep(for: .milliseconds(5))
			}
			let count = min(1024, 96000-first)
			buffer.frameLength = UInt32(count)
			let data = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
			data.update(repeating: 0, count: count*5)
			for frame in 0..<count { data[frame*5+active] = Float(sin(Double(first+frame)*2 * .pi*440/rate)*0.1) }
			try require(input.append(SpatialProjectAudio.sample(buffer, at: Int64(first))), "Cannot append APAC sample")
		}
		input.markAsFinished()
		writer.endSession(atSourceTime: t(2))
		await writer.finishWriting()
		try require(writer.status == .completed, "APAC writer failed")
		complete = true
		let asset = AVURLAsset(url: file.url)
		let track = try await asset.loadTracks(withMediaType: .audio)[0]
		let pcm = try await read(asset, track: track, channels: 5)
		let levels = (0..<5).map { channel in
			sqrt(stride(from: channel, to: pcm.count, by: 5).reduce(0.0) { $0 + Double(pcm[$1]*pcm[$1]) } / 96000)
		}
		print("Expected RMS", 0.1 / sqrt(2), "in channel", active, "zero elsewhere")
		print("Decoded channel RMS", levels)
		try require(levels.indices.allSatisfy { abs(levels[$0] - ($0 == active ? 0.1 / sqrt(2) : 0)) < 0.001 }, "APAC round trip changed channel isolation")
		var difference = 0.0
		for frame in 0..<96000 {
			let reference = sin(Double(frame) * 2 * .pi * 440 / rate) * 0.1
			let error = Double(pcm[frame * 5 + active]) - reference
			difference += error * error
		}
		try require(sqrt(difference / 96000) < 0.0071, "Encoded signal timing or waveform changed")
		print("PASS channel isolation")
	}

	static func main() async {
		setbuf(stdout, nil)
		do {
			try require(CommandLine.arguments.count > 2, "Usage: project-audio-check NEW_OUTPUT_DIRECTORY SOURCE_MOVIE [SOURCE_MOVIE ...]")
			try require(!FileManager.default.fileExists(atPath: ProbeFiles.root.path), "Choose a new output directory.")
			try FileManager.default.createDirectory(at: ProbeFiles.root, withIntermediateDirectories: true)
			if CommandLine.arguments[2] == "--isolation" { for active in 0..<5 { try await checkIsolation(active: active) }; return }
			let stereoURL = try tone(channels: 2, frequencies: [440, 660])
			let monoURL = try tone(channels: 1, frequencies: [880])
			for path in CommandLine.arguments.dropFirst(2) {
				let url = URL(fileURLWithPath: path)
				let name = url.lastPathComponent
				let source = AVURLAsset(url: url)
				var native: AVAssetTrack!
				for track in try await source.loadTracks(withMediaType: .audio) {
					if try await track.load(.formatDescriptions).contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatAPAC }) { native = track }
				}
				let fallback = try await native.loadAssociatedTracks(ofType: .audioFallback)[0]
				let composition = AVMutableComposition()
				let stereoComp = AVMutableComposition()
				let raw = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 1)!
				let cuts = [CMTimeRange(start: t(0.5), duration: t(1)), CMTimeRange(start: t(3), duration: t(1))]
				for (index, cut) in cuts.enumerated() { try raw.insertTimeRange(cut, of: native, at: t(Double(index))) }
				let compatibility = stereoComp.addMutableTrack(withMediaType: .audio, preferredTrackID: 1)!
				for (index, cut) in cuts.enumerated() { try compatibility.insertTimeRange(cut, of: fallback, at: t(Double(index))) }
				
				for (id,url,start) in [(Int32(2),stereoURL,0.25),(Int32(3),monoURL,0.5)] {
					let asset = AVURLAsset(url: url)
					let input = try await asset.loadTracks(withMediaType: .audio)[0]
					let prepared = input
					let range = CMTimeRange(start: .zero, duration: t(1))
					for comp in [composition,stereoComp] {
						let output = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: id)!
						try output.insertTimeRange(range, of: prepared, at: t(start))
					}
				}
				func mix() -> AVAudioMix {
					let mix = AVMutableAudioMix()
					mix.inputParameters = [Int32(1),2,3].map { id in
						let p = AVMutableAudioMixInputParameters(); p.trackID = id
						let base: Float = id == 1 ? 0.8 : 1
						p.setVolume(base, at: .zero)
						if id != 3 {
							p.setVolumeRamp(fromStartVolume: base, toEndVolume: base * 0.5, timeRange: CMTimeRange(start: t(0.4), duration: t(0.1)))
							p.setVolume(base * 0.5, at: t(0.5))
							p.setVolumeRamp(fromStartVolume: base * 0.5, toEndVolume: base, timeRange: CMTimeRange(start: t(1.5), duration: t(0.1)))
						}
						return p
					}
					return mix
				}
				let video = try await source.loadTracks(withMediaType: .video).first
				if let video {
					let picture = stereoComp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
					for (index, cut) in cuts.enumerated() { try picture.insertTimeRange(cut, of: video, at: t(Double(index))) }
					picture.preferredTransform = try await video.load(.preferredTransform)
				}
				let quality = try await MediaQuality.inspect(source)
				let intermediate = try ExportFile(name:"Stereo",suffix:"mov")
				let exporter = try await MediaExportSupport.exporter(asset: stereoComp, video: video != nil, hdr: quality.hdr, type: .mov)
				exporter.audioMix = mix()
				exporter.timeRange = CMTimeRange(start:.zero,duration:t(2))
				try await exporter.export(to: intermediate.url, as:.mov)
				let plan = SpatialProjectAudio(asset:composition,mix:mix(),nativeTrackIDs:[1],monoTrackIDs:[3],nativeGains:[1:[
					SpatialGainRamp(range:CMTimeRange(start:t(0),duration:t(0.4)),start:0.8,end:0.8),
					SpatialGainRamp(range:CMTimeRange(start:t(0.4),duration:t(0.1)),start:0.8,end:0.4),
					SpatialGainRamp(range:CMTimeRange(start:t(0.5),duration:t(1)),start:0.4,end:0.4),
					SpatialGainRamp(range:CMTimeRange(start:t(1.5),duration:t(0.1)),start:0.4,end:0.8),
					SpatialGainRamp(range:CMTimeRange(start:t(1.6),duration:t(0.4)),start:0.8,end:0.8)
				]])
				let description = try await native.load(.formatDescriptions)[0]
				let sourceChannels = Int(CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee.mChannelsPerFrame)
				let continuous = try await read(source,track:native,channels:sourceChannels,duration:5,requiredStart:0.5,requiredEnd:4)
				let decoded = Array(continuous[(24000*sourceChannels)..<(72000*sourceChannels)]) + Array(continuous[(144000*sourceChannels)..<(192000*sourceChannels)])
				var original = [Float](repeating: 0, count: 96000 * 5)
				for frame in 0..<96000 { for channel in 0..<sourceChannels { original[frame*5+channel] = decoded[frame*sourceChannels+channel] } }
				var expected = original
				for frame in 0..<96000 {
					let seconds = Double(frame)/rate
					let duck = seconds < 0.4 || seconds >= 1.6 ? 1 : seconds < 0.5 ? 1-(seconds-0.4)*5 : seconds < 1.5 ? 0.5 : 0.5+(seconds-1.5)*5
					for channel in 0..<5 { expected[frame*5+channel] *= Float(0.8*duck) }
					if seconds >= 0.25 && seconds < 1.25 {
						let phase = seconds-0.25
						let l = Float(sin(phase*2 * .pi*440)*0.02*duck), r = Float(sin(phase*2 * .pi*660)*0.02*duck)
						expected[frame*5] += (l+r)/2
						expected[frame*5+1] += (l-r)/4
						expected[frame*5+3] += (l+r)/2 * Float(sqrt(3)/2)
					}
					if seconds >= 0.5 && seconds < 1.5 { expected[frame*5+4] += Float(sin((seconds-0.5)*2 * .pi*880)*0.02) }
				}
				let reference = expected

				let result = try await plan.render(stereoMovie:intermediate.url,duration:t(2),name:"Spatial") { buffer, first in
					let values = buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
					for index in 0..<(Int(buffer.frameLength) * 5) {
						try require(abs(values[index] - reference[Int(first) * 5 + index]) < 0.00001, "Uncompressed mix mismatch at frame \(first + Int64(index / 5))")
					}
				}
				print("PASS PCM", name, "source preservation, front stereo, center narration, fades, whole-program ducking, timing")
				try await MediaExportSupport.validate(result.url, hdr: quality.hdr)
				let rendered = AVURLAsset(url:result.url)
				if let picture = try await rendered.loadTracks(withMediaType: .video).first {
					let reader = try AVAssetReader(asset: rendered)
					let frames = AVAssetReaderTrackOutput(track: picture, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
					reader.add(frames)
					try require(reader.startReading(), "Video decoder failed to start")
					var frameCount = 0
					while let sample = frames.copyNextSampleBuffer() {
						try require(CMSampleBufferGetImageBuffer(sample) != nil, "Missing decoded video frame")
						frameCount += 1
					}
					try require(reader.status == .completed && frameCount > 0, "Video decoding failed")
					let range = try await picture.load(.timeRange)
					try require(abs(range.start.seconds) < 0.05 && abs(range.duration.seconds - 2) < 0.05, "Video/audio timing mismatch")
					print("PASS synchronized HDR video", frameCount, "decoded frames")
				}
				var spatialTrack: AVAssetTrack!
				for track in try await rendered.loadTracks(withMediaType:.audio) {
					if try await track.load(.formatDescriptions).contains(where:{CMFormatDescriptionGetMediaSubType($0)==kAudioFormatAPAC}) { spatialTrack=track }
				}
				let renderedFallback = try await spatialTrack.loadAssociatedTracks(ofType: .audioFallback)[0]
				let stereoAsset = AVURLAsset(url: intermediate.url)
				let stereoTrack = try await stereoAsset.loadTracks(withMediaType: .audio)[0]
				let stereoReference = try await read(stereoAsset, track: stereoTrack, channels: 2)
				let stereoResult = try await read(rendered, track: renderedFallback, channels: 2)
				try require(zip(stereoReference, stereoResult).allSatisfy { abs($0 - $1) < 0.000001 }, "Stereo fallback changed during spatial export")
				print("PASS stereo fallback samples")
				let actual = try await read(rendered,track:spatialTrack,channels:5)
				for channel in 0..<5 {
					let reference = stride(from:channel,to:expected.count,by:5).reduce(0.0) { $0+Double(expected[$1]*expected[$1]) }
					let observed = stride(from:channel,to:actual.count,by:5).reduce(0.0) { $0+Double(actual[$1]*actual[$1]) }
					if reference < 0.00000001 {
						try require(observed < 0.00000001, "Signal leaked into a silent channel")
						print(name, "channel", channel, "remains silent")
						continue
					}
					let ratio = sqrt(observed/reference)
					print(name,"channel",channel,"RMS ratio",ratio)
					try require(abs(ratio-1)<0.12,"channel level mismatch")
				}
				print("PASS",name,"spatial source + stereo + mono, gain, ducking, fades, timestamps, APAC group:",result.url.path)
			}
		} catch { print("FAIL",error); exit(1) }
	}
}

nonisolated enum ProbeFiles {
	static var root: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
}

nonisolated final class ExportFile: Sendable {
	let url: URL
	init(name: String, suffix: String) throws {
		url = ProbeFiles.root.appendingPathComponent(name + "-" + UUID().uuidString).appendingPathExtension(suffix)
	}
}

nonisolated struct ProjectFailure: LocalizedError {
	let message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}
