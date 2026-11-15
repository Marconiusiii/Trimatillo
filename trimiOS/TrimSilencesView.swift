import AVFoundation
import SwiftUI

struct TrimSilencesView: View {
	let session: CuttingBoardSession
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@Environment(\.dismiss) private var dismiss
	@State private var decibels = -40
	@State private var minimum = 0.6
	@State private var retained = 0.15
	@State private var markedOnly = true
	@State private var pauses: [SilencePause]?
	@State private var activity: String?
	@State private var task: Task<Void, Never>?
	@State private var failure: String?
	@State private var preview: PreviewPlayback?
	@AccessibilityFocusState private var previewFocus: Int?
	@State private var previewTrigger = -1

	var body: some View {
		NavigationStack {
			Group {
				if let activity {
					ProgressView(activity)
				} else {
					Form {
						if pauses == nil {
							settings
						} else {
							review
						}
					}
					.editorListMargins()
				}
			}
			.navigationTitle("Trim Silences")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Cancel") {
						if task != nil { task?.cancel() } else { dismiss() }
					}
				}
			}
		}
		.editorAppearance()
		.interactiveDismissDisabled(activity != nil)
		.onDisappear { task?.cancel() }
		.fullScreenCover(item: $preview, onDismiss: { previewFocus = previewTrigger }) { playback in
			FullScreenPreview(playback: playback)
		}
		.alert("Trim Silences", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("OK") { failure = nil }
		} message: { Text(failure ?? "") }
	}

	private var settings: some View {
		Group {
			Stepper("Silence threshold, \(decibels) dB", value: $decibels, in: -80 ... -10)
			Stepper("Minimum silence, \(minimum.formatted()) seconds", value: $minimum, in: 0.1 ... 10, step: 0.1)
			Stepper("Retained silence, \(retained.formatted()) seconds", value: $retained, in: 0 ... 2, step: 0.05)
			if session.selection != nil {
				Toggle("Only Between In and Out", isOn: $markedOnly)
			}
			Button("Find Pauses") {
				run("Finding pauses") {
					let whole = CMTimeRange(start: .zero, duration: session.duration)
					pauses = try await session.silencePauses(range: markedOnly ? session.selection ?? whole : whole,
						decibels: decibels, minimum: minimum, retained: retained)
				}
			}
		}
	}

	@ViewBuilder private var review: some View {
		let results = pauses ?? []
		if results.isEmpty { Text("No pauses found") }
		if !results.isEmpty {
			let removed = results.filter(\.included).reduce(CMTime.zero) { $0 + $1.cut.duration }
			Text("Time to remove, " + session.timecode(removed, format: .milliseconds))
		}
		let enabled = results.contains(where: \.included)
		Button("Preview Trimmed Clip") { play(-1) }
			.disabled(!enabled)
			.accessibilityFocused($previewFocus, equals: -1)
		Button("Apply Cuts") {
			run("Applying cuts") {
				try await session.applySilenceCuts(results)
				dismiss()
			}
		}
		.disabled(!enabled)
		Button("Change Detection Settings") { pauses = nil }
		ForEach(results.indices, id: \.self) { index in
			let pause = results[index]
			Section {
				Toggle("Remove Pause \(index + 1)", isOn: Binding(get: { pause.included }, set: { pauses?[index].included = $0 }))
				Button("Play Pause \(index + 1) in Context") {
					let second = CMTime(value: 1, timescale: 1)
					play(index, context: CMTimeRange(start: max(.zero, pause.cut.start - second),
						end: min(session.duration, pause.cut.end + second)))
				}
				.accessibilityFocused($previewFocus, equals: index)
				boundary(index, start: true)
				boundary(index, start: false)
			} header: { Text("Pause \(index + 1)").accessibilityAddTraits(.isHeader) }
		}

	}

	private func boundary(_ index: Int, start: Bool) -> some View {
		let results = pauses ?? []
		let pause = results[index]
		let time = start ? pause.cut.start : pause.cut.end
		func change(_ count: Int) -> (() -> Void)? {
			let next = session.stepped(from: time, by: count)
			guard next != time, next >= pause.limits.start, next <= pause.limits.end else { return nil }
			if start {
				guard next < pause.cut.end, index == 0 || next >= results[index - 1].cut.end else { return nil }
			} else {
				guard next > pause.cut.start, index + 1 == results.count || next <= results[index + 1].cut.start else { return nil }
			}
			return {
				pauses?[index].cut = CMTimeRange(start: start ? next : pause.cut.start, end: start ? pause.cut.end : next)
			}
		}
		return Stepper((start ? "Start, " : "End, ") + session.timecode(time, format: format),
			onIncrement: change(1), onDecrement: change(-1))
	}

	private func play(_ trigger: Int, context: CMTimeRange? = nil) {
		previewTrigger = trigger
		run("Preparing preview") {
			let item = try await session.silencePreview(pauses, context: context)
			try Task.checkCancellation()
			preview = PreviewPlayback(item: item, start: .zero, rate: 1) { _ in }
		}
	}

	private func run(_ label: String, operation: @escaping @MainActor () async throws -> Void) {
		guard task == nil else { return }
		activity = label
		task = Task {
			defer { activity = nil; task = nil }
			do { try await operation() }
			catch { if !Task.isCancelled { failure = error.localizedDescription } }
		}
	}
}
