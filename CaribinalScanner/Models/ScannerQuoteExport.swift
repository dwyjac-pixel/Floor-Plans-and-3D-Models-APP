import Foundation

struct ScannerQuoteExport: Encodable {
    struct Client: Encodable {
        var name: String
        var email: String
        var phone: String
        var address: String
        var postal_code: String
    }

    struct Line: Encodable {
        var category: String
        var description: String
        var quantity_label: String
        var notes: String
        var amount_cents: Int?

        enum CodingKeys: String, CodingKey {
            case category, description, quantity_label, notes, amount_cents
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(category, forKey: .category)
            try container.encode(description, forKey: .description)
            try container.encode(quantity_label, forKey: .quantity_label)
            try container.encode(notes, forKey: .notes)
            try container.encode(amount_cents, forKey: .amount_cents)
        }
    }

    struct Pricing: Encodable {
        let currency = "CAD"
        var lines: [Line]
        var subtotal_cents: Int
        var markup_cents: Int
        var tax_label: String
        var tax_rate: Decimal
        var tax_cents: Int
        var total_cents: Int
    }

    let version = 1
    let source = "caribinal-scanner"
    let kind = "quote"
    var project_id: UUID
    var title: String
    var project_type: String
    var client: Client
    var notes: String
    var measurements: ScannerRevisionExport?
    var pricing: Pricing?

    enum ExportError: LocalizedError {
        case missingClient, pricing, invalidProject

        var errorDescription: String? {
            switch self {
            case .missingClient: "Add a client name, property address, and a valid email or phone number in Project Details."
            case .pricing: "Check the quote prices, markup, and tax before exporting."
            case .invalidProject: "This project could not be prepared for EstiMater."
            }
        }
    }

    static func make(project: RenovationProject, takeoff: MaterialTakeoff, adjustments: TakeoffAdjustments,
                     settings: QuoteSettings) throws -> ScannerQuoteExport {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func cents(_ value: Double) throws -> Int {
            guard value.isFinite, value >= 0, value <= 1_000_000_000 else { throw ExportError.pricing }
            return Int((value * 100).rounded())
        }
        let client = Client(name: clean(project.clientName), email: clean(project.email), phone: clean(project.phone),
                            address: clean(project.address), postal_code: clean(project.postalCode))
        let emailValid = client.email.isEmpty || client.email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
        let phoneValid = client.phone.isEmpty || client.phone.filter(\.isNumber).count >= 7
        guard !client.name.isEmpty, !client.address.isEmpty, !client.email.isEmpty || !client.phone.isEmpty,
              emailValid, phoneValid else { throw ExportError.missingClient }
        guard let projectID = UUID(uuidString: project.folderName) else { throw ExportError.invalidProject }

        let history = try ScanStore.loadPlanHistory(for: project)
        let measurements = history.map { history in
            ScannerRevisionExport(snapshot: history.proposedRevisions.last ?? history.existingConditions,
                                  existingConditionsID: history.existingConditions.id)
        }
        let lines = try takeoff.lines.filter(adjustments.isIncluded).map { line in
            Line(category: line.category, description: line.item, quantity_label: line.quantity, notes: line.note,
                 amount_cents: try adjustments.price(for: line).map(cents))
        }
        var pricing: Pricing?
        if !lines.isEmpty {
            guard lines.count <= 500, (0...100).contains(settings.taxPercent), settings.markupPercent >= 0,
                  let taxRate = QuoteSettings.exactPercent(settings.taxPercent),
                  let markupRate = QuoteSettings.exactPercent(settings.markupPercent),
                  !clean(settings.taxLabel).isEmpty else { throw ExportError.pricing }
            let subtotal = lines.reduce(0) { $0 + ($1.amount_cents ?? 0) }
            guard let markup = QuoteSettings.cents(subtotal, percent: markupRate), markup <= 100_000_000_000,
                  let tax = QuoteSettings.cents(subtotal + markup, percent: taxRate) else { throw ExportError.pricing }
            let total = subtotal + markup + tax
            guard total <= 100_000_000_000 else { throw ExportError.pricing }
            pricing = Pricing(lines: lines, subtotal_cents: subtotal, markup_cents: markup,
                              tax_label: clean(settings.taxLabel), tax_rate: taxRate,
                              tax_cents: tax, total_cents: total)
        }
        return ScannerQuoteExport(project_id: projectID, title: clean(project.name), project_type: project.projectType,
                                  client: client, notes: clean(project.notes), measurements: measurements, pricing: pricing)
    }
}
