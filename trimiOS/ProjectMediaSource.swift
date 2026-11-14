import AVFoundation
import Photos

final class ProjectMediaAccess {
	let asset: AVAsset
	private let scoped: URL?

	init(asset: AVAsset, scoped: URL? = nil) {
		self.asset = asset
		self.scoped = scoped
	}

	deinit { scoped?.stopAccessingSecurityScopedResource() }
}

nonisolated struct ProjectMediaSource: Codable, Equatable, Identifiable {
	enum Reference: Codable, Equatable {
		case file(Data)
		case photos(local: String, cloud: String?)
	}

	var id = UUID()
	let name: String
	var reference: Reference
	let duration: ProjectTime
	let picture: ProjectPicture?
	let hasAudio: Bool

	@MainActor static func file(_ url: URL) async throws -> Self {
		let accessed = url.startAccessingSecurityScopedResource()
		defer { if accessed { url.stopAccessingSecurityScopedResource() } }
		let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
		return try await inspect(asset: AVURLAsset(url: url), name: url.lastPathComponent, reference: .file(data))
	}

	@MainActor static func photo(_ id: String) async throws -> Self {
		let photo = try await photoAsset(id, cloud: nil)
		let asset = try await video(photo)
		let name = PHAssetResource.assetResources(for: photo).first { $0.type == .video || $0.type == .fullSizeVideo }?.originalFilename ?? "Video"
		let result = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [id])[id]
		let cloud = (try? result?.get())?.stringValue
		return try await inspect(asset: asset, name: name, reference: .photos(local: id, cloud: cloud))
	}

	@MainActor private static func inspect(asset: AVAsset, name: String, reference: Reference) async throws -> Self {
		let duration = try await asset.load(.duration)
		let video = try await asset.loadTracks(withMediaType: .video).first
		let audio = try await asset.loadTracks(withMediaType: .audio).first
		guard duration.isNumeric, duration > .zero, video != nil || audio != nil else {
			throw ProjectFailure("Choose a playable video or audio clip.")
		}
		var picture: ProjectPicture?
		if let video {
			let size = try await video.load(.naturalSize)
			let oriented = size.applying(try await video.load(.preferredTransform))
			var frame = try await video.load(.minFrameDuration)
			if !frame.isNumeric || frame <= .zero {
				let rate = try await video.load(.nominalFrameRate)
				guard rate > 0 else { throw ProjectFailure("Choose a video with a readable frame rate.") }
				frame = CMTime(seconds: 1 / Double(rate), preferredTimescale: 600000)
			}
			picture = ProjectPicture(width: Int(abs(oriented.width).rounded()), height: Int(abs(oriented.height).rounded()), frame: ProjectTime(frame))
		}
		return Self(name: name, reference: reference, duration: ProjectTime(duration), picture: picture, hasAudio: audio != nil)
	}

	@MainActor private static func photoAsset(_ id: String, cloud: String?) async throws -> PHAsset {
		let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
		guard status == .authorized || status == .limited else {
			throw ProjectFailure("Allow access to the selected video in Settings, then choose it again.")
		}
		if let photo = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject { return photo }
		if let cloud {
			let key = PHCloudIdentifier(stringValue: cloud)
			if let mapping = PHPhotoLibrary.shared().localIdentifierMappings(for: [key])[key],
				let local = try? mapping.get(), let photo = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject { return photo }
		}
		throw ProjectFailure("Open Project Media and reconnect the video from Photos.")
	}

	@MainActor private static func video(_ photo: PHAsset) async throws -> AVAsset {
		let options = PHVideoRequestOptions()
		options.isNetworkAccessAllowed = true
		options.deliveryMode = .highQualityFormat
		return try await withCheckedThrowingContinuation { continuation in
			PHImageManager.default().requestAVAsset(forVideo: photo, options: options) { asset, _, _ in
				if let asset { continuation.resume(returning: asset) }
				else { continuation.resume(throwing: ProjectFailure("Download the video in Photos, then reopen it.")) }
			}
		}
	}

	@MainActor func open() async throws -> ProjectMediaAccess {
		switch reference {
		case .file(let data):
			var stale = false
			let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
			let accessed = url.startAccessingSecurityScopedResource()
			return ProjectMediaAccess(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]), scoped: accessed ? url : nil)
		case .photos(let local, let cloud):
			let photo = try await Self.photoAsset(local, cloud: cloud)
			return ProjectMediaAccess(asset: try await Self.video(photo))
		}
	}
}
