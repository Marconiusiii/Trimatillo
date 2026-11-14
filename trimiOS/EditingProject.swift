import AVFoundation
import Foundation

nonisolated struct ProjectTime: Codable, Equatable {
	let value: Int64
	let scale: Int32

	init(_ time: CMTime) {
		value = time.value
		scale = time.timescale
	}

	var time: CMTime { CMTime(value: value, timescale: scale) }
}

nonisolated struct ProjectRange: Codable, Equatable {
	let start: ProjectTime
	let length: ProjectTime

	init(_ range: CMTimeRange) {
		start = ProjectTime(range.start)
		length = ProjectTime(range.duration)
	}

	var range: CMTimeRange { CMTimeRange(start: start.time, duration: length.time) }
}

nonisolated enum ProjectTrack: String, Codable, CaseIterable {
	case video = "Video"
	case audio = "Audio"
}

nonisolated struct ProjectPlacement: Identifiable, Codable, Equatable {
	var id = UUID()
	let sourceID: UUID
	var track: ProjectTrack
	var start: ProjectTime
	var ranges: [ProjectRange]
	var duration: CMTime { ranges.reduce(.zero) { $0 + $1.length.time } }
	var end: CMTime { start.time + duration }
}

nonisolated struct ProjectPicture: Codable, Equatable {
	var width: Int
	var height: Int
	var frame: ProjectTime
}

nonisolated struct EditingProject: Identifiable, Codable, Equatable {
	var id = UUID()
	var version = 1
	var name: String
	var picture: ProjectPicture?
	var targetSeconds: Double?
	var sources: [ProjectMediaSource] = []
	var placements: [ProjectPlacement] = []
	var markIn: ProjectTime?
	var markOut: ProjectTime?

	var duration: CMTime { placements.map(\.end).max() ?? .zero }
	var frame: CMTime { picture?.frame.time ?? CMTime(value: 1, timescale: 30) }

	func clips(on track: ProjectTrack) -> [ProjectPlacement] {
		placements.filter { $0.track == track }.sorted { $0.start.time < $1.start.time }
	}

	mutating func place(_ source: ProjectMediaSource, ranges: [CMTimeRange], at start: CMTime, replacing id: UUID?) throws {
		let placement = ProjectPlacement(id: id ?? UUID(), sourceID: source.id,
			track: source.picture == nil ? .audio : .video, start: ProjectTime(start), ranges: ranges.map(ProjectRange.init))
		guard !ranges.isEmpty, ranges.allSatisfy({ $0.isValid && $0.start >= .zero && $0.duration > .zero && $0.end <= source.duration.time }) else {
			throw ProjectFailure("The edit is outside the source clip. Reopen the clip and adjust its boundaries.")
		}
		guard !placements.contains(where: { $0.id != id && $0.track == placement.track && $0.start.time < placement.end && $0.end > start }) else {
			throw ProjectFailure("There is a clip at that time on the track. Choose Append or move the playhead to an open space.")
		}
		placements.removeAll { $0.id == id }
		placements.append(placement)
		if picture == nil { picture = source.picture }
	}
}

nonisolated struct ProjectFailure: LocalizedError {
	let message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}

enum ProjectLibrary {
	static let directory = URL.documentsDirectory.appendingPathComponent("Projects", isDirectory: true)

	static func load(_ url: URL) throws -> EditingProject {
		let project = try JSONDecoder().decode(EditingProject.self, from: Data(contentsOf: url))
		guard project.version == 1 else { throw ProjectFailure("Update Trimatillo to open this project.") }
		return project
	}

	static func savedFiles() throws -> [URL] {
		guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
		return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "json" }
	}

	static func save(_ project: EditingProject, replacing previous: EditingProject? = nil) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appending(component: project.id.uuidString + ".json")
		if let previous, try load(url) != previous {
			throw ProjectFailure("This project changed in another window. Close and reopen it before editing.")
		}
		try JSONEncoder().encode(project).write(to: url, options: .atomic)
	}
}
