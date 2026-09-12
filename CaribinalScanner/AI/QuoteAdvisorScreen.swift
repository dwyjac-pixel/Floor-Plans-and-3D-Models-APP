import SwiftUI

/// Chat with the AI quote advisor about this project: what to replace,
/// fix, add, or remove from the quote. The conversation persists per
/// project; the advisor sees the rooms, takeoff pricing, and estimate.
struct QuoteAdvisorScreen: View {
    let project: RenovationProject

    @AppStorage("useImperialUnits") private var useImperial = true
    @State private var messages: [AIChatMessage] = []
    @State private var draft = ""
    @State private var isSending = false
    @State private var errorText: String?
    @State private var hasKey = APIKeyStore.load() != nil
    @State private var keyDraft = ""
    @State private var showingKeyEntry = false
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var draftFocused: Bool

    private static let starterQuestions = [
        "What would you cut from this quote for a flip?",
        "What's missing from this quote?",
        "Which items usually need a permit?",
        "Where is this quote most likely to blow the budget?",
    ]

    var body: some View {
        Group {
            if hasKey {
                chat
            } else {
                keySetup
            }
        }
        .navigationTitle("AI Quote Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasKey {
                Menu {
                    Button("Change API Key…") {
                        keyDraft = ""
                        showingKeyEntry = true
                    }
                    if !messages.isEmpty {
                        Button("Clear Conversation", role: .destructive) {
                            messages = []
                            try? ScanStore.saveAIChat(messages, for: project)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Claude API Key", isPresented: $showingKeyEntry) {
            SecureField("sk-ant-…", text: $keyDraft)
            Button("Save") {
                // Empty/whitespace input is a no-op — never call save("") since
                // that would wipe the existing stored key.
                let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    APIKeyStore.save(trimmed)
                    hasKey = APIKeyStore.load() != nil
                }
                keyDraft = ""
            }
            Button("Cancel", role: .cancel) { keyDraft = "" }
        } message: {
            Text("Stored securely on this device and used only to talk to Claude.")
        }
        .onAppear {
            messages = ScanStore.loadAIChat(for: project) ?? []
        }
        .onDisappear {
            // Cancel any in-flight turn so it can't write ai_chat.json after
            // the view is gone or race a re-entered screen's writer.
            sendTask?.cancel()
            sendTask = nil
        }
    }

    // MARK: - Key setup

    private var keySetup: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("AI-Powered Quote Review")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("A second set of eyes on this project's numbers before you commit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                VStack(spacing: 16) {
                    onboardingStep(
                        number: 1,
                        systemImage: "checklist",
                        title: "What it does for this job",
                        detail: "Walks your scope and pricing line by line. It flags what to cut or add to make the flip pencil out, catches items that usually need a permit, and points out where the budget's most likely to run over."
                    )
                    onboardingStep(
                        number: 2,
                        systemImage: "lock.shield",
                        title: "Powered by Claude",
                        detail: "It runs on Claude, so it needs a free Anthropic API key from platform.claude.com. Your key is stored securely on this device only. It is never uploaded or shared."
                    )
                    onboardingStep(
                        number: 3,
                        systemImage: "key",
                        title: "Add your key to start",
                        detail: "Paste your key and you're ready to talk through the quote. You only do this once."
                    )
                }

                VStack(spacing: 10) {
                    Button {
                        keyDraft = ""
                        showingKeyEntry = true
                    } label: {
                        Label("Add API Key", systemImage: "key")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Add API Key")

                    Link(destination: URL(string: "https://platform.claude.com")!) {
                        Label("Get a key", systemImage: "arrow.up.right")
                            .font(.footnote)
                    }
                    .accessibilityLabel("Get a key from platform.claude.com")
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private func onboardingStep(
        number: Int,
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Step \(number)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }

    // MARK: - Chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            starterView
                        }
                        ForEach(messages) { message in
                            bubble(message)
                                .id(message.id)
                        }
                        if isSending {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Reviewing the quote…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .id("typing")
                        }
                        if let errorText {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: messages) {
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: isSending) {
                    if isSending {
                        withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                TextField("Ask about this quote…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($draftFocused)
                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
    }

    private var starterView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about this project's quote. The advisor can see the rooms, the takeoff with your pricing, and the estimate.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(Self.starterQuestions, id: \.self) { question in
                Button {
                    send(question)
                } label: {
                    Text(question)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(isSending)
            }
        }
        .padding(.horizontal)
    }

    private func bubble(_ message: AIChatMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            Text(LocalizedStringKey(message.text))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.role == "user"
                        ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                        : AnyShapeStyle(.thinMaterial),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            if message.role != "user" { Spacer(minLength: 40) }
        }
        .padding(.horizontal)
    }

    // MARK: - Sending

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        draft = ""
        errorText = nil
        messages.append(AIChatMessage(role: "user", text: trimmed))
        try? ScanStore.saveAIChat(messages, for: project)
        isSending = true

        let history = messages
        let context = QuoteAdvisor.buildContext(
            project: project,
            rooms: ScanStore.loadRooms(for: project),
            takeoff: currentTakeoff(),
            adjustments: ScanStore.loadTakeoffAdjustments(for: project) ?? TakeoffAdjustments(),
            estimate: currentEstimate(),
            useImperial: useImperial
        )

        sendTask = Task {
            do {
                let reply = try await QuoteAdvisor.send(history: history, context: context)
                // The view may have been dismissed while awaiting — don't touch
                // @State or the chat file if this turn was cancelled.
                if Task.isCancelled { return }
                // Merge with the freshest on-disk chat instead of overwriting a
                // stale snapshot, so a concurrent turn can't be dropped.
                var merged = ScanStore.loadAIChat(for: project) ?? messages
                merged.append(AIChatMessage(role: "assistant", text: reply))
                messages = merged
                try? ScanStore.saveAIChat(messages, for: project)
            } catch {
                if Task.isCancelled { return }
                errorText = error.localizedDescription
            }
            if !Task.isCancelled { isSending = false }
        }
    }

    private func currentTakeoff() -> MaterialTakeoff? {
        let rooms = ScanStore.loadRooms(for: project)
        guard !rooms.isEmpty else { return nil }
        return MaterialTakeoff.calculate(rooms: rooms.map(\.room))
    }

    private func currentEstimate() -> EstimateResult? {
        guard let inputs = ScanStore.loadEstimate(for: project) else { return nil }
        return EstimateCalculator.calculate(inputs: inputs, planAreaSquareMeters: planArea())
    }

    /// The plan-preferred floor area, resolved the SAME way ProjectDetailView
    /// picks its `plan`: a LiDAR scan wins over merged traced/camera rooms,
    /// which win over a manual entry. Every other screen estimates from this
    /// area, so the advisor must too.
    private func planArea() -> Double? {
        if let room = ScanStore.loadCapturedRoom(for: project),
           let scanPlan = FloorPlanModel(room: room) {
            return scanPlan.approxFloorAreaSquareMeters
        }
        let rooms = ScanStore.loadRooms(for: project)
        if !rooms.isEmpty, let mergedPlan = FloorPlanModel(rooms: rooms.map(\.room)) {
            return mergedPlan.approxFloorAreaSquareMeters
        }
        if let manual = ScanStore.loadManualRoom(for: project),
           let manualPlan = FloorPlanModel(manual: manual) {
            return manualPlan.approxFloorAreaSquareMeters
        }
        return nil
    }
}
