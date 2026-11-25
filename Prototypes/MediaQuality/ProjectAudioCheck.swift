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
	static func read(_ asset: AVAsset, track: AVAssetTrack, channels: Int, start: Double = 0) async throws -> [Float] {
		let reader = try AVAssetReader(asset: asset)
		reader.timeRange = CMTimeRange(start: t(start), duration: t(2))
		let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: SpatialChannelMap.settings(channels: channels, pcm: true))
		reader.add(output)
		try require(reader.startReading(), "reader start: \(String(describing: reader.error))")
		var result = [Float](repeating: 0, count: 96000 * channels)
		var coverage = Set<Int>()
		while let sample = output.copyNextSampleBuffer() {
			let format = AVAudioFormat(cmAudioFormatDescription: CMSampleBufferGetFormatDescription(sample)!)
			let count = CMSampleBufferGetNumSamples(sample)
			let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!; buffer.frameLength = UInt32(count)
			try require(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == 0, "PCM copy")
			let data = buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
			let offset = Int(((CMSampleBufferGetPresentationTimeStamp(sample).seconds - start) * rate).rounded())
			for frame in max(0,offset)..<max(0,min(96000, offset+count)) {
				for channel in 0..<channels { result[frame*channels+channel] = data[(frame-offset)*channels+channel] }
				coverage.insert(frame)
			}
		}
		try require(reader.status == .completed, "reader finish: \(String(describing: reader.error))")
		try require(coverage.count == 96000, "missing frames \(96000-coverage.count)")
		return result
	}
	static func checkIsolation() async throws {
		let file = try ExportFile(name: "Isolated-W", suffix: "mov")
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
			for frame in 0..<count { data[frame*5] = Float(sin(Double(first+frame)*2 * .pi*440/rate)*0.1) }
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
		print("Isolated W expected RMS", 0.1 / sqrt(2), "in channel 0, zero elsewhere")
		print("Isolated W decoded RMS", levels)
		try require(abs(levels[0] - 0.1 / sqrt(2)) < 0.001 && levels.dropFirst().allSatisfy { $0 < 0.001 }, "APAC round trip changed channel isolation")
		print("PASS channel isolation")
	}

	static func main() async {
		setbuf(stdout, nil)
		do {
			try require(CommandLine.arguments.count > 2, "Usage: project-audio-check NEW_OUTPUT_DIRECTORY SOURCE_MOVIE [SOURCE_MOVIE ...]")
			try require(!FileManager.default.fileExists(atPath: ProbeFiles.root.path), "Choose a new output directory.")
			try FileManager.default.createDirectory(at: ProbeFiles.root, withIntermediateDirectories: true)
			if CommandLine.arguments[2] == "--isolation" { try await checkIsolation(); return }
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
				try raw.insertTimeRange(CMTimeRange(start: t(0.5), duration: t(2)), of: native, at: .zero)
				let compatibility = stereoComp.addMutableTrack(withMediaType: .audio, preferredTrackID: 1)!
				try compatibility.insertTimeRange(CMTimeRange(start: t(0.5), duration: t(2)), of: fallback, at: .zero)
				
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
				let intermediate = try ExportFile(name:"Stereo",suffix:"m4a")
				let exporter = AVAssetExportSession(asset: stereoComp, presetName: AVAssetExportPresetAppleM4A)!
				exporter.audioMix = mix()
				exporter.timeRange = CMTimeRange(start:.zero,duration:t(2))
				try await exporter.export(to: intermediate.url, as:.m4a)
				let plan = SpatialProjectAudio(asset:composition,mix:mix(),nativeTrackIDs:[1],monoTrackIDs:[3],nativeGains:[1:[
					SpatialGainRamp(range:CMTimeRange(start:t(0),duration:t(0.4)),start:0.8,end:0.8),
					SpatialGainRamp(range:CMTimeRange(start:t(0.4),duration:t(0.1)),start:0.8,end:0.4),
					SpatialGainRamp(range:CMTimeRange(start:t(0.5),duration:t(1)),start:0.4,end:0.4),
					SpatialGainRamp(range:CMTimeRange(start:t(1.5),duration:t(0.1)),start:0.4,end:0.8),
					SpatialGainRamp(range:CMTimeRange(start:t(1.6),duration:t(0.4)),start:0.8,end:0.8)
				]])
				let original = try await read(source,track:native,channels:5,start:0.5)
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
				let rendered = AVURLAsset(url:result.url)
				var spatialTrack: AVAssetTrack!
				for track in try await rendered.loadTracks(withMediaType:.audio) {
					if try await track.load(.formatDescriptions).contains(where:{CMFormatDescriptionGetMediaSubType($0)==kAudioFormatAPAC}) { spatialTrack=track }
				}
				let actual = try await read(rendered,track:spatialTrack,channels:5)
				for channel in 0..<5 {
					let reference = stride(from:channel,to:expected.count,by:5).reduce(0.0) { $0+Double(expected[$1]*expected[$1]) }
					let observed = stride(from:channel,to:actual.count,by:5).reduce(0.0) { $0+Double(actual[$1]*actual[$1]) }
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
