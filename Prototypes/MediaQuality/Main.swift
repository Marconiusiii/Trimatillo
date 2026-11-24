import Foundation
import AVFoundation

struct ProbeFailure: Error, CustomStringConvertible {
	let description: String
	init(_ message: String) { description = message }
}

func require(_ condition: Bool, _ message: String) throws {
	if !condition { throw ProbeFailure(message) }
}

func ready(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
	let deadline = Date().addingTimeInterval(30)
	while !input.isReadyForMoreMediaData {
		try Task.checkCancellation()
		try require(writer.status == .writing, "Writer stopped: \(String(describing: writer.error))")
		try require(Date() < deadline, "Writer stalled for 30 seconds")
		try await Task.sleep(for: .milliseconds(2))
	}
}

func finish(_ writer: AVAssetWriter) async throws {
	await writer.finishWriting()
	try require(writer.status == .completed, "Writer failed: \(String(describing: writer.error))")
}

func fourCC(_ value: UInt32) -> String {
	String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }, encoding: .ascii) ?? String(value)
}

func inspect(_ url: URL) async throws {
	let asset = AVURLAsset(url: url)
	print("FILE \(url.lastPathComponent): \(try await asset.load(.duration).seconds) seconds")
	for track in try await asset.load(.tracks) {
		let formats = try await track.load(.formatDescriptions)
		for format in formats {
			print("  track \(track.trackID) \(track.mediaType.rawValue) \(fourCC(CMFormatDescriptionGetMediaSubType(format))) enabled=\(try await track.load(.isEnabled))")
			if let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
				var size = 0
				let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size)
				print("  channels=\(audio.pointee.mChannelsPerFrame) sampleRate=\(audio.pointee.mSampleRate) layout=\(layout?.pointee.mChannelLayoutTag ?? 0)")
				if let layout, layout.pointee.mNumberChannelDescriptions > 0 {
					let descriptions = UnsafeRawPointer(layout).advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!).assumingMemoryBound(to: AudioChannelDescription.self)
					for index in 0..<Int(layout.pointee.mNumberChannelDescriptions) {
						print("  channel \(index) label=\(descriptions[index].mChannelLabel)")
					}
				}
			} else {
				print("  \(String(describing: CMFormatDescriptionGetExtensions(format)))")
			}
		}
	}
	for group in try await asset.load(.trackGroups) {
		print("  alternate group: \(group.trackIDs)")
	}
}

@main struct MediaQualityProbe {
	static func main() async {
		do {
			let args = Array(CommandLine.arguments.dropFirst())
			guard let destination = args.first else {
				throw ProbeFailure("Usage: media-quality OUTPUT_DIRECTORY [IPHONE_MOVIE]")
			}
			let root = URL(fileURLWithPath: destination, isDirectory: true)
			try require(!FileManager.default.fileExists(atPath: root.path), "Choose a new output directory; existing results are never overwritten")
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			try await HDRProbe.run(root)
			try await SpatialProbe.run(root)
			if args.count > 1 {
				let source = URL(fileURLWithPath: args[1])
				try await inspect(source)
				try await HDRProbe.camera(source, root: root)
				try await SpatialProbe.camera(source, root: root)
			} else {
				print("NOT RUN: real iPhone Spatial Audio metadata and camera HDR validation; no source supplied")
			}
			print("Synthetic checks completed. Physical iPhone playback and app integration remain unverified.")
		} catch {
			fputs("FAILED: \(error)\n", stderr)
			exit(1)
		}
	}
}
