import AVFoundation
#if canImport(Cinematic)
import Cinematic
#endif

// Standalone reproduction: no project files, APAC encoder, audio playback, or UI.
@main struct ChannelLayoutCheck {
	static func mixedLayout() -> AVAudioChannelLayout {
		let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
		let size = offset + 5 * MemoryLayout<AudioChannelDescription>.size
		let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
		defer { raw.deallocate() }
		raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
		let header = raw.assumingMemoryBound(to: AudioChannelLayout.self)
		header.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
		header.pointee.mNumberChannelDescriptions = 5
		let channels = raw.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
		for channel in 0..<4 { channels[channel].mChannelLabel = kAudioChannelLabel_HOA_ACN_0 + UInt32(channel) }
		channels[4].mChannelLabel = kAudioChannelLabel_Center
		channels[4].mChannelFlags = .sphericalCoordinates
		channels[4].mCoordinates = (0, 0, 1)
		return AVAudioChannelLayout(layout: header)
	}

	static func matrix(_ layout: AVAudioChannelLayout, name: String) throws -> Bool {
		let count = Int(layout.channelCount)
		var pointers = [layout.layout, layout.layout]
		var equivalent: UInt32 = 0
		var size = UInt32(MemoryLayout<UInt32>.size)
		let equivalenceStatus = pointers.withUnsafeMutableBytes {
			AudioFormatGetProperty(kAudioFormatProperty_AreChannelLayoutsEquivalent, UInt32($0.count), $0.baseAddress, &size, &equivalent)
		}
		var coefficients = [Float](repeating: 0, count: count * count)
		size = UInt32(coefficients.count * MemoryLayout<Float>.size)
		let status = pointers.withUnsafeMutableBytes {
			AudioFormatGetProperty(kAudioFormatProperty_MatrixMixMap, UInt32($0.count), $0.baseAddress, &size, &coefficients)
		}
		guard status == noErr, equivalenceStatus == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status != noErr ? status : equivalenceStatus)) }
		print(name, "equivalent:", equivalent, "matrix:", coefficients)
		let identity = coefficients.indices.allSatisfy { abs(coefficients[$0] - ($0 / count == $0 % count ? 1 : 0)) < 0.000001 }
		print(identity && equivalent == 1 ? "PASS identity matrix" : "FAIL identity matrix", name)
		return identity && equivalent == 1
	}

	static func pcm(_ layout: AVAudioChannelLayout, explicit: Bool) throws {
		let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: true, channelLayout: layout)
		guard let converter = AVAudioConverter(from: format, to: format),
			let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128),
			let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128) else { throw CocoaError(.featureUnsupported) }
		if explicit { converter.channelMap = [0, 1, 2, 3, 4] }
		input.frameLength = 128
		let data = input.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
		for active in 0..<5 {
			converter.reset()
			data.update(repeating: 0, count: 128 * 5)
			for frame in 0..<128 { data[frame * 5 + active] = 0.1 }
			try converter.convert(to: output, from: input)
			guard output.frameLength == 128 else { throw CocoaError(.fileReadCorruptFile) }
			let samples = output.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
			guard (0..<(128*5)).allSatisfy({ abs(samples[$0] - ($0 % 5 == active ? 0.1 : 0)) < 0.000001 }) else { throw CocoaError(.fileReadCorruptFile) }
		}
		print("PASS same-format PCM conversion; explicit channel map:", explicit)
	}

	static func main() async {
		setbuf(stdout, nil)
		do {
			print("OS", ProcessInfo.processInfo.operatingSystemVersionString)
			let stereo = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
			let foa = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_HOA_ACN_SN3D | 4)!
			let mixed = mixedLayout()
			let stereoPass = try matrix(stereo, name: "Stereo")
			let foaPass = try matrix(foa, name: "Four-channel FOA")
			let mixedPass = try matrix(mixed, name: "FOA plus center")
			try pcm(mixed, explicit: false)
			try pcm(mixed, explicit: true)
			#if canImport(Cinematic)
			if let path = CommandLine.arguments.dropFirst().first {
				let info = try await CNAssetSpatialAudioInfo(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
				guard let data = info.assetWriterInputSettings(for: .spatial)[AVChannelLayoutKey] as? Data else { throw CocoaError(.fileReadCorruptFile) }
				let raw = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: MemoryLayout<AudioChannelLayout>.alignment)
				defer { raw.deallocate() }
				data.copyBytes(to: raw.assumingMemoryBound(to: UInt8.self), count: data.count)
				let apple = AVAudioChannelLayout(layout: raw.assumingMemoryBound(to: AudioChannelLayout.self))
				print("Apple helper layout equals reproduction:", apple == mixed)
				_ = try matrix(apple, name: "Apple helper spatial writer layout")
			}
			#endif
			if !stereoPass || !foaPass || !mixedPass { exit(1) }
		} catch { print("ERROR", error); exit(2) }
	}
}
