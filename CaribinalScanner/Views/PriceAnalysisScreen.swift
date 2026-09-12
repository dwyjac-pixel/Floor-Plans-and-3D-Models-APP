import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device AI price review: analyzes the quote against the contractor's
/// own price book for the job's region, then interviews the contractor —
/// question by question — to sharpen the number. No API key, no network;
/// requires Apple Intelligence (iPhone 15 Pro or later, iOS 26).
struct PriceAnalysisScreen: View {
    let project: RenovationProject

    @AppStorage("useImperialUnits") private var useImperial = true
    @State private var postal = ""
    @State private var region: String?
    @State private var isRunning = false
    @State private var summary: String?
    @State private var findings: [(item: String, verdict: String, note: String)] = []
    @State private var questions: [String] = []
    @State private var thread: [(question: String, answer: String, reply: String)] = []
    @State private var activeQuestion: String?
    @State private var answerText = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            switch OnDeviceAI.availability {
            case .unsupported:
                Section {
                    Label("Needs Apple Intelligence", systemImage: "sparkles.slash")
                        .font(.headline)
                    Text("On-device price analysis runs on iPhone 15 Pro or later with iOS 26. On this device, use AI Quote Review with an API key instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .needsAppleIntelligence:
                Section {
                    Label("Turn on Apple Intelligence", systemImage: "sparkles")
                        .font(.headline)
                    Text("This device supports on-device AI, but Apple Intelligence is off or still downloading. Turn it on in Settings → Apple Intelligence & Siri, then come back.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .available:
                availableContent
            }
        }
        .navigationTitle("AI Price Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .onAppear(perform: seedLocation)
        .alert("AI Problem", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var availableContent: some View {
        Section {
            HStack {
                TextField("Postal / ZIP code", text: $postal)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: postal) { _, value in
                        region = OnDeviceAI.region(fromPostal: value)
                        ScanStore.saveAIPostal(postal, for: project)
                    }
                if let region {
                    Text(region)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                runAnalysis()
            } label: {
                if isRunning && summary == nil {
                    HStack { ProgressView(); Text("Analyzing…") }
                } else {
                    Label(summary == nil ? "Analyze This Quote" : "Re-Analyze",
                          systemImage: "wand.and.sparkles")
                }
            }
            .disabled(isRunning)
        } header: {
            Text("Job Location")
        } footer: {
            Text("Runs entirely on this iPhone. No API key, no internet, nothing leaves the device. The AI reasons from your quote, your Price Book, and the region; it does not know live market prices.")
        }

        if let summary {
            Section("Overall Read") {
                Text(summary)
            }
        }
        if !findings.isEmpty {
            Section("Line Findings") {
                ForEach(findings.indices, id: \.self) { index in
                    let finding = findings[index]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(finding.item).font(.subheadline.weight(.semibold))
                            Spacer()
                            verdictChip(finding.verdict)
                        }
                        Text(finding.note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        if !questions.isEmpty {
            Section {
                ForEach(questions, id: \.self) { question in
                    Button {
                        activeQuestion = question
                        answerText = ""
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: activeQuestion == question
                                  ? "questionmark.circle.fill" : "questionmark.circle")
                            Text(question).multilineTextAlignment(.leading)
                        }
                    }
                    if activeQuestion == question {
                        HStack {
                            TextField("Your answer…", text: $answerText, axis: .vertical)
                            Button {
                                sendAnswer(to: question)
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title3)
                            }
                            .disabled(answerText.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
                        }
                    }
                }
            } header: {
                Text("Job Interview")
            } footer: {
                Text("Answer any question and the AI folds it into the pricing guidance.")
            }
        }
        if !thread.isEmpty {
            Section("Refined Guidance") {
                ForEach(thread.indices, id: \.self) { index in
                    let turn = thread[index]
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(turn.question)  →  \(turn.answer)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(turn.reply)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func verdictChip(_ verdict: String) -> some View {
        let (label, color): (String, Color) = switch verdict {
        case "looks_high": ("High?", .orange)
        case "looks_low": ("Low?", .red)
        case "fair": ("Fair", .green)
        default: ("Check", .blue)
        }
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func seedLocation() {
        // Priority: the project's own postal field, then a previous entry
        // on this screen, then whatever the address contains.
        let fromProject = project.postalCode.isEmpty ? nil : project.postalCode
        postal = fromProject
            ?? ScanStore.loadAIPostal(for: project)
            ?? OnDeviceAI.extractPostal(from: project.address)
            ?? ""
        region = OnDeviceAI.region(fromPostal: postal)
    }

    private func runAnalysis() {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return }
        let rooms = ScanStore.loadRooms(for: project).map(\.room)
        guard !rooms.isEmpty else {
            errorMessage = "Add rooms and price the material takeoff first. The AI reviews the numbers you've entered."
            return
        }
        let takeoff = MaterialTakeoff.calculate(rooms: rooms)
        let adjustments = ScanStore.loadTakeoffAdjustments(for: project) ?? TakeoffAdjustments()
        guard !adjustments.prices.isEmpty else {
            errorMessage = "No prices entered yet. Open Material Takeoff / Quote, price the lines, then run the analysis."
            return
        }
        let prompt = OnDeviceAI.quotePrompt(takeoff: takeoff,
                                            adjustments: adjustments,
                                            settings: ScanStore.loadQuoteSettings(for: project),
                                            estimate: ScanStore.loadEstimate(for: project),
                                            region: region)
        isRunning = true
        Task {
            do {
                let session = OnDeviceAI.makeSession(region: region)
                Self.activeSession = session
                let response = try await session.respond(to: prompt,
                                                         generating: QuoteAIAnalysis.self)
                await MainActor.run {
                    summary = response.content.summary
                    findings = response.content.findings.map { ($0.item, $0.verdict, $0.note) }
                    questions = response.content.questions
                    thread = []
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "The on-device model couldn't finish: \(error.localizedDescription)"
                    isRunning = false
                }
            }
        }
        #endif
    }

    private func sendAnswer(to question: String) {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *),
              let session = Self.activeSession as? LanguageModelSession else { return }
        let answer = answerText.trimmingCharacters(in: .whitespaces)
        isRunning = true
        activeQuestion = nil
        Task {
            do {
                let response = try await session.respond(to: """
                    Contractor answered your question.
                    Q: \(question)
                    A: \(answer)
                    In 2-3 sentences, update your pricing guidance for this quote based on that answer. \
                    Use dollar figures only from the numbers already provided.
                    """)
                await MainActor.run {
                    thread.append((question, answer, response.content))
                    questions.removeAll { $0 == question }
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "The on-device model couldn't finish: \(error.localizedDescription)"
                    isRunning = false
                }
            }
        }
        #endif
    }

    /// The multi-turn session lives across the analyze → interview flow.
    /// Held as Any so the property compiles on pre-26 SDers/devices.
    private static var activeSession: Any?
}
