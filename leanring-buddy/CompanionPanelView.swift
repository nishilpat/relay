//
//  CompanionPanelView.swift
//
//  Relay AE Command Center — the floating panel opened from the menu bar icon.
//  Shows three tabs: recent customer intakes from the Relay link, a post-call
//  notes form for pasting meeting transcripts, and Claude-generated follow-through
//  outputs (email, Salesforce note, Slack update, tasks, etc.).
//

import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 0) {
            relayPanelHeader
            relayTabBar
            relayTabContent
            relayPanelFooter
        }
        .frame(minWidth: 420, maxWidth: .infinity)
        .background(DS.Colors.background)
        .task {
            // Initial load, then auto-poll every 30 seconds so new customer
            // submissions appear without the AE needing to click refresh.
            while !Task.isCancelled {
                await companionManager.fetchRelayRecentIntakes()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Header

    private var relayPanelHeader: some View {
        HStack(spacing: 10) {
            // Relay logo — three circles. Fades to a tinted state during active voice use.
            RelayLogoView(size: 14)
                .opacity(companionManager.voiceState == .idle ? 1.0 : 0.5)
                .animation(.easeInOut(duration: 0.3), value: companionManager.voiceState)

            Text("Relay")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            // Voice state label — only visible when push-to-talk is active.
            if companionManager.voiceState != .idle {
                Text(voiceStateLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(voiceStateDotColor)
                    .transition(.opacity)
            } else {
                Text("AE Command Center")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Button(action: {
                // Play the subtle enter chime before refreshing
                if let soundURL = Bundle.main.url(forResource: "enter", withExtension: "mp3") {
                    NSSound(contentsOf: soundURL, byReference: false)?.play()
                }
                Task { await companionManager.fetchRelayRecentIntakes() }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(companionManager.relayIsLoadingIntakes ? DS.Colors.accent : DS.Colors.textTertiary)
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Auto-refreshes every 30s · Click to refresh now")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(DS.Colors.surface1)
        .animation(.easeInOut(duration: 0.2), value: companionManager.voiceState)
    }

    private var voiceStateLabel: String {
        switch companionManager.voiceState {
        case .idle:       return ""
        case .listening:  return "Listening…"
        case .processing: return "Processing…"
        case .responding: return "Responding…"
        }
    }

    private var voiceStateDotColor: Color {
        switch companionManager.voiceState {
        case .idle:       return DS.Colors.accent
        case .listening:  return Color(hex: "#16a34a")  // green
        case .processing: return Color(hex: "#ca8a04")  // amber
        case .responding: return Color(hex: "#9333ea")  // purple
        }
    }

    // MARK: - Tab Bar

    private var relayTabBar: some View {
        HStack(spacing: 0) {
            relayTabButton(label: "Customer Asks", tab: .customerAsks)
            relayTabButton(label: "Post-Call Notes", tab: .postCallNotes)
            relayTabButton(label: "Outputs", tab: .outputs)
        }
        .background(DS.Colors.surface1)
        .overlay(Divider().background(DS.Colors.borderSubtle), alignment: .bottom)
    }

    private func relayTabButton(label: String, tab: RelayActiveTab) -> some View {
        let isSelected = companionManager.relayActiveTab == tab

        return Button(action: { companionManager.relayActiveTab = tab }) {
            VStack(spacing: 0) {
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)

                Rectangle()
                    .fill(isSelected ? DS.Colors.accent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .frame(maxWidth: .infinity)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var relayTabContent: some View {
        switch companionManager.relayActiveTab {
        case .customerAsks:
            RelayCustomerAsksTabView(companionManager: companionManager)
        case .postCallNotes:
            RelayPostCallNotesTabView(companionManager: companionManager)
        case .outputs:
            RelayOutputsTabView(companionManager: companionManager)
        }
    }

    // MARK: - Footer

    private var relayPanelFooter: some View {
        HStack {
            Text("Connected to Claude AI, Google Sheets, Slack")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)

            Spacer()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("Quit")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DS.Colors.surface1)
        .overlay(Divider().background(DS.Colors.borderSubtle), alignment: .top)
    }
}

// MARK: - Customer Asks Tab

struct RelayCustomerAsksTabView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        Group {
            if companionManager.relayIsLoadingIntakes && companionManager.relayRecentIntakes.isEmpty {
                RelayLoadingView(message: "Loading customer asks…")
            } else if companionManager.relayRecentIntakes.isEmpty {
                RelayEmptyStateView(
                    icon: "tray",
                    title: "No customer asks yet",
                    subtitle: "Share your Relay link after a call. Customer submissions will appear here."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(companionManager.relayRecentIntakes) { intake in
                            RelayIntakeCardView(intake: intake, companionManager: companionManager)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 500)
            }
        }
    }
}

struct RelayIntakeCardView: View {
    let intake: RelayCustomerIntake
    @ObservedObject var companionManager: CompanionManager
    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(intake.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(intake.company)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        RelayUrgencyBadge(urgency: intake.urgency)
                        Button(action: {
                            if let soundURL = Bundle.main.url(forResource: "enter", withExtension: "mp3") {
                                NSSound(contentsOf: soundURL, byReference: false)?.play()
                            }
                            companionManager.dismissRelayIntake(withID: intake.id)
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        .help("Dismiss — removes from this list (not deleted from server)")
                    }
                    Text(relayFormattedRelativeTime(from: intake.createdAt))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Text(intake.summary ?? intake.question)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                RelayPillLabel(text: intake.category)
                Spacer()

                if companionManager.relayIsAnalyzing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(height: 22)
                } else {
                    Button(action: {
                        if let soundURL = Bundle.main.url(forResource: "eshop", withExtension: "mp3") {
                            NSSound(contentsOf: soundURL, byReference: false)?.play()
                        }
                        Task { await companionManager.generateRelayFollowUpForIntake(intake) }
                    }) {
                        Text("Generate Follow-Up")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(DS.Colors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
        }
        .padding(12)
        .background(isHovered ? DS.Colors.surface2 : DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Post-Call Notes Tab

struct RelayPostCallNotesTabView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste notes or a transcript from a customer call. Claude will generate all follow-through outputs.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    RelayFormField(
                        label: "Company / Account",
                        text: $companionManager.relayPostCallCompany,
                        placeholder: "Acme Corp"
                    )
                    RelayFormField(
                        label: "Contact",
                        text: $companionManager.relayPostCallContact,
                        placeholder: "Jane Smith"
                    )
                }

                HStack(spacing: 8) {
                    RelayFormField(
                        label: "Deal Stage",
                        text: $companionManager.relayPostCallDealStage,
                        placeholder: "Evaluation"
                    )
                    RelayFormField(
                        label: "Deal Size / ARR",
                        text: $companionManager.relayPostCallDealSize,
                        placeholder: "$80k ARR"
                    )
                }

                HStack(spacing: 8) {
                    RelayFormField(
                        label: "Next Meeting",
                        text: $companionManager.relayPostCallNextMeetingDate,
                        placeholder: "May 5"
                    )
                    RelayFormField(
                        label: "Internal Teams Needed",
                        text: $companionManager.relayPostCallInternalTeams,
                        placeholder: "Sales Eng, Security"
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes / Transcript")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    TextEditor(text: $companionManager.relayPostCallNotes)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(minHeight: 140, maxHeight: 180)
                        .padding(8)
                        .background(DS.Colors.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                        )
                        .scrollContentBackground(.hidden)
                }

                if let errorMessage = companionManager.relayAnalysisError {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#f87171"))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: {
                    Task { await companionManager.analyzeRelayPostCallNotes() }
                }) {
                    HStack(spacing: 6) {
                        if companionManager.relayIsAnalyzing {
                            ProgressView()
                                .scaleEffect(0.65)
                                .frame(width: 14, height: 14)
                        }
                        Text(companionManager.relayIsAnalyzing ? "Analyzing…" : "Analyze & Generate Outputs")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        companionManager.relayIsAnalyzing
                            ? DS.Colors.accent.opacity(0.5)
                            : DS.Colors.accent
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(companionManager.relayIsAnalyzing)
                .onHover { hovering in
                    if hovering && !companionManager.relayIsAnalyzing { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                // Demo hint
                VStack(alignment: .leading, spacing: 4) {
                    Text("Demo example")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text("\"Call with Acme today. They like the product but need SSO, HubSpot sync, and data export confirmation. CTO is concerned about security review. VP Sales wants Q3 rollout. Deal ~$80k ARR.\"")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(DS.Colors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(12)
        }
        .frame(maxHeight: 520)
    }
}

// MARK: - Outputs Tab

struct RelayOutputsTabView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        if companionManager.relayIsAnalyzing {
            RelayLoadingView(message: "Claude is generating your follow-through outputs…")
        } else if let outputs = companionManager.relayAnalysisOutputs {
            ScrollView {
                VStack(spacing: 10) {
                    RelayOutputCard(
                        title: "Executive Summary",
                        icon: "doc.text",
                        content: outputs.executiveSummary
                    )

                    RelayClassificationOutputCard(classification: outputs.classification)

                    RelayEmailOutputCard(
                        subject: outputs.customerEmail.subject,
                        emailBody: outputs.customerEmail.body,
                        toAddress: companionManager.relayCurrentCustomerEmail,
                        companionManager: companionManager
                    )

                    RelayOutputCard(
                        title: "Salesforce Note",
                        icon: "building.2",
                        content: outputs.salesforceNote
                    )

                    RelaySlackOutputCard(
                        outputs: outputs,
                        companionManager: companionManager
                    )

                    RelayOutputCard(
                        title: "Product / Support Request",
                        icon: "wrench.and.screwdriver",
                        content: outputs.productRequest
                    )

                    RelayNextStepsOutputCard(tasks: outputs.nextStepTasks)

                    Button(action: { companionManager.relayAnalysisOutputs = nil }) {
                        Text("Clear outputs")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .padding(.bottom, 8)
                }
                .padding(12)
            }
            .frame(maxHeight: 540)
        } else {
            RelayEmptyStateView(
                icon: "sparkles",
                title: "No outputs yet",
                subtitle: "Tap \"Generate Follow-Up\" on a customer ask, or paste post-call notes to get started."
            )
        }
    }
}

// MARK: - Output Cards

struct RelayOutputCard: View {
    let title: String
    let icon: String
    let content: String
    @State private var isCopied: Bool = false
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accent)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                relayCopyButton(text: content, isCopied: $isCopied)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isExpanded {
                Divider().background(DS.Colors.borderSubtle)

                Text(content)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
        }
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Email Output Card (with Open in Mail button)

struct RelayEmailOutputCard: View {
    let subject: String
    let emailBody: String
    /// The customer's email address — present when outputs came from a customer
    /// intake, nil when from post-call notes. Controls whether the To field is pre-filled.
    let toAddress: String?
    @ObservedObject var companionManager: CompanionManager

    @State private var isCopied: Bool = false
    @State private var isExpanded: Bool = true
    @State private var gmailSaveState: RelayGmailSaveState = .idle

    /// Editable copies of the Claude-generated subject and body.
    /// Initialized from the immutable props on appear so the AE can
    /// tweak wording before opening in Mail or saving to Gmail.
    @State private var editableSubject: String = ""
    @State private var editableEmailBody: String = ""

    var fullEmailText: String { "Subject: \(editableSubject)\n\n\(editableEmailBody)" }

    enum RelayGmailSaveState {
        case idle
        case saving
        case saved(draftId: String)
        case failed(message: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accent)

                Text("Customer Follow-Up Email")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                relayCopyButton(text: fullEmailText, isCopied: $isCopied)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isExpanded {
                Divider().background(DS.Colors.borderSubtle)

                // Email — editable subject + body so the AE can tweak before sending
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("To:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(toAddress ?? "— add recipient")
                            .font(.system(size: 10))
                            .foregroundColor(toAddress != nil ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                    }

                    HStack(alignment: .center, spacing: 6) {
                        Text("Subject:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                        TextField("Subject", text: $editableSubject)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textPrimary)
                            .textFieldStyle(PlainTextFieldStyle())
                    }

                    Divider().background(DS.Colors.borderSubtle).padding(.vertical, 2)

                    TextEditor(text: $editableEmailBody)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(minHeight: 100, maxHeight: 200)
                        .padding(6)
                        .background(DS.Colors.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                        )
                        .scrollContentBackground(.hidden)
                }
                .padding(12)
                .onAppear {
                    // Seed editable fields from the Claude-generated content on first show.
                    if editableSubject.isEmpty { editableSubject = subject }
                    if editableEmailBody.isEmpty { editableEmailBody = emailBody }
                }

                Divider().background(DS.Colors.borderSubtle)

                // "Open in Mail" is always available — opens the system mail client
                // (Mail.app, Outlook, etc.) with To/Subject/Body pre-filled via mailto:.
                openInMailButton

                // "Save to Gmail Drafts" appears as an additional option only when
                // GMAIL_MCP_URL is configured on the server. Both buttons coexist.
                if companionManager.gmailIntegrationEnabled {
                    gmailDraftButton
                }

                // Status row shown after a Gmail save attempt.
                if case .saved(let draftId) = gmailSaveState {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#16a34a"))
                        Text("Draft saved — open Gmail to review and send")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                        Spacer()
                        Text(draftId.prefix(8))
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else if case .failed(let message) = gmailSaveState {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#ca8a04"))
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Email Action Buttons

    private var gmailDraftButton: some View {
        Button(action: {
            if case .saving = gmailSaveState { return }
            saveToGmailDrafts()
        }) {
            HStack(spacing: 6) {
                if case .saving = gmailSaveState {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "envelope.badge.arrow.up")
                        .font(.system(size: 11))
                }
                Text(gmailButtonLabel)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(gmailButtonBackground)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var openInMailButton: some View {
        Button(action: {
            if let soundURL = Bundle.main.url(forResource: "enter", withExtension: "mp3") {
                NSSound(contentsOf: soundURL, byReference: false)?.play()
            }
            openEmailDraftViaMailto(toAddress: toAddress, subject: editableSubject, body: editableEmailBody)
        }) {
            HStack(spacing: 6) {
                Image(systemName: "envelope")
                    .font(.system(size: 11))
                Text(toAddress != nil ? "Open in Mail — to \(toAddress!)" : "Open in Mail")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(DS.Colors.accent)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var gmailButtonLabel: String {
        switch gmailSaveState {
        case .idle:    return toAddress != nil ? "Save to Gmail Drafts — to \(toAddress!)" : "Save to Gmail Drafts"
        case .saving:  return "Saving to Gmail…"
        case .saved:   return "Saved to Gmail Drafts"
        case .failed:  return "Retry — Save to Gmail"
        }
    }

    private var gmailButtonBackground: Color {
        if case .saved = gmailSaveState { return Color(hex: "#16a34a") }
        if case .saving = gmailSaveState { return DS.Colors.accent.opacity(0.6) }
        return DS.Colors.accent
    }

    private func saveToGmailDrafts() {
        gmailSaveState = .saving
        Task {
            do {
                let draftId = try await companionManager.saveEmailToGmailDrafts(
                    toAddress: toAddress,
                    subject: editableSubject,
                    emailBody: editableEmailBody
                )
                gmailSaveState = .saved(draftId: draftId)
            } catch RelayGmailError.notConfigured {
                // Server says Gmail isn't configured — fall back to clipboard copy.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullEmailText, forType: .string)
                gmailSaveState = .failed(message: "Gmail not configured — copied to clipboard instead")
            } catch {
                gmailSaveState = .failed(message: error.localizedDescription)
            }
        }
    }
}

// Opens the system default mail client (Mail.app, Outlook, etc.) with a
// pre-filled compose window. Uses URLComponents so encoding is handled correctly.
// No entitlements required — mailto: is an open URL scheme on macOS.
private func openEmailDraftViaMailto(toAddress: String?, subject: String, body: String) {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = toAddress ?? ""
    components.queryItems = [
        URLQueryItem(name: "subject", value: subject),
        URLQueryItem(name: "body", value: body)
    ]
    guard let mailtoURL = components.url else {
        print("[Relay] Failed to construct mailto URL")
        return
    }
    NSWorkspace.shared.open(mailtoURL)
}

// MARK: - Slack Output Card (with Send to Slack button)

// MARK: - Slack Output Card (draft → edit → send flow)

struct RelaySlackOutputCard: View {
    /// Full analysis outputs — needed so we can send context to Claude for drafting.
    let outputs: RelayAnalysisOutputs
    @ObservedObject var companionManager: CompanionManager

    @State private var isCopied: Bool = false
    @State private var isExpanded: Bool = true
    @State private var cardState: RelaySlackCardState = .idle
    @State private var editableDraftText: String = ""

    /// State machine for the draft → edit → send flow.
    enum RelaySlackCardState {
        case idle            // shows "Draft AE message" button
        case generatingDraft // Claude is writing, show spinner
        case editingDraft    // show editable TextEditor + Send button
        case sendingDraft    // posting to Slack, show spinner
        case sent            // success
        case failed(message: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Card header — always visible
            HStack(spacing: 8) {
                Image(systemName: "number")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accent)

                Text("Slack Update")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                relayCopyButton(text: outputs.slackUpdate, isCopied: $isCopied)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isExpanded {
                Divider().background(DS.Colors.borderSubtle)

                // Structured auto-notification text (always shown for reference)
                Text(outputs.slackUpdate)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)

                Divider().background(DS.Colors.borderSubtle)

                // Draft / edit / send flow
                slackDraftSection
            }
        }
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Draft Section

    @ViewBuilder
    private var slackDraftSection: some View {
        switch cardState {

        case .idle:
            Button(action: {
                if let soundURL = Bundle.main.url(forResource: "enter", withExtension: "mp3") {
                    NSSound(contentsOf: soundURL, byReference: false)?.play()
                }
                generateDraft()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                    Text("Draft AE message for Slack")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(DS.Colors.surface2)
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

        case .generatingDraft:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.65)
                Text("Claude is drafting your message…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)

        case .editingDraft:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Edit before sending")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    Button(action: { cardState = .idle }) {
                        Text("Start over")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }

                TextEditor(text: $editableDraftText)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(minHeight: 80, maxHeight: 140)
                    .padding(8)
                    .background(DS.Colors.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
                    .scrollContentBackground(.hidden)

                Button(action: sendDraft) {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill").font(.system(size: 11))
                        Text("Send to #relay-signals")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(DS.Colors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(12)

        case .sendingDraft:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.65)
                Text("Sending to #relay-signals…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)

        case .sent:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#16a34a"))
                Text("Posted to #relay-signals")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button(action: { cardState = .idle }) {
                    Text("Send another")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(12)

        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#ca8a04"))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: { cardState = .idle }) {
                    Text("Retry")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Actions

    private func generateDraft() {
        cardState = .generatingDraft
        Task {
            do {
                let draftText = try await companionManager.generateRelaySlackDraft(analysisOutputs: outputs)
                editableDraftText = draftText
                cardState = .editingDraft
            } catch {
                cardState = .failed(message: error.localizedDescription)
            }
        }
    }

    private func sendDraft() {
        let textToSend = editableDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToSend.isEmpty else { return }
        cardState = .sendingDraft
        Task {
            do {
                try await companionManager.sendSlackUpdate(slackUpdateText: textToSend)
                cardState = .sent
            } catch {
                cardState = .failed(message: error.localizedDescription)
            }
        }
    }
}

struct RelayClassificationOutputCard: View {
    let classification: RelayAnalysisOutputs.RelayClassification
    @State private var isCopied: Bool = false

    var classificationText: String {
        "Category: \(classification.category)\nUrgency: \(classification.urgency)\nSentiment: \(classification.sentiment)\nRevenue Impact: \(classification.revenueImpact)\nRecommended Owner: \(classification.recommendedOwner)\nNeeds Human Follow-Up: \(classification.needsHumanFollowUp ? "Yes" : "No")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accent)

                Text("Classification")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                relayCopyButton(text: classificationText, isCopied: $isCopied)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 6) {
                RelayClassificationRow(label: "Category", value: classification.category)
                RelayClassificationRow(label: "Urgency", value: classification.urgency)
                RelayClassificationRow(label: "Sentiment", value: classification.sentiment)
                RelayClassificationRow(label: "Revenue Impact", value: classification.revenueImpact)
                RelayClassificationRow(label: "Owner", value: classification.recommendedOwner)
                RelayClassificationRow(label: "Human Follow-Up", value: classification.needsHumanFollowUp ? "Yes" : "No")
            }
            .padding(12)
        }
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }
}

struct RelayClassificationRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 110, alignment: .leading)

            Text(value)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RelayNextStepsOutputCard: View {
    let tasks: [String]
    @State private var isCopied: Bool = false

    var tasksText: String {
        tasks.map { "☐ \($0)" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accent)

                Text("Next-Step Tasks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                relayCopyButton(text: tasksText, isCopied: $isCopied)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "square")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.top, 1)

                        Text(task)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
        }
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Shared Components

struct RelayFormField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            TextField(placeholder, text: $text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .textFieldStyle(PlainTextFieldStyle())
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(DS.Colors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity)
    }
}

struct RelayUrgencyBadge: View {
    let urgency: String

    var badgeColor: Color {
        let lower = urgency.lowercased()
        if lower.contains("blocking") { return Color(hex: "#dc2626") }
        if lower == "high" { return Color(hex: "#ea580c") }
        if lower == "medium" { return Color(hex: "#ca8a04") }
        return Color(hex: "#16a34a")
    }

    var body: some View {
        Text(urgency)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct RelayPillLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(DS.Colors.surface3)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct RelayLoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

struct RelayEmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(DS.Colors.textTertiary)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

// MARK: - Copy Button Helper

private func relayCopyButton(text: String, isCopied: Binding<Bool>) -> some View {
    Button(action: {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        isCopied.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied.wrappedValue = false
        }
    }) {
        Text(isCopied.wrappedValue ? "Copied!" : "Copy")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(isCopied.wrappedValue ? Color(hex: "#16a34a") : DS.Colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DS.Colors.surface3)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    .buttonStyle(PlainButtonStyle())
    .onHover { hovering in
        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
}

// MARK: - Relay Logo

/// The Relay three-circle logo rendered in SwiftUI from the 24×24 SVG viewBox.
/// Use this anywhere the Relay brand mark is needed — panel header, cursor overlay, etc.
struct RelayLogoView: View {
    let size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 24 // maps SVG 24×24 viewBox to actual size
            let r = 2.2 * scale

            // SVG coords: cx, cy match SVG top-left origin — SwiftUI y also goes down, no flip needed.
            let circles: [(cx: CGFloat, cy: CGFloat, color: Color)] = [
                (7,    16,   Color(red: 0.949, green: 0.325, blue: 0.082)), // #f25314 orange
                (14,   6.5,  Color(red: 0.075, green: 0.596, blue: 0.831)), // #1398d4 blue
                (17,   16.5, Color(red: 0.314, green: 0.937, blue: 0.553)), // #50ef8d green
            ]

            for circle in circles {
                let rect = CGRect(
                    x: circle.cx * scale - r,
                    y: circle.cy * scale - r,
                    width: r * 2,
                    height: r * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(circle.color))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Utility

func relayFormattedRelativeTime(from isoString: String) -> String {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let simpleFormatter = ISO8601DateFormatter()

    let date = fractionalFormatter.date(from: isoString) ?? simpleFormatter.date(from: isoString)
    guard let date = date else { return "" }

    let secondsAgo = Int(-date.timeIntervalSinceNow)
    if secondsAgo < 60 { return "just now" }
    if secondsAgo < 3600 { return "\(secondsAgo / 60)m ago" }
    if secondsAgo < 86400 { return "\(secondsAgo / 3600)h ago" }
    return "\(secondsAgo / 86400)d ago"
}
