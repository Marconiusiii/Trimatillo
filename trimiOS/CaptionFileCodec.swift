import Foundation
import CoreMedia

nonisolated enum CaptionFileCodec {
	static func encode(_ cues: [CaptionCue], format: CaptionFileFormat) throws -> Data {
		let sorted = try cues.map { try $0.validated() }.sorted {
			if $0.start.time == $1.start.time { return $0.end.time < $1.end.time }
			return $0.start.time < $1.start.time
		}
		let body: String
		if format == .subRip {
			body = sorted.enumerated().map { index, cue in
				"\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(escaped(cue.text))"
			}.joined(separator: "\n\n")
		} else {
			body = sorted.map { cue in
				return "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(escaped(cue.text))"
			}.joined(separator: "\n\n")
		}
		let result = (format == .webVTT ? "WEBVTT\n\n" : "") + body + (body.isEmpty ? "" : "\n")
		return Data(result.utf8)
	}

	static func encodePlainText(_ cues: [CaptionCue], projectTitle: String) throws -> Data {
		let sorted = try cues.map { try $0.validated() }.sorted {
			if $0.start.time == $1.start.time { return $0.end.time < $1.end.time }
			return $0.start.time < $1.start.time
		}
		let paragraphs = sorted.map { cue in
			cue.text.components(separatedBy: .newlines)
				.map { $0.trimmingCharacters(in: .whitespaces) }
				.filter { !$0.isEmpty }
				.joined(separator: " ")
		}
		.filter { !$0.isEmpty }
		let title = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		let body = paragraphs.joined(separator: "\n\n")
		let result = title + (body.isEmpty ? "" : "\n\n\(body)") + "\n"
		return Data(result.utf8)
	}

	private static func escaped(_ text: String) -> String {
		text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }.joined(separator: "\n")
			.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
	}

	private static func timestamp(_ time: ProjectTime, separator: String) -> String {
		let milliseconds = max(Int((time.seconds * 1_000).rounded()), 0)
		return String(format: "%02lld:%02lld:%02lld%@%03lld", milliseconds / 3_600_000,
					(milliseconds / 60_000) % 60, (milliseconds / 1_000) % 60,
					separator, milliseconds % 1_000)
	}

}
