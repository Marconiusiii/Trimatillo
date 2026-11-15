import AVFoundation
import SwiftUI

struct TrimSilencesView: View {
	let session: CuttingBoardSession
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@Environment(\.dismiss) private var dismiss
	@State private var decibels = -40.0
	@State private var minimum = 0.6
	@State private var retained = 0.15
	@State private var markedOnly = true
	@State private var pauses: [SilencePause]?
	@State private var activity: String?
	@State private var task: Task<Void, Never>?
	@State private var noPausesMessage: String?
	@AccessibilityFocusState private var findPausesFocused: Bool
	@State private var failure: String?
	@State private var showingPreview = false
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
		.fullScreenCover(isPresented: $showingPreview, onDismiss: { previewFocus = previewTrigger }) {
			SilencePreviewSheet(session: session, pauses: pauses ?? [], index: previewTrigger)
		}
		.alert("No Pauses Found", isPresented: Binding(get: { noPausesMessage != nil }, set: {
			if !$0 { noPausesMessage = nil }
		})) {
			Button("OK") {}
		} message: { Text(noPausesMessage ?? "") }
		.onChange(of: noPausesMessage) { previous, current in
			if previous != nil && current == nil { findPausesFocused = true }
		}
		.alert("Trim Silences", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("OK") { failure = nil }
		} message: { Text(failure ?? "") }
	}

	private var settings: some View {
		Group {
			valueSlider("Silence threshold", reading: "\(Int(decibels)) dB", value: $decibels, range: -80 ... -10, step: 1)
			valueSlider("Minimum silence", reading: "\(minimum.formatted()) seconds", value: $minimum, range: 0.1 ... 10, step: 0.1)
			valueSlider("Retained silence", reading: "\(retained.formatted()) seconds", value: $retained, range: 0 ... 2, step: 0.05)
			if session.selection != nil {
				Toggle("Only Between In and Out", isOn: $markedOnly)
			}
			Button("Find Pauses") {
				run("Finding pauses") {
					let whole = CMTimeRange(start: .zero, duration: session.duration)
					let selection = markedOnly ? session.selection : nil
					let found = try await session.silencePauses(range: selection ?? whole,
						decibels: Int(decibels), minimum: minimum, retained: retained)
					try Task.checkCancellation()
					if found.isEmpty {
						noPausesMessage = selection == nil ? "No pauses matched these settings in the clip."
							: "No pauses matched these settings in the marked range."
					} else {
						pauses = found
					}
				}
			}
			.accessibilityFocused($findPausesFocused)
		}
	}

	@ViewBuilder private var review: some View {
		let results = pauses ?? []
		let removed = results.filter(\.included).reduce(CMTime.zero) { $0 + $1.cut.duration }
		let milliseconds = removed.convertScale(1000, method: .roundHalfAwayFromZero).value
		let digits = [1000, 100, 10].firstIndex { milliseconds.isMultiple(of: Int64($0)) } ?? 3
		let duration = Duration.milliseconds(milliseconds).formatted(.units(allowed: [.hours, .minutes, .seconds],
			width: .wide, fractionalPart: .show(length: digits)))
		Text("Time to remove, " + duration)
			.accessibilityLabel("Time to remove")
			.accessibilityValue(Text(duration))
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
				Button("Open Pause \(index + 1) Preview") { play(index) }
				.accessibilityFocused($previewFocus, equals: index)
				boundary(index, in: results, start: true)
				boundary(index, in: results, start: false)
			} header: { Text("Pause \(index + 1)").accessibilityAddTraits(.isHeader) }
		}

	}

	private func valueSlider(_ name: String, reading: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
		VStack(alignment: .leading) {
			Text(name + ", " + reading)
				.accessibilityHidden(true)
			Slider(value: value, in: range, step: step) { Text(name) }
				.labelsHidden()
				.accessibilityValue(Text(reading))
		}
	}

	private func boundary(_ index: Int, in results: [SilencePause], start: Bool) -> some View {
		let pause = results[index]
		let current = start ? pause.cut.start : pause.cut.end
		let earliest = max(pause.limits.start, index > 0 ? results[index - 1].cut.end : .zero)
		let latest = min(pause.limits.end, index + 1 < results.count ? results[index + 1].cut.start : session.duration)
		let lower: Int64
		let upper: Int64
		let position: Int64
		if session.hasVideo {
			let first = session.frameNumber(at: earliest)
			let firstTime = session.time(atFrame: first, sourceTime: false) ?? earliest
			let last = session.frameNumber(at: latest)
			lower = start ? first + (firstTime < earliest ? 1 : 0) : session.frameNumber(at: pause.cut.start) + 1
			upper = start ? session.frameNumber(at: pause.cut.end) - 1 : last
			position = session.frameNumber(at: current)
		} else {
			// Keep the original sample offset while moving in Cutting Board audio steps.
			let scale: CMTimeScale = 30
			let anchor = pause.limits.start
			let offset = (current - anchor).convertScale(scale, method: .roundTowardNegativeInfinity)
			let origin = current - offset
			let first = (earliest - origin).convertScale(scale, method: .roundTowardPositiveInfinity).value
			let last = (latest - origin).convertScale(scale, method: .roundTowardNegativeInfinity).value
			lower = start ? first : max(first, (pause.cut.start - origin).convertScale(scale, method: .roundTowardNegativeInfinity).value + 1)
			upper = start ? min(last, (pause.cut.end - origin).convertScale(scale, method: .roundTowardPositiveInfinity).value - 1) : last
			position = offset.value
		}
		let value = Binding<Double>(get: { Double(position) }, set: { proposed in
			let selected = Int64(proposed.rounded())
			guard selected >= lower, selected <= upper else { return }
			let next: CMTime
			if session.hasVideo {
				guard let time = session.time(atFrame: selected, sourceTime: false) else { return }
				next = time
			} else {
				next = current + CMTime(value: selected - position, timescale: 30)
			}
			pauses?[index].cut = CMTimeRange(start: start ? next : pause.cut.start, end: start ? pause.cut.end : next)
		})
		return valueSlider("Pause \(index + 1) " + (start ? "Start" : "End"), reading: session.timecode(current, format: format),
			value: value, range: Double(lower) ... Double(max(lower + 1, upper)), step: 1)
			.disabled(lower >= upper)
	}

	private func play(_ trigger: Int) {
		previewTrigger = trigger
		showingPreview = true
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

private struct SilencePreviewSheet: View {
	let session: CuttingBoardSession
	let pauses: [SilencePause]
	let index: Int
	@Environment(\.dismiss) private var dismiss
	@State private var playback: PreviewPlayback?
	@State private var failed = false

	private var title: String { index < 0 ? "Trimmed Silence Preview" : "Pause \(index + 1) Preview" }

	var body: some View {
		Group {
			if let playback {
				FullScreenPreview(playback: playback, title: title)
			} else {
				NavigationStack {
					Group {
						if failed {
							Text("Could not prepare the preview. Close it and open it again.")
						} else {
							ProgressView("Preparing preview")
						}
					}
					.navigationBarTitleDisplayMode(.inline)
					.toolbar {
						ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
						ToolbarItem(placement: .principal) {
							Text(title).font(.headline).accessibilityAddTraits(.isHeader)
						}
					}
				}
			}
		}
		.editorAppearance()
		.task {
			guard playback == nil else { return }
			do {
				var context: CMTimeRange?
				if index >= 0 {
					let cut = pauses[index].cut
					let second = CMTime(value: 1, timescale: 1)
					context = CMTimeRange(start: max(.zero, cut.start - second), end: min(session.duration, cut.end + second))
				}
				let item = try await session.silencePreview(pauses, context: context)
				try Task.checkCancellation()
				playback = PreviewPlayback(item: item, start: .zero, rate: 1) { _ in }
			} catch { if !Task.isCancelled { failed = true } }
		}
	}
}
