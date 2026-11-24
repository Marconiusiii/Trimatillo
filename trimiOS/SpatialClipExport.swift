import AVFoundation

// Cutting Board cuts only. Project mixes require a separate channel-aware renderer.
@available(iOS 26, *)
nonisolated enum SpatialClipExport {
	static func render(source: AVAsset, ranges: [CMTimeRange], videoAsset: AVAsset, quality: MediaQuality,
		name: String) async throws -> ExportFile {
		let audio = try await source.loadTracks(withMediaType: .audio)
		var spatial: AVAssetTrack?
		for track in audio {
			if try await track.load(.formatDescriptions).contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatAPAC }) { spatial = track; break }
		}
		guard let spatial else { throw MediaExportFailure.spatialPreservation }
		let fallback = try await spatial.loadAssociatedTracks(ofType: .audioFallback)
		guard let stereo = fallback.first, audio.count == 2 else { throw MediaExportFailure.spatialPreservation }
		let composition = AVMutableComposition()
		var inputs: [(AVCompositionTrack, [String: Any], [String: Any])] = []
		for (index, original) in [stereo, spatial].enumerated() {
			guard let format = try await original.load(.formatDescriptions).first,
				let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format),
				let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
				throw MediaExportFailure.spatialPreservation
			}
			var layoutSize = 0
			guard let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutSize), layoutSize > 0 else { throw MediaExportFailure.spatialPreservation }
			let channels = audio.pointee.mChannelsPerFrame
			if index == 0 {
				guard channels == 2 else { throw MediaExportFailure.spatialPreservation }
			} else {
				let tag = layout.pointee.mChannelLayoutTag
				let foa = channels == 4 && tag == (kAudioChannelLayoutTag_HOA_ACN_SN3D | 4)
				var foaCenter = false
				if channels == 5 && tag == kAudioChannelLayoutTag_UseChannelDescriptions && layout.pointee.mNumberChannelDescriptions == 5 {
					let descriptions = UnsafeRawPointer(layout).advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!).assumingMemoryBound(to: AudioChannelDescription.self)
					foaCenter = (0..<4).allSatisfy { descriptions[$0].mChannelLabel == kAudioChannelLabel_HOA_ACN_0 + UInt32($0) } && descriptions[4].mChannelLabel == kAudioChannelLabel_Center
				}
				guard foa || foaCenter else { throw MediaExportFailure.spatialPreservation }
			}
			let data = Data(bytes: layout, count: layoutSize)
			let base: [String: Any] = [AVSampleRateKey: audio.pointee.mSampleRate, AVNumberOfChannelsKey: channels, AVChannelLayoutKey: data]
			var pcm = base
			pcm[AVFormatIDKey] = kAudioFormatLinearPCM
			pcm[AVLinearPCMIsFloatKey] = true
			pcm[AVLinearPCMBitDepthKey] = 32
			pcm[AVLinearPCMIsNonInterleaved] = false
			var encoding = base
			encoding[AVFormatIDKey] = index == 0 ? kAudioFormatMPEG4AAC : kAudioFormatAPAC
			var cursor = CMTime.zero
			let available = try await original.load(.timeRange)
			for range in ranges {
				try Task.checkCancellation()
				let overlap = CMTimeRangeGetIntersection(range, otherRange: available)
				if overlap.isValid && !overlap.isEmpty { try destination.insertTimeRange(overlap, of: original, at: cursor + overlap.start - range.start) }
				cursor = cursor + range.duration
			}
			inputs.append((destination, pcm, encoding))
		}
		let duration = ranges.reduce(CMTime.zero) { $0 + $1.duration }
		if composition.duration < duration { composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: duration)) }
		let videoFile: ExportFile?
		if try await !videoAsset.loadTracks(withMediaType: .video).isEmpty {
			let file = try ExportFile(name: "Video", suffix: "mov")
			let exporter = try await MediaExportSupport.exporter(asset: videoAsset, video: true, hdr: quality.hdr, type: .mov)
			exporter.timeRange = CMTimeRange(start: .zero, duration: duration)
			try await exporter.export(to: file.url, as: .mov)
			videoFile = file
		} else { videoFile = nil }
		let output = try ExportFile(name: name, suffix: "mov")
		try await encode(composition: composition, inputs: inputs, video: videoFile?.url, duration: duration, output: output.url)
		withExtendedLifetime(videoFile) {}
		try await MediaExportSupport.validate(output.url, hdr: quality.hdr, preserveAudioFrom: source)
		let renderedDuration = try await AVURLAsset(url: output.url).load(.duration)
		guard abs((renderedDuration - duration).seconds) < 0.05 else { throw MediaExportFailure.invalidOutput }
		return output
	}

	@concurrent private static func encode(composition: AVComposition, inputs: [(AVCompositionTrack, [String: Any], [String: Any])],
		video: URL?, duration: CMTime, output: URL) async throws {
		let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
		let reader = try AVAssetReader(asset: composition)
		var readers = [reader]
		var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
		for (track, pcm, encoding) in inputs {
			guard writer.canApply(outputSettings: encoding, forMediaType: .audio) else { throw MediaExportFailure.spatialPreservation }
			let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encoding)
			let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
			output.alwaysCopiesSampleData = false
			guard reader.canAdd(output), writer.canAdd(input) else { throw MediaExportFailure.spatialPreservation }
			reader.add(output)
			writer.add(input)
			pairs.append((output, input))
		}
		pairs[1].1.marksOutputTrackAsEnabled = false
		pairs[1].1.addTrackAssociation(withTrackOf: pairs[0].1, type: AVAssetTrack.AssociationType.audioFallback.rawValue)
		writer.add(AVAssetWriterInputGroup(inputs: pairs.map(\.1), defaultInput: pairs[0].1))
		if let video {
			let asset = AVURLAsset(url: video)
			guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaExportFailure.invalidOutput }
			let picture = try AVAssetReader(asset: asset)
			let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
			let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: try await track.load(.formatDescriptions).first)
			input.transform = try await track.load(.preferredTransform)
			guard picture.canAdd(output), writer.canAdd(input) else { throw MediaExportFailure.invalidOutput }
			picture.add(output)
			writer.add(input)
			pairs.append((output, input))
			readers.append(picture)
		}
		var finished = false
		defer {
			if !finished { readers.forEach { $0.cancelReading() }; writer.cancelWriting() }
		}
		guard writer.startWriting() else { throw writer.error ?? MediaExportFailure.spatialPreservation }
		writer.startSession(atSourceTime: .zero)
		for reader in readers { guard reader.startReading() else { throw reader.error ?? MediaExportFailure.spatialPreservation } }
		var pending = Set(pairs.indices)
		var lastProgress = Date()
		while !pending.isEmpty {
			try Task.checkCancellation()
			var advanced = false
			for index in pending.sorted() {
				let (source, destination) = pairs[index]
				guard destination.isReadyForMoreMediaData else { continue }
				if let sample = source.copyNextSampleBuffer() {
					guard destination.append(sample) else { throw writer.error ?? MediaExportFailure.invalidOutput }
				} else {
					destination.markAsFinished()
					pending.remove(index)
				}
				advanced = true
			}
			guard writer.status == .writing else { throw writer.error ?? MediaExportFailure.invalidOutput }
			if advanced { lastProgress = Date() }
			else {
				guard Date().timeIntervalSince(lastProgress) < 30 else { throw MediaExportFailure.invalidOutput }
				try await Task.sleep(for: .milliseconds(5))
			}
		}
		for reader in readers { guard reader.status == .completed else { throw reader.error ?? MediaExportFailure.invalidOutput } }
		writer.endSession(atSourceTime: duration)
		await writer.finishWriting()
		guard writer.status == .completed else { throw writer.error ?? MediaExportFailure.invalidOutput }
		finished = true
	}
}
