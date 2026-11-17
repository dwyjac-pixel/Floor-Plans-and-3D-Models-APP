import SwiftUI

/// Grouped material list computed from the room geometry, with per-line
/// pricing the user controls: tick a line to include it in the total,
/// and enter or adjust its price. Decisions persist per project.
struct MaterialTakeoffScreen: View {
    let takeoff: MaterialTakeoff
    let project: RenovationProject

    @State private var adjustments = TakeoffAdjustments()
    @State private var quote = QuoteSettings()
    @FocusState private var focusedPriceKey: String?
    @State private var csvURL: URL?
    @State private var csvPreview = ""
    @State private var showingCSVPreview = false
    @State private var showingEstiMaterExport = false
    @State private var estiMaterURL: URL?
    @State private var estiMaterError: String?

    private var totals: QuoteTotals {
        QuoteTotals(subtotal: adjustments.total(for: takeoff), settings: quote)
    }

    private var categories: [String] {
        var seen: [String] = []
        for line in takeoff.lines where !seen.contains(line.category) {
            seen.append(line.category)
        }
        return seen
    }

    private var pricedLineCount: Int {
        takeoff.lines.filter { adjustments.isIncluded($0) && adjustments.price(for: $0) != nil }.count
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Subtotal") {
                    Text(Money.format(totals.subtotal))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Markup %")
                    Spacer()
                    TextField("0", value: $quote.markupPercent, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .focused($focusedPriceKey, equals: "__markup__")
                        .accessibilityLabel("Markup percent")
                }
                LabeledContent("Markup") {
                    Text(Money.format(totals.markup))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("\(quote.taxLabel) %")
                    Spacer()
                    TextField("0", value: $quote.taxPercent, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .focused($focusedPriceKey, equals: "__tax__")
                        .accessibilityLabel("\(quote.taxLabel) percent")
                }
                LabeledContent(quote.taxLabel) {
                    Text(Money.format(totals.tax))
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Total") {
                    Text(Money.format(totals.grandTotal))
                        .font(.title3.bold())
                        .foregroundStyle(.tint)
                }
            } header: {
                Text("Pricing Summary")
            } footer: {
                Text(pricedLineCount == 0
                     ? "Enter a price on each line and untick anything the quote shouldn't include."
                     : "\(pricedLineCount) priced line\(pricedLineCount == 1 ? "" : "s") included. Markup and \(quote.taxLabel) apply to the subtotal above.")
            }

            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(takeoff.lines.filter { $0.category == category }) { line in
                        lineRow(line)
                    }
                }
            }
            Section {
                Button("Export quote to EstiMater", systemImage: "square.and.arrow.up") {
                    prepareEstiMaterQuote()
                }
            } footer: {
                Text("Quantities assume 16\" o.c. framing, 4×8 sheets, and a 10% waste factor. Verify against site conditions before ordering.")
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Quote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    prepareCSV()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export order list (CSV)")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedPriceKey = nil }
            }
        }
        .sheet(isPresented: $showingCSVPreview) { csvPreviewSheet }
        .sheet(isPresented: $showingEstiMaterExport) {
            if let estiMaterURL {
                VStack(spacing: 16) {
                    Text("Scanner quote").font(.headline)
                    Text("Save the file, then choose Import a Scanner quote in EstiMater’s New Proposal screen.")
                        .multilineTextAlignment(.center)
                    ShareLink(item: estiMaterURL) {
                        Label("Share quote file", systemImage: "square.and.arrow.up")
                    }
                    Button("Done") { showingEstiMaterExport = false }
                }
                .padding()
                .presentationDetents([.medium])
            }
        }
        .alert("Could not export quote", isPresented: Binding(
            get: { estiMaterError != nil }, set: { if !$0 { estiMaterError = nil } }
        )) {
            Button("OK", role: .cancel) { estiMaterError = nil }
        } message: {
            Text(estiMaterError ?? "")
        }
        .onAppear {
            adjustments = ScanStore.loadTakeoffAdjustments(for: project) ?? TakeoffAdjustments()
            quote = ScanStore.loadQuoteSettings(for: project)
        }
        .onChange(of: quote) { _, newValue in
            try? ScanStore.saveQuoteSettings(newValue, for: project)
        }
    }

    private func lineRow(_ line: MaterialTakeoff.Line) -> some View {
        let included = adjustments.isIncluded(line)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if included {
                        adjustments.excludedKeys.insert(line.key)
                    } else {
                        adjustments.excludedKeys.remove(line.key)
                    }
                    persist()
                } label: {
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(included ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Include \(line.item)")
                .accessibilityValue(included ? "Included" : "Excluded")
                .accessibilityHint(included ? "Double tap to exclude from the total" : "Double tap to include in the total")

                VStack(alignment: .leading, spacing: 2) {
                    Text(line.item)
                        .strikethrough(!included, color: .secondary)
                        .foregroundStyle(included ? .primary : .secondary)
                    if !line.note.isEmpty {
                        Text(line.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(line.quantity)
                    .bold()
                    .foregroundStyle(included ? Color.accentColor : Color.secondary)
            }
            HStack {
                Text("Price")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Plain "$" + grouped integer to match Money.format everywhere
                // else; .currency(code:"CAD") rendered "CA$" outside Canada.
                Text("$").foregroundStyle(.secondary)
                TextField("0", value: priceBinding(line), format: .number.grouping(.automatic).precision(.fractionLength(0)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedPriceKey, equals: line.key)
                    .disabled(!included)
                    .opacity(included ? 1 : 0.5)
                    .accessibilityLabel("Price for \(line.item)")
            }
            .padding(.leading, 34)
        }
        .padding(.vertical, 2)
    }

    private func priceBinding(_ line: MaterialTakeoff.Line) -> Binding<Double?> {
        Binding(
            get: { adjustments.prices[line.key] },
            set: { newValue in
                if let newValue, newValue > 0 {
                    adjustments.prices[line.key] = newValue
                } else {
                    adjustments.prices.removeValue(forKey: line.key)
                }
                persist()
            }
        )
    }

    private func persist() {
        try? ScanStore.saveTakeoffAdjustments(adjustments, for: project)
    }

    // MARK: - CSV order list (preview before sending)

    private var csvPreviewSheet: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(csvPreview)
                    .font(.system(.caption2, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Order List Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingCSVPreview = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let csvURL {
                        ShareLink(item: csvURL) {
                            Label("Send", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    private func prepareEstiMaterQuote() {
        do {
            let package = try ScannerQuoteExport.make(project: project, takeoff: takeoff,
                                                      adjustments: adjustments, settings: quote)
            let data = try JSONEncoder().encode(package)
            guard data.count <= 400_000 else { throw ScannerQuoteExport.ExportError.invalidProject }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Scanner Quote " + package.project_id.uuidString + ".json")
            try data.write(to: url, options: .atomic)
            estiMaterURL = url
            showingEstiMaterExport = true
        } catch {
            estiMaterError = error.localizedDescription
        }
    }

    private func prepareCSV() {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = ["Category,Item,Quantity,Note,Included,Price (CAD)"]
        for line in takeoff.lines {
            let included = adjustments.isIncluded(line)
            let price = adjustments.price(for: line).map { String(Int($0.rounded())) } ?? ""
            rows.append([quoted(line.category), quoted(line.item), quoted(line.quantity),
                         quoted(line.note), included ? "yes" : "no", price]
                .joined(separator: ","))
        }
        rows.append("")
        rows.append(",,,,Subtotal,\(Int(totals.subtotal.rounded()))")
        rows.append(",,,,Markup,\(Int(totals.markup.rounded()))")
        rows.append(",,,,\(quote.taxLabel),\(Int(totals.tax.rounded()))")
        rows.append(",,,,Total,\(Int(totals.grandTotal.rounded()))")
        let text = rows.joined(separator: "\r\n")

        let safeName = project.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName) - Materials.csv")
        guard let data = text.data(using: .utf8), (try? data.write(to: url, options: .atomic)) != nil else {
            return
        }
        csvPreview = text
        csvURL = url
        showingCSVPreview = true
    }
}
