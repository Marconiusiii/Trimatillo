import MessageUI
import StoreKit
import SwiftUI

struct SettingsView: View {
	@ObservedObject var support: SupportStore
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	@AppStorage("appearance", store: EditorPreferences.shared) private var appearance = EditorAppearance.system
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
