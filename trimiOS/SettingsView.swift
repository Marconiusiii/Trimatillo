import MessageUI
import StoreKit
import SwiftUI

struct SettingsView: View {
	@ObservedObject var support: SupportStore
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	@AppStorage("appearance", store: EditorPreferences.shared) private var appearance = EditorAppearance.system
	@AppStorage("showAudioWaveforms", store: EditorPreferences.shared) private var showAudioWaveforms = false
	@AppStorage("shakeToUndo", store: EditorPreferences.shared) private var shake = true
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@AppStorage("directTouchScrubbing", store: EditorPreferences.shared) private var scrubbing = DirectTouchScrubbing.absolute
	@State private var composing = false
	@State private var mailFailed = false
	@AccessibilityFocusState private var feedbackFocused: Bool

	@Environment(\.scenePhase) private var scenePhase
	@AccessibilityFocusState(for: .voiceOver) private var focusedOption: String?
	@State private var selectedOption: String?
	@State private var returnFocus: String?
	@State private var confirmation: SupportStore.Receipt?
	@State private var notice: String?

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Picker("Appearance", selection: $appearance) {
						ForEach(EditorAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
					Picker("Control Color", selection: $color) {
						ForEach(ControlColor.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
					Toggle("Show Audio Waveforms", isOn: $showAudioWaveforms)
				} header: { heading("Appearance") }
				Section {
					Picker("Timecode", selection: $format) {
						ForEach(TimecodeFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
					Picker("Direct Touch Scrubbing", selection: $scrubbing) {
						ForEach(DirectTouchScrubbing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
					Toggle("Shake to Undo", isOn: $shake)
				} header: { heading("Editing") }
				Section {
					NavigationLink("Audio") { RecordingRouteSettings() }
					NavigationLink("Storage") { StorageSettingsView() }
				}
				supportSection
				Section {
					Button("Send App Feedback") {
						if MFMailComposeViewController.canSendMail() {
							composing = true
						} else if let url = MailComposerView.fallback {
							openURL(url) { if !$0 { mailFailed = true } }
						}
					}
					.accessibilityFocused($feedbackFocused)
					.sheet(isPresented: $composing, onDismiss: { feedbackFocused = true }) {
						MailComposerView { failed in
							composing = false
							mailFailed = failed
						}
					}
					Link("Privacy Policy", destination: URL(string: "https://marconius.com/trimato/privacy/")!)
						.accessibilityRemoveTraits(.isButton)
						.accessibilityAddTraits(.isLink)
				} header: { heading("About") } footer: {
					let year = Calendar(identifier: .gregorian).component(.year, from: Date())
					Text(verbatim: "© \(year) Marco Salsiccia, \(MailComposerView.version)")
				}
			}
			.editorListMargins()
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle("Settings")
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
			}
			.alert("Send App Feedback", isPresented: $mailFailed) {
				Button("OK") { feedbackFocused = true }
			} message: { Text("Email marco@marconius.com with your feedback.") }
		}
		.editorAppearance()
		.task { await support.load() }
		.task(id: scenePhase == .active && !support.purchasing ? returnFocus : nil) {
			guard scenePhase == .active, !support.purchasing, let returnFocus else { return }
			focusedOption = returnFocus
			self.returnFocus = nil
		}
		.sheet(item: $confirmation, onDismiss: { returnFocus = selectedOption }) { receipt in
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					Text("Contribution Received").font(.title2).accessibilityAddTraits(.isHeader)
					Text(support.thankYou(for: receipt))
					Button("Done") { confirmation = nil }
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding()
			}
			.presentationBackground(EditorTheme.workspace)
			.editorAppearance()
		}
		.alert("Support Trimatillo", isPresented: Binding(get: { notice != nil }, set: {
			if !$0 { notice = nil; returnFocus = selectedOption }
		})) {
			Button("OK") {}
		} message: { Text(notice ?? "") }
	}

	private func heading(_ title: String) -> some View {
		Text(title).editorTouchRow(alignment: .leading).accessibilityAddTraits(.isHeader)
	}

	private var supportSection: some View {
		Section {
			Text("If Trimatillo helps you make the cut, you can support future updates with a one-time contribution. Thanks for pitching in!")
			if let latest = support.latest { Text(support.thankYou(for: latest)) }
			if support.catalogState == .loading || support.catalogState == .idle {
				ProgressView("Loading support options")
			}
			ForEach(SupportStore.options) { option in
				let product = support.products[option.id]
				Button {
					Task { await purchase(option) }
				} label: {
					LabeledContent(product?.displayName ?? option.name, value: product?.displayPrice ?? "Price unavailable")
				}
				.disabled(product == nil || support.purchasing)
				.accessibilityFocused($focusedOption, equals: option.id)
			}
			if support.catalogState == .incomplete {
				Text("Some support options could not be loaded.")
				Button("Retry") { Task { await support.load() } }
			}
		} header: {
			heading("Support Trimatillo")
		}
	}

	private func purchase(_ option: SupportStore.Option) async {
		selectedOption = option.id
		switch await support.buy(option) {
		case .received(let receipt): confirmation = receipt
		case .cancelled: returnFocus = option.id
		case .pending: notice = "Your purchase is waiting for approval."
		case .unverified: notice = "The App Store could not verify this purchase. Check your purchase history."
		case .failed: notice = "Could not complete the purchase. Check your App Store account and try again."
		}
	}
}

private struct StorageSettingsView: View {
	@Environment(\.scenePhase) private var phase
	@State private var sizes: (projects: Int64, temporary: Int64, available: Int64)?
	@State private var managing = false
	@State private var pending: EditingProject?
	@State private var opened: EditingProject?
	@State private var refreshing = 0
	@State private var clearing = false
	@State private var scanFailed = false
	@State private var failure: String?
	@AccessibilityFocusState private var manageFocused: Bool

	var body: some View {
		Form {
			if let sizes {
				LabeledContent("Projects", value: ProjectStorage.formatted(sizes.projects))
					.accessibilityElement(children: .combine)
				Button("Manage Projects") { managing = true }
					.accessibilityFocused($manageFocused)
				LabeledContent("Temporary Files", value: ProjectStorage.formatted(sizes.temporary))
					.accessibilityElement(children: .combine)
				if sizes.temporary > sizes.available {
					LabeledContent("In Use", value: ProjectStorage.formatted(sizes.temporary - sizes.available))
						.accessibilityElement(children: .combine)
				}
				Button("Clear Temporary Files") { clearing = true }
					.disabled(clearing || sizes.available == 0)
			} else if !scanFailed {
				ProgressView("Checking storage")
			} else {
				Button("Check Storage") { refreshing += 1 }
			}
		}
		.editorListMargins()
		.scrollContentBackground(.hidden)
		.background(EditorTheme.workspace)
		.navigationTitle("Storage")
		.task(id: refreshing) {
			do {
				let value = try await ProjectStorage.sizes()
				try Task.checkCancellation()
				sizes = value
				scanFailed = false
			} catch {
				if !Task.isCancelled { scanFailed = true; failure = "Could not read storage. Reopen Storage to check again." }
			}
		}
		.task(id: clearing) {
			guard clearing else { return }
			do { try await ProjectStorage.clearTemporaryFiles() }
			catch { failure = "Could not clear temporary files. Open Storage and try again." }
			clearing = false
			refreshing += 1
		}
		.onReceive(NotificationCenter.default.publisher(for: ProjectStorage.didClean)) { _ in refreshing += 1 }
		.onChange(of: phase) { _, phase in if phase == .active { refreshing += 1 } }
		.sheet(isPresented: $managing, onDismiss: {
			if let pending { opened = pending; self.pending = nil }
			else { manageFocused = true; refreshing += 1 }
		}) {
			ProjectLauncherView(mode: .open) { pending = $0 }
		}
		.fullScreenCover(item: $opened, onDismiss: { manageFocused = true; refreshing += 1 }) { project in
			ProjectWorkspaceView(project: project) { opened = nil }
		}
		.alert("Storage", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("OK") {}
		} message: { Text(failure ?? "") }
	}
}
