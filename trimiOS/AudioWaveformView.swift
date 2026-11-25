import AVFoundation
import SwiftUI

// A bounded amplitude overview of the edited audio, independent of playback.
nonisolated enum AudioWaveformAnalyzer {
	@concurrent static func samples(asset: AVAsset, count: Int = 2048) async throws -> [Float] {
		let duration = try await asset.load(.duration).seconds
		let available = try await asset.loadTracks(withMediaType: .audio)
		let tracks: [AVAssetTrack]
		if asset is AVComposition { tracks = available }
		else {
			var selected = available.first
			for track in available where try await track.load(.isEnabled) { selected = track; break }
			tracks = selected.map { [$0] } ?? []
		}
		guard duration.isFinite, duration > 0, !tracks.isEmpty, count > 0 else { return [] }
		try Task.checkCancellation()
		let reader = try AVAssetReader(asset: asset)
		let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVSampleRateKey: 12000,
			AVNumberOfChannelsKey: 2,
			AVLinearPCMIsFloatKey: true,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsNonInterleaved: false
		])
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else { throw CocoaError(.fileReadUnsupportedScheme) }
		reader.add(output)
		guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
		defer { reader.cancelReading() }
		var peaks = [Float](repeating: 0, count: count)
		while reader.status == .reading {
			try Task.checkCancellation()
			guard let sample = output.copyNextSampleBuffer() else { break }
			guard let block = CMSampleBufferGetDataBuffer(sample),
				let format = CMSampleBufferGetFormatDescription(sample),
				let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { continue }
			let channels = Int(description.pointee.mChannelsPerFrame)
			let rate = description.pointee.mSampleRate
			let frames = CMSampleBufferGetNumSamples(sample)
			let bytes = CMBlockBufferGetDataLength(block)
			guard channels == 2, rate.isFinite, rate > 0, frames > 0,
				bytes <= 4 * 1024 * 1024, bytes / MemoryLayout<Float>.size / channels >= frames else {
				throw CocoaError(.fileReadCorruptFile)
			}
			var values = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
			let result = values.withUnsafeMutableBytes {
				CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
			}
			guard result == noErr else { throw CocoaError(.fileReadCorruptFile) }
			let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
			guard start.isFinite else { continue }
			for frame in 0..<frames {
				let fraction = (start + Double(frame) / rate) / duration
				guard fraction >= 0, fraction < 1 else { continue }
				let bucket = min(count - 1, Int(fraction * Double(count)))
				for channel in 0..<channels {
					let value = abs(values[frame * channels + channel])
					if value.isFinite { peaks[bucket] = max(peaks[bucket], min(value, 1)) }
				}
			}
		}
		try Task.checkCancellation()
		guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
		return peaks
	}
}

struct AudioWaveformView<Cursor: View>: View {
	let item: AVPlayerItem?
	@ViewBuilder var cursor: () -> Cursor
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal
	@State private var samples: [Float] = []
	@State private var status = "Preparing audio waveform"

	var body: some View {
		ZStack {
			EditorTheme.surface
			WaveformDrawing(samples: samples, color: color.accent).equatable()
				.accessibilityHidden(true)
			cursor().accessibilityHidden(true)
			if status == "Preparing audio waveform" {
				ProgressView("Preparing audio waveform").padding()
			} else if !status.isEmpty {
				Text(status).multilineTextAlignment(.center).padding()
			}
		}
		.clipped()
		.task(id: item) {
			samples = []
			status = "Preparing audio waveform"
			guard let item else { return }
			do {
				let result = try await AudioWaveformAnalyzer.samples(asset: item.asset)
				try Task.checkCancellation()
				samples = result
				status = result.isEmpty ? "No audio waveform" : ""
			} catch {
				guard !Task.isCancelled else { return }
				status = "Could not load the waveform. Reopen the clip or project to try again."
			}
		}
	}
}

private struct WaveformDrawing: View, Equatable {
	let samples: [Float]
	let color: Color
	var body: some View {
		Canvas(rendersAsynchronously: true) { context, size in
			var path = Path()
			let count = max(samples.count, 1)
			for (index, peak) in samples.enumerated() {
				let x = (CGFloat(index) + 0.5) / CGFloat(count) * size.width
				let half = max(CGFloat(peak) * size.height * 0.42, 0.5)
				path.move(to: CGPoint(x: x, y: size.height / 2 - half))
				path.addLine(to: CGPoint(x: x, y: size.height / 2 + half))
			}
			context.stroke(path, with: .color(color), lineWidth: max(size.width / CGFloat(count), 1))
		}
	}
}

struct WaveformPlayhead: View {
	let position: CMTime
	let duration: CMTime
	var body: some View {
		GeometryReader { geometry in
			let fraction = duration.seconds > 0 && position.isNumeric ? min(1, max(0, position.seconds / duration.seconds)) : 0
			Rectangle().fill(EditorTheme.playhead)
				.frame(width: 3)
				.offset(x: max(0, geometry.size.width - 3) * fraction)
		}
	}
}

struct ClipWaveformPlayhead: View {
	@ObservedObject var playhead: CuttingBoardPlayhead
	let duration: CMTime
	var body: some View { WaveformPlayhead(position: playhead.position, duration: duration) }
}

struct WaveformSelection: View {
	let range: CMTimeRange?
	let duration: CMTime
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal
	var body: some View {
		Canvas { context, size in
			guard let range, duration.seconds > 0 else { return }
			let left = size.width * min(1, max(0, range.start.seconds / duration.seconds))
			let right = size.width * min(1, max(0, range.end.seconds / duration.seconds))
			var path = Path()
			path.addRect(CGRect(x: left, y: size.height - 6, width: max(0, right - left), height: 4))
			path.addRect(CGRect(x: left, y: size.height - 12, width: 3, height: 10))
			path.addRect(CGRect(x: max(left, right - 3), y: size.height - 12, width: 3, height: 10))
			context.fill(path, with: .color(color.accent))
		}
	}
}
