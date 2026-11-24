import AVFoundation
import SwiftUI

struct TimelineShiftRequest: Identifiable {
	let id = UUID()
	let title: String
	var clips: Set<UUID> = []
	var transcripts: Set<UUID> = []
	var descriptions: Set<UUID> = []
	var captions: Set<UUID> = []
}

extension EditingProject {
	var initialDescriptionTimeline: DescriptionTimeline {
		audioDescriptions?.isEmpty == false || descriptiveTranscript?.isEmpty != false ? .audio : .transcript
	}

	mutating func shift(_ request: TimelineShiftRequest, by seconds: Double) throws {
		guard seconds.isFinite, seconds != 0, abs(seconds) < Double(Int64.max) / 600000 else {
			throw ProjectFailure("Enter a valid number of seconds greater than zero.")
		}
		let amount = CMTime(seconds: seconds, preferredTimescale: 600000)
		var next = self
		func moved(_ time: ProjectTime) throws -> ProjectTime {
			let value = time.time + amount
			guard value.isNumeric, value >= .zero else { throw ProjectFailure("This shift moves content before the project start. Enter a smaller amount.") }
			return ProjectTime(value)
		}
		for i in next.placements.indices where request.clips.contains(next.placements[i].id) {
			next.placements[i].start = try moved(next.placements[i].start)
		}
		for i in next.descriptiveTranscript?.indices ?? 0..<0 where request.transcripts.contains(next.descriptiveTranscript![i].id) {
			next.descriptiveTranscript![i].start = try moved(next.descriptiveTranscript![i].start)
			next.descriptiveTranscript![i].end = try moved(next.descriptiveTranscript![i].end)
		}
		for i in next.audioDescriptions?.indices ?? 0..<0 where request.descriptions.contains(next.audioDescriptions![i].id) {
			next.audioDescriptions![i].start = try moved(next.audioDescriptions![i].start)
			next.audioDescriptions![i].limit = try moved(next.audioDescriptions![i].limit)
		}
		for i in next.captions?.indices ?? 0..<0 where request.captions.contains(next.captions![i].id) {
			next.captions![i].start = try moved(next.captions![i].start)
			next.captions![i].end = try moved(next.captions![i].end)
		}
		func check(_ rows: [(UUID, CMTime, CMTime)], selected: Set<UUID>) throws {
			let stationary = rows.filter { !selected.contains($0.0) }
			guard !stationary.isEmpty else { return }
			for row in rows where selected.contains(row.0) {
				guard !stationary.contains(where: { $0.1 < row.2 && row.1 < $0.2 }) else {
					throw ProjectFailure("This shift overlaps other content on the timeline. Change the amount or include those clips in the group.")
				}
			}
		}
		for track in next.tracks {
			try check(next.displayedClips(on: track).map { ($0.id, $0.start.time, $0.end) }, selected: request.clips)
		}
		try check((next.descriptiveTranscript ?? []).map { ($0.id, $0.start.time, $0.end.time) }, selected: request.transcripts)
		try check((next.audioDescriptions ?? []).map { ($0.id, $0.start.time, $0.end) }, selected: request.descriptions)
		try check((next.captions ?? []).map { ($0.id, $0.start.time, $0.end.time) }, selected: request.captions)
		let ends = (next.descriptiveTranscript ?? []).filter { request.transcripts.contains($0.id) }.map { $0.end.time }
			+ (next.audioDescriptions ?? []).filter { request.descriptions.contains($0.id) }.map { $0.limit.time }
			+ (next.captions ?? []).filter { request.captions.contains($0.id) }.map { $0.end.time }
		guard ends.allSatisfy({ $0 <= next.duration }) else { throw ProjectFailure("This shift moves timed entries beyond the project end. Extend the project or enter a smaller amount.") }
		next.cleanTransitions()
		try next.validateTransitions()
		self = next
	}

	func shiftOtherTracksRequest(excluding track: TimelineTrack, from time: CMTime) -> TimelineShiftRequest {
		let protected = Set([track.id, track.videoPartnerID].compactMap { $0 })
		return TimelineShiftRequest(title: "Shift Other Tracks",
			clips: Set(placements.filter { !protected.contains($0.trackID) && $0.start.time >= time }.map(\.id)),
			transcripts: Set((descriptiveTranscript ?? []).filter { $0.start.time >= time }.map(\.id)),
			descriptions: Set((audioDescriptions ?? []).filter { $0.start.time >= time }.map(\.id)),
			captions: Set((captions ?? []).filter { $0.start.time >= time }.map(\.id)))
	}
}

struct TimelineShiftView: View {
	let request: TimelineShiftRequest
	let apply: (Double) throws -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var later = true
	@State private var seconds = ""
	@State private var error: String?
	@FocusState private var typing: Bool

	var body: some View {
		NavigationStack {
			Form {
				Picker("Direction", selection: $later) { Text("Earlier").tag(false); Text("Later").tag(true) }
				TextField("", text: $seconds).keyboardType(.decimalPad).focused($typing).editorFieldLabel("Seconds")
				Button("Shift") {
					let input = seconds.trimmingCharacters(in: .whitespacesAndNewlines)
					guard !input.isEmpty else { error = "Enter the number of seconds to shift."; return }
					guard let value = try? Double(input, format: .number), value.isFinite else { error = "Enter a valid number of seconds."; return }
					guard value > 0 else { error = "Enter a number greater than zero. Choose Earlier or Later for the direction."; return }
					do { try apply(later ? value : -value); dismiss() }
					catch { self.error = error.localizedDescription }
				}
			}
			.dismissKeyboardToolbar(while: typing) { typing = false }
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .principal) { Text(request.title).accessibilityAddTraits(.isHeader) }

			}
			.alert("Could Not Shift", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
		}.editorAppearance()
	}
}
