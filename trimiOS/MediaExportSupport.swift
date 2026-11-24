import AVFoundation
import CoreImage

nonisolated struct MediaQuality: Sendable {
	var hdr = false
	var spatialAudio = false
	var multichannelAudio = false
	var needsAudioChoice: Bool { spatialAudio || multichannelAudio }

	static func inspect(_ asset: AVAsset) async throws -> Self {
		var result = Self()
		for track in try await asset.loadTracks(withMediaType: .video) {
			for format in try await track.load(.formatDescriptions) {
				let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
				if transfer == AVVideoTransferFunction_ITU_R_2100_HLG || transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ { result.hdr = true }
			}
		}
		for track in try await asset.loadTracks(withMediaType: .audio) {
			for format in try await track.load(.formatDescriptions) {
				if CMFormatDescriptionGetMediaSubType(format) == kAudioFormatAPAC { result.spatialAudio = true }
				if let description = CMAudioFormatDescriptionGetStreamBasicDescription(format), description.pointee.mChannelsPerFrame > 2 { result.multichannelAudio = true }
			}
		}
		return result
	}

	mutating func include(_ other: Self) {
		hdr = hdr || other.hdr
		spatialAudio = spatialAudio || other.spatialAudio
		multichannelAudio = multichannelAudio || other.multichannelAudio
	}

	static func playbackAudioTrack(_ asset: AVAsset) async throws -> AVAssetTrack? {
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		for track in tracks where try await track.load(.isEnabled) { return track }
		return tracks.first
	}

	static func playbackAudioTracks(_ asset: AVAsset) async throws -> [AVAssetTrack] {
		var result: [AVAssetTrack] = []
		for track in try await asset.loadTracks(withMediaType: .audio) {
			if try await track.load(.isEnabled) { result.append(track) }
		}
		return result
	}
}

nonisolated enum MediaExportFailure: LocalizedError {
	case spatialProcessing, hdrUnavailable, spatialPreservation, invalidOutput
	var errorDescription: String? {
		switch self {
		case .spatialProcessing:
			return "This mix cannot be exported with its original audio layout. Choose Export in Stereo."
		case .hdrUnavailable:
			return "HDR export is unavailable for this media on this device. Use a device that supports 10-bit HEVC export."
		case .spatialPreservation:
			return "This edit cannot preserve the original audio layout. Choose Export in Stereo."
		case .invalidOutput:
			return "The export did not retain the required media format. Cancel the export and reopen the clip."
		}
	}
}

nonisolated enum MediaExportSupport {
	static let hdrColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
	static let hdrWorkingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

	static func configureHDR(_ video: AVMutableVideoComposition) {
		video.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
		video.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
		video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
		video.perFrameHDRDisplayMetadataPolicy = .generate
	}

	static func markHDR(_ buffer: CVPixelBuffer) {
		CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
		CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
		CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
	}

	static func exporter(asset: AVAsset, video: Bool, hdr: Bool, type: AVFileType) async throws -> AVAssetExportSession {
		let preset = video ? (hdr ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality) : AVAssetExportPresetAppleM4A
		let compatible = await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: type)
		guard compatible, let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
			if hdr { throw MediaExportFailure.hdrUnavailable }
			throw CocoaError(.featureUnsupported)
		}
		return exporter
	}

	static func validate(_ url: URL, hdr: Bool, preserveAudioFrom source: AVAsset? = nil) async throws {
		let output = AVURLAsset(url: url)
		let quality = try await MediaQuality.inspect(output)
		if hdr && !quality.hdr { throw MediaExportFailure.invalidOutput }
		if hdr {
			for track in try await output.loadTracks(withMediaType: .video) {
				for format in try await track.load(.formatDescriptions) {
					let fields = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
					guard (fields["BitsPerComponent"] as? Int ?? 0) >= 10 else { throw MediaExportFailure.invalidOutput }
				}
			}
		}
		if let source {
			func signatures(_ asset: AVAsset) async throws -> [String] {
				var result: [String] = []
				for track in try await asset.loadTracks(withMediaType: .audio) {
					for format in try await track.load(.formatDescriptions) {
						if let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
							var size = 0
							var layoutDescription = "none"
							if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size) {
								layoutDescription = "\(layout.pointee.mChannelLayoutTag):\(layout.pointee.mChannelBitmap)"
								let descriptions = UnsafeRawPointer(layout).advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!).assumingMemoryBound(to: AudioChannelDescription.self)
								for index in 0..<Int(layout.pointee.mNumberChannelDescriptions) {
									layoutDescription += ":\(descriptions[index].mChannelLabel)"
								}
							}
							result.append("\(CMFormatDescriptionGetMediaSubType(format)):\(audio.pointee.mChannelsPerFrame):\(audio.pointee.mSampleRate):\(layoutDescription)")
						}
					}
				}
				return result.sorted()
			}
			guard try await signatures(source) == signatures(output) else { throw MediaExportFailure.spatialPreservation }
			let originalGroups = try await source.load(.trackGroups)
			let outputGroups = try await output.load(.trackGroups)
			if !originalGroups.isEmpty && outputGroups.isEmpty { throw MediaExportFailure.spatialPreservation }
			for track in try await output.loadTracks(withMediaType: .audio) {
				if try await track.load(.formatDescriptions).contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatAPAC }) {
					let fallback = try await track.loadAssociatedTracks(ofType: .audioFallback)
					guard !fallback.isEmpty, outputGroups.contains(where: { group in
						group.trackIDs.contains(NSNumber(value: track.trackID)) && fallback.contains { group.trackIDs.contains(NSNumber(value: $0.trackID)) }
					}) else { throw MediaExportFailure.spatialPreservation }
				}
			}
		}
	}
}
