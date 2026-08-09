import SwiftUI

/// The investor deal analyzer: purchase + financing + ARV + renovation →
/// Flip / Rental / BRRRR returns, computed live, with a winner banner for
/// strong deals. Renovation cost prefers the measured scan estimate.
struct DealAnalyzerScreen: View {
    let project: RenovationProject
    let estimateMidpoint: Double?
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inputs: DealInputs
    // Suite ROI / payback inputs now live inside Deal Analyzer too (roi.json),
    // so a contractor never needs the separate Suite ROI screen.
    @State private var roiInputs: ROIInputs

    init(project: RenovationProject, estimateMidpoint: Double?, onSave: @escaping () -> Void) {
        self.project = project
        self.estimateMidpoint = estimateMidpoint
        self.onSave = onSave
        if let saved = ScanStore.loadDeal(for: project) {
            _inputs = State(initialValue: saved)
        } else {
            // First open: seed the strategy from the project type (a flip
            // starts on Flip, a suite/multi-family on Rental).
            var fresh = DealInputs()
            if let strategy = ProjectTypeProfile.profile(for: project.projectType).defaultDealStrategy {
                fresh.strategy = strategy
            }
            _inputs = State(initialValue: fresh)
        }
        _roiInputs = State(initialValue: ScanStore.loadROI(for: project) ?? ROIInputs())
    }

    private var keyMetricText: String {
        switch inputs.strategy {
        case .flip:
            return "\(Money.format(result.flipProfit)) · \(String(format: "%.1f%%", result.flipROIPercent)) ROI"
        case .rental:
            return "\(Money.format(result.monthlyCashFlow))/mo · \(String(format: "%.1f%%", result.cashOnCashPercent)) CoC"
        case .brrrr:
            return "\(Money.format(result.cashLeftInDeal)) left in · \(Money.format(result.postRefiCashFlow))/mo"
        }
    }

    private var result: DealResult {
        DealAnalyzer.calculate(inputs: inputs, estimateMidpoint: estimateMidpoint)
    }

    private var roiResult: ROIResult? {
        ROICalculator.calculate(inputs: roiInputs, estimateMidpoint: estimateMidpoint)
    }

    var body: some View {
        Form {
            strategySection
            mlsSection
            purchaseSection
            arvSection
            renoSection
            if inputs.propertyType != .single {
                rentRollSection
            }
            if inputs.strategy != .flip || inputs.propertyType == .apartment {
                incomeSection
            }
            resultsSection
            // ROI & Payback is meaningful for hold strategies (rental / BRRRR).
            if inputs.strategy != .flip {
                roiPaybackSection
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Deal Analyzer")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                if result.isWinner {
                    Image(systemName: "trophy.fill").foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
                Text(inputs.strategy.rawValue).bold()
                Spacer()
                Text(keyMetricText)
                    .bold()
                    .foregroundStyle(result.isWinner ? Color.green : .primary)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(result.isWinner
                                ? "\(inputs.strategy.rawValue), strong deal. \(keyMetricText)"
                                : "\(inputs.strategy.rawValue). \(keyMetricText)")
        }
        .onChange(of: inputs.propertyType) { _, newType in
            switch newType {
            case .apartment:
                inputs.downPaymentPercent = 25
                if inputs.managementPercent == 0 { inputs.managementPercent = 8 }
            case .single, .duplex, .small:
                inputs.downPaymentPercent = 20
            }
        }
        // Autosave the ROI/payback inputs live, matching the former Suite ROI
        // screen's save-on-change so nothing is lost.
        .onChange(of: roiInputs) { _, newInputs in
            try? ScanStore.saveROI(newInputs, for: project)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    try? ScanStore.saveDeal(inputs, for: project)
                    try? ScanStore.saveROI(roiInputs, for: project)
                    onSave()
                    dismiss()
                }
            }
        }
        // Persist on Back/swipe too, so edits aren't lost when the user
        // leaves without tapping Done (QA-023).
        .onDisappear {
            try? ScanStore.saveDeal(inputs, for: project)
            try? ScanStore.saveROI(roiInputs, for: project)
            onSave()
        }
    }

    // MARK: - Sections

    private var strategySection: some View {
        Section {
            Picker("Strategy", selection: $inputs.strategy) {
                ForEach(DealInputs.Strategy.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Property type", selection: $inputs.propertyType) {
                ForEach(DealInputs.PropertyType.allCases) { Text($0.rawValue).tag($0) }
            }
        } header: {
            Text("Strategy")
        } footer: {
            Text("Flip: renovate and sell. Rental: hold and collect rent. BRRRR: renovate, rent it out, then refinance to pull your cash back out.")
        }
    }

    private var mlsSection: some View {
        Section {
            TextField("MLS® number", text: $inputs.mlsNumber)
                .textInputAutocapitalization(.characters)
            moneyRow("List price", value: $inputs.listPrice)
            if inputs.listPrice > 0, inputs.listPrice != inputs.purchasePrice {
                Button("Use list price as purchase price") {
                    inputs.purchasePrice = inputs.listPrice
                }
            }
            moneyRow("Property taxes (annual)", value: $inputs.annualTaxes)
        } header: {
            Text("Listing Details")
        } footer: {
            Text("Taxes feed the expense math. Automatic listing pull by address needs an MLS data feed (CREA DDF) — the fields are ready for it.")
        }
    }

    private var rentRollSection: some View {
        Section {
            ForEach($inputs.units) { $unit in
                HStack {
                    TextField("Unit", text: $unit.name)
                        .frame(width: 90)
                        .accessibilityLabel("Unit name")
                    Toggle("", isOn: $unit.occupied)
                        .labelsHidden()
                        .accessibilityLabel("\(unit.name) occupied")
                    Spacer()
                    Text("$").foregroundStyle(.secondary)
                    TextField("0", value: $unit.monthlyRent, format: .number.grouping(.automatic).precision(.fractionLength(0)))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .accessibilityLabel("\(unit.name) monthly rent")
                }
            }
            .onDelete { inputs.units.remove(atOffsets: $0) }
            Button {
                inputs.units.append(DealInputs.UnitRent(name: "Unit \(inputs.units.count + 1)"))
            } label: {
                Label("Add Unit", systemImage: "plus")
            }
        } header: {
            Text("Rent Roll — \(Money.format(result.grossMonthlyRent))/mo gross")
        } footer: {
            Text("Toggle off vacant units. With no units listed, the single Monthly Rent field below is used.")
        }
    }

    private var purchaseSection: some View {
        Section("Purchase & Financing") {
            moneyRow("Purchase price", value: $inputs.purchasePrice)
            percentRow("Down payment", value: $inputs.downPaymentPercent)
            percentRow("Interest rate", value: $inputs.interestRate)
            Stepper("Amortization: \(inputs.amortizationYears) yr",
                    value: $inputs.amortizationYears, in: 5...30, step: 5)
            LabeledContent("Monthly mortgage", value: Money.format(result.monthlyMortgage))
        }
    }

    private var arvSection: some View {
        Section {
            moneyRow("After-renovation value", value: $inputs.arv)
            if inputs.strategy == .flip {
                percentRow("Selling costs", value: $inputs.sellingCostPercent)
                Stepper("Months to flip: \(inputs.monthsToFlip)",
                        value: $inputs.monthsToFlip, in: 1...24)
            }
        } header: {
            Text("ARV")
        } footer: {
            Text("Enter the expected market value after renovation — comps from your realtor, or an appraisal. Automated Teranet valuations plug in here later.")
        }
    }

    private var renoSection: some View {
        Section {
            if let estimateMidpoint, estimateMidpoint > 0, inputs.overrideRenoCost == nil {
                LabeledContent("Renovation cost") {
                    Text(Money.format(estimateMidpoint)).bold().foregroundStyle(.tint)
                }
                Text("From the measured scan estimate — the number every other flip calculator makes you guess.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if inputs.overrideRenoCost == nil {
                ForEach(DealInputs.renoCategories, id: \.name) { category in
                    Toggle(isOn: Binding(
                        get: { inputs.quickReno[category.name] != nil },
                        set: { on in
                            inputs.quickReno[category.name] = on ? (category.low + category.high) / 2 : nil
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name)
                            Text("\(Money.format(category.low)) – \(Money.format(category.high))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let budget = inputs.quickReno[category.name] {
                        moneyRow("    Budget", value: Binding(
                            get: { budget },
                            set: { inputs.quickReno[category.name] = $0 }
                        ))
                    }
                }
            }
            moneyOptionalRow("Override total", value: $inputs.overrideRenoCost)
        } header: {
            Text("Renovation — \(Money.format(result.renoCost))")
        } footer: {
            Text("Source: \(result.renoSource). Capture or trace the property to replace bands with measured quantities.")
        }
    }

    private var incomeSection: some View {
        Section("Rental Income") {
            moneyRow("Monthly rent", value: $inputs.monthlyRent)
            percentRow("Vacancy", value: $inputs.vacancyPercent)
            moneyRow("Monthly costs", value: $inputs.monthlyCosts)
            percentRow("Management", value: $inputs.managementPercent)
            percentRow("Maintenance reserve", value: $inputs.maintenancePercent)
            if inputs.propertyType == .apartment {
                HStack(spacing: 6) {
                    InfoButton(title: "Cap Rate",
                               message: "Capitalization rate: the market's yield for buildings like this. Value = annual net income ÷ cap rate. Ask a commercial realtor for the local rate — Winnipeg multi-family is typically 5–6%.")
                    percentRow("Cap rate (valuation)", value: $inputs.capRatePercent)
                }
            }
            if inputs.strategy == .brrrr {
                percentRow("Refinance LTV", value: $inputs.refinanceLTV)
            }
        }
    }

    private var resultsSection: some View {
        Section("Results") {
            if result.isWinner {
                Label("Strong deal — this one clears your hurdle!", systemImage: "trophy.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
            }
            LabeledContent("Cash invested", value: Money.format(result.cashInvested))
            if inputs.propertyType != .single {
                LabeledContent {
                    Text(String(format: "%.2f", min(result.dscr, 99)))
                        .bold()
                        .foregroundStyle(result.dscr >= 1.2 ? Color.green : .orange)
                } label: {
                    HStack(spacing: 6) {
                        Text("DSCR")
                        InfoButton(title: "DSCR",
                                   message: "Debt Service Coverage Ratio: rental income after expenses ÷ mortgage payment. Lenders on multi-unit buildings usually want 1.2 or higher.")
                    }
                }
                if inputs.propertyType == .apartment {
                    LabeledContent("Income-approach value",
                                   value: Money.format(result.incomeApproachValue))
                }
            }
            switch inputs.strategy {
            case .flip:
                LabeledContent("Projected profit") {
                    Text(Money.format(result.flipProfit))
                        .bold()
                        .foregroundStyle(result.flipProfit >= 0 ? Color.green : .red)
                }
                LabeledContent("Return on investment",
                               value: String(format: "%.1f%%", result.flipROIPercent))
            case .rental:
                LabeledContent("Monthly cash flow") {
                    Text(Money.format(result.monthlyCashFlow))
                        .bold()
                        .foregroundStyle(result.monthlyCashFlow >= 0 ? Color.green : .red)
                }
                LabeledContent {
                    Text(String(format: "%.1f%%", result.cashOnCashPercent))
                } label: {
                    HStack(spacing: 6) {
                        Text("Cash-on-cash")
                        InfoButton(title: "Cash-on-Cash Return",
                                   message: "Annual cash flow ÷ the actual cash you put in (down payment + renovation). The truest measure of what your money earns.")
                    }
                }
                LabeledContent("Cap rate",
                               value: String(format: "%.1f%%", result.capRatePercent))
            case .brrrr:
                LabeledContent("Refinance cash out", value: Money.format(result.refinanceCashOut))
                LabeledContent("Cash left in deal", value: Money.format(result.cashLeftInDeal))
                LabeledContent("Cash flow after refi") {
                    Text(Money.format(result.postRefiCashFlow))
                        .bold()
                        .foregroundStyle(result.postRefiCashFlow >= 0 ? Color.green : .red)
                }
                LabeledContent("Cash-on-cash",
                               value: result.cashOnCashPercent >= 999 ? "∞ (all cash out)"
                                   : String(format: "%.1f%%", result.cashOnCashPercent))
            }
        }
    }

    private var roiPaybackSection: some View {
        Section {
            moneyRow("Monthly rent", value: $roiInputs.monthlyRent)
            percentRow("Vacancy allowance", value: $roiInputs.vacancyPercent)
            moneyRow("Monthly costs", value: $roiInputs.monthlyCosts)
            moneyRow("Build cost", value: Binding(
                get: { roiInputs.overrideBuildCost ?? estimateMidpoint ?? 0 },
                set: { roiInputs.overrideBuildCost = $0 }
            ))
            if roiInputs.overrideBuildCost != nil, estimateMidpoint != nil {
                Button("Use Estimate Midpoint") {
                    roiInputs.overrideBuildCost = nil
                }
            }
            if let roiResult {
                LabeledContent("Net income / year") {
                    Text(Money.format(roiResult.annualNetIncome)).bold()
                }
                LabeledContent("Payback") {
                    Text(roiResult.paybackText).bold()
                }
                LabeledContent("Annual yield") {
                    Text(String(format: "%.1f%%", roiResult.annualYieldPercent)).bold()
                }
                LabeledContent("10-year position") {
                    Text(Money.format(roiResult.tenYearPosition))
                        .bold()
                        .foregroundStyle(roiResult.tenYearPosition >= 0 ? Color.green : .red)
                }
            }
        } header: {
            Text("ROI & Payback")
        } footer: {
            if roiInputs.overrideBuildCost == nil, estimateMidpoint != nil {
                Text("Suite payback on this project's numbers, built in. Build cost uses the estimate midpoint. Planning math only — not financial advice.")
            } else {
                Text("Suite payback on this project's numbers, built in. Planning math only — not financial advice.")
            }
        }
    }

    // MARK: - Rows

    private func moneyRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField("0", value: value, format: .number.grouping(.automatic).precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .accessibilityLabel(label)
        }
    }

    private func moneyOptionalRow(_ label: String, value: Binding<Double?>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField("auto", value: value, format: .number.grouping(.automatic).precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .accessibilityLabel(label)
        }
    }

    private func percentRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .accessibilityLabel(label)
            Text("%").foregroundStyle(.secondary)
        }
    }
}
