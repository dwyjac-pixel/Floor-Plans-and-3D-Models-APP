import SwiftUI
import UIKit
import PDFKit

/// Builds the client-facing PDF report: branded cover page, project details,
/// floor plan with measurements, proposed development, preliminary estimate,
/// and site photos. US Letter pages.
@MainActor
enum PDFExporter {

    private static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 48
    private static var contentWidth: CGFloat { pageRect.width - margin * 2 }
    private static let accent = UIColor(red: 0.55, green: 0.13, blue: 0.18, alpha: 1)

    static func makeReport(for project: RenovationProject,
                           plan: FloorPlanModel?,
                           estimate: EstimateInputs?,
                           planning: PlanningChecklist?,
                           useImperial: Bool,
                           takeoffAdjustments: TakeoffAdjustments = TakeoffAdjustments(),
                           layers: PlanLayers = PlanLayers()) -> URL? {
        let profile = BusinessProfile.load()
        let businessLogo = BusinessProfile.loadLogo()
        let brand: UIColor = {
            if profile.bannerHex != "default", let custom = Color(hexString: profile.bannerHex) {
                return UIColor(custom)
            }
            return accent
        }()
        let reportMarkers = ScanStore.loadMarkers(for: project)?.markers ?? []
        // Traced-room label centroids don't share the LiDAR plan's ARKit
        // coordinate space — suppress them on scanned plans.
        let labelRooms = ScanStore.roomDataURL(for: project) != nil ? [] : ScanStore.loadRooms(for: project)
        let reportRoomLabels = roomLabels(for: labelRooms, useImperial: useImperial)
        // One plan image per storey when the captured rooms span multiple
        // floors (LiDAR plans — labelRooms empty — keep the single image).
        // Any floor that fails to build falls the whole report back to the
        // merged image rather than silently dropping a storey.
        let floorNames = orderedFloorNames(of: labelRooms)
        var floorSections: [(name: String, image: UIImage, plan: FloorPlanModel, rooms: [RoomEntry])] = []
        if floorNames.count > 1 {
            for floorName in floorNames {
                let floorRooms = labelRooms.filter { $0.floorDisplayName == floorName }
                guard let floorPlan = FloorPlanModel(rooms: floorRooms.map(\.room)),
                      let image = renderPlanImage(plan: floorPlan,
                                                  labels: roomLabels(for: floorRooms, useImperial: useImperial),
                                                  markers: reportMarkers,
                                                  layers: layers,
                                                  useImperial: useImperial,
                                                  side: 500, scale: 2) else { continue }
                floorSections.append((floorName, image, floorPlan, floorRooms))
            }
            if floorSections.count != floorNames.count { floorSections = [] }
        }
        var planImage: UIImage?
        if floorSections.isEmpty, let plan {
            planImage = renderPlanImage(plan: plan,
                                        labels: reportRoomLabels,
                                        markers: reportMarkers,
                                        layers: layers,
                                        useImperial: useImperial,
                                        side: 500, scale: 2)
        }

        let captions = ScanStore.loadPhotoCaptions(for: project)
        let photoItems: [(image: UIImage, caption: String)] = project.photoFileNames.compactMap { name in
            guard let url = ScanStore.photoURL(named: name, in: project),
                  let image = UIImage(contentsOfFile: url.path) else { return nil }
            return (image, captions[name] ?? "")
        }

        let estimateResult = estimate.flatMap {
            EstimateCalculator.calculate(inputs: $0, planAreaSquareMeters: plan?.approxFloorAreaSquareMeters)
        }
        let plannedItems = planning?.items.filter(\.planned) ?? []
        let generatedDate = Date.now.formatted(date: .long, time: .omitted)

        let safeName = project.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName) - Project Report.pdf")

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: pageRect)
        do {
            try pdfRenderer.writePDF(to: outputURL) { context in
                var pageNumber = 0

                @MainActor func beginContentPage(_ title: String) -> CGFloat {
                    context.beginPage()
                    pageNumber += 1
                    brand.setFill()
                    UIRectFill(CGRect(x: 0, y: 0, width: pageRect.width, height: 6))
                    let small: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 9),
                        .foregroundColor: UIColor.gray,
                    ]
                    (profile.businessName as NSString)
                        .draw(at: CGPoint(x: margin, y: 16), withAttributes: small)
                    drawRightAligned(project.name, attributes: small, y: 16)
                    drawCentered("Page \(pageNumber)", attributes: small, y: pageRect.height - 28)
                    ("Generated \(generatedDate)" as NSString)
                        .draw(at: CGPoint(x: margin, y: pageRect.height - 28), withAttributes: small)
                    var y: CGFloat = 46
                    y = drawText(title, font: .boldSystemFont(ofSize: 18), color: brand, y: y)
                    return y + 6
                }

                // MARK: Cover page

                context.beginPage()
                pageNumber += 1
                brand.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: pageRect.width, height: 150))
                _ = drawText(profile.businessName.uppercased(),
                             font: .boldSystemFont(ofSize: 24), color: .white, y: 56)
                _ = drawText("Project Report",
                             font: .systemFont(ofSize: 15, weight: .medium),
                             color: UIColor(white: 1, alpha: 0.9), y: 94)
                if !profile.slogan.isEmpty {
                    _ = drawText(profile.slogan,
                                 font: .italicSystemFont(ofSize: 11),
                                 color: UIColor(white: 1, alpha: 0.85), y: 118)
                }
                if let businessLogo {
                    let side: CGFloat = 84
                    let logoRect = CGRect(x: pageRect.width - margin - side, y: 33,
                                          width: side, height: side)
                    let backing = UIBezierPath(roundedRect: logoRect.insetBy(dx: -8, dy: -8),
                                               cornerRadius: 14)
                    UIColor.white.setFill()
                    backing.fill()
                    businessLogo.draw(in: aspectFit(imageSize: businessLogo.size, in: logoRect))
                }

                var y: CGFloat = 200
                y = drawText(project.name, font: .boldSystemFont(ofSize: 26), y: y)
                y += 6
                if !project.clientName.isEmpty {
                    y = drawText(project.clientName, font: .systemFont(ofSize: 15), color: .darkGray, y: y)
                }
                if !project.address.isEmpty {
                    y = drawText(project.address, font: .systemFont(ofSize: 15), color: .darkGray, y: y)
                }
                let contact = [project.phone, project.email].filter { !$0.isEmpty }.joined(separator: "   ·   ")
                if !contact.isEmpty {
                    y = drawText(contact, font: .systemFont(ofSize: 12), color: .gray, y: y)
                }
                y += 24

                var facts = ["Project type: \(project.projectType)",
                             "Estimate: \(project.estimateStatus)   ·   Permit: \(project.permitStatus)"]
                if let plan, let area = plan.approxFloorAreaSquareMeters {
                    facts.append("Approx. floor area: \(Measure.area(area, imperial: useImperial))")
                }
                if let plan, let height = plan.ceilingHeightMeters {
                    facts.append("Ceiling height: \(Measure.length(height, imperial: useImperial))")
                }
                if let estimateResult {
                    facts.append("Rough project range: \(estimateResult.rangeText)")
                }
                if !profile.gstNumber.isEmpty {
                    facts.append("GST/HST #: \(profile.gstNumber)")
                }
                facts.append("Report date: \(generatedDate)")
                for fact in facts {
                    y = drawText(fact, font: .systemFont(ofSize: 13), y: y + 2)
                }
                drawCentered("Prepared with Interior AI Reno Planner — \(profile.businessName)", attributes: [
                    .font: UIFont.systemFont(ofSize: 9),
                    .foregroundColor: UIColor.gray,
                ], y: pageRect.height - 48)

                // MARK: Project details

                y = beginContentPage("Project Details")
                let details: [(String, String)] = [
                    ("Client", project.clientName),
                    ("Address", project.address),
                    ("Phone", project.phone),
                    ("Email", project.email),
                    ("Project type", project.projectType),
                    ("Created", project.createdAt.formatted(date: .long, time: .omitted)),
                    ("Scan date", project.scanDate?.formatted(date: .long, time: .shortened) ?? "—"),
                    ("Estimate status", project.estimateStatus),
                    ("Permit status", project.permitStatus),
                ]
                for (label, value) in details where !value.isEmpty {
                    y = drawKeyValueRow(label: label, value: value, y: y)
                }
                if !project.notes.isEmpty {
                    y += 18
                    y = drawText("Notes", font: .boldSystemFont(ofSize: 14), color: brand, y: y)
                    y = drawText(String(project.notes.prefix(4000)), font: .systemFont(ofSize: 12), y: y)
                }

                // MARK: Floor plan

                @MainActor func drawFloorPlanSection(title: String,
                                                     image: UIImage,
                                                     sectionPlan: FloorPlanModel,
                                                     sectionRooms: [RoomEntry]) {
                    y = beginContentPage(title)
                    let imageSide: CGFloat = 400
                    let imageRect = CGRect(x: (pageRect.width - imageSide) / 2, y: y + 4,
                                           width: imageSide, height: imageSide)
                    image.draw(in: imageRect)
                    y = imageRect.maxY + 10
                    for item in sectionPlan.summaryItems(useImperial: useImperial) {
                        if y > pageRect.height - 80 {
                            y = beginContentPage("\(title) (continued)")
                        }
                        y = drawKeyValueRow(label: item.label, value: item.value, y: y)
                    }
                    if sectionRooms.count > 1 {
                        y += 8
                        if y > pageRect.height - 80 {
                            y = beginContentPage("\(title) (continued)")
                        }
                        y = drawText("Rooms", font: .boldSystemFont(ofSize: 13), color: brand, y: y)
                        for entry in sectionRooms {
                            if y > pageRect.height - 80 {
                                y = beginContentPage("\(title) (continued)")
                            }
                            y = drawKeyValueRow(label: entry.name,
                                                value: Measure.area(entry.room.floorAreaSquareMeters,
                                                                    imperial: useImperial),
                                                y: y)
                        }
                    }
                    if let correction = sectionRooms.compactMap(\.room.verifiedAccuracyPercent).max() {
                        if y > pageRect.height - 80 {
                            y = beginContentPage("\(title) (continued)")
                        }
                        y = drawText(String(format: "Tape-verified: plan scaled to an on-site measurement (%.1f%% correction applied).", correction),
                                     font: .italicSystemFont(ofSize: 9), color: .gray, y: y + 4)
                    }
                    if !sectionPlan.walls.isEmpty {
                        y += 8
                        if y > pageRect.height - 80 {
                            y = beginContentPage("\(title) (continued)")
                        }
                        y = drawText("Wall lengths", font: .boldSystemFont(ofSize: 13), color: brand, y: y)
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: UIFont.systemFont(ofSize: 10),
                            .foregroundColor: UIColor.darkGray,
                        ]
                        let wallTexts = sectionPlan.walls.enumerated().map {
                            "Wall \($0.offset + 1): \(Measure.length($0.element.lengthMeters, imperial: useImperial))"
                        }
                        var index = 0
                        while index < wallTexts.count {
                            if y > pageRect.height - 60 {
                                y = beginContentPage("\(title) (continued)")
                            }
                            (wallTexts[index] as NSString)
                                .draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
                            if index + 1 < wallTexts.count {
                                (wallTexts[index + 1] as NSString)
                                    .draw(at: CGPoint(x: margin + contentWidth / 2, y: y), withAttributes: attrs)
                            }
                            index += 2
                            y += 14
                        }
                    }
                    if y < pageRect.height - 52 {
                        _ = drawText("Measurements are approximate. Verify critical dimensions on site.",
                                     font: .italicSystemFont(ofSize: 9), color: .gray, y: y + 6)
                    }
                }

                if !floorSections.isEmpty {
                    for section in floorSections {
                        drawFloorPlanSection(title: "Floor Plan — \(section.name)",
                                             image: section.image,
                                             sectionPlan: section.plan,
                                             sectionRooms: section.rooms)
                    }
                } else if let planImage, let plan {
                    drawFloorPlanSection(title: "Floor Plan",
                                         image: planImage,
                                         sectionPlan: plan,
                                         sectionRooms: ScanStore.loadRooms(for: project))
                }

                // MARK: Proposed development

                if !plannedItems.isEmpty || plan != nil {
                    y = beginContentPage("Proposed Development")
                    let assessment = SuiteAssessment.evaluate(
                        areaSquareMeters: plan?.approxFloorAreaSquareMeters,
                        ceilingMeters: plan?.ceilingHeightMeters,
                        planning: planning,
                        estimate: estimate)
                    y = drawText(assessment.headline, font: .boldSystemFont(ofSize: 14), y: y)
                    for note in assessment.notes {
                        y = drawText("– \(note)", font: .systemFont(ofSize: 10), color: .darkGray, y: y)
                    }
                    y += 10
                    for item in plannedItems {
                        if y > pageRect.height - 80 {
                            y = beginContentPage("Proposed Development (continued)")
                        }
                        y = drawText("•  \(item.title)", font: .systemFont(ofSize: 13, weight: .semibold), y: y)
                        if !item.note.isEmpty {
                            y = drawText(item.note, font: .systemFont(ofSize: 11), color: .darkGray, y: y, indent: 16)
                        }
                        y += 4
                    }
                }

                // MARK: Suite compliance

                let complianceRooms = ScanStore.loadRooms(for: project)
                if plan != nil || !complianceRooms.isEmpty {
                    let compliance = SuiteCompliance.evaluate(
                        rooms: complianceRooms,
                        planAreaSquareMeters: plan?.approxFloorAreaSquareMeters,
                        planning: planning,
                        estimate: estimate)
                    y = beginContentPage("Suite Compliance (Guidance)")
                    y = drawText(compliance.headline, font: .boldSystemFont(ofSize: 13), y: y)
                    y += 6
                    for check in compliance.checks {
                        if y > pageRect.height - 96 {
                            y = beginContentPage("Suite Compliance (continued)")
                        }
                        let symbol: String
                        switch check.status {
                        case .pass: symbol = "✓"
                        case .warning: symbol = "!"
                        case .fail: symbol = "✕"
                        case .unknown: symbol = "?"
                        }
                        y = drawText("\(symbol)  \(check.title)",
                                     font: .systemFont(ofSize: 12, weight: .semibold), y: y)
                        y = drawText(check.detail, font: .systemFont(ofSize: 10),
                                     color: .darkGray, y: y, indent: 16)
                        if check.reference != "—" {
                            y = drawText(check.reference, font: .italicSystemFont(ofSize: 8),
                                         color: .gray, y: y, indent: 16)
                        }
                        y += 5
                    }
                    y += 6
                    _ = drawText("Guidance only, based on \(compliance.preset.name) provisions. Editions and municipal requirements vary — confirm everything with the local authority before construction.",
                                 font: .italicSystemFont(ofSize: 9), color: .gray, y: y)
                }

                // MARK: Preliminary estimate

                if let estimate, let estimateResult {
                    y = beginContentPage("Preliminary Estimate")
                    y = drawText(scopeSummary(estimate, squareFeet: estimateResult.squareFeet),
                                 font: .systemFont(ofSize: 12), color: .darkGray, y: y)
                    y += 10
                    let rowFont = UIFont.systemFont(ofSize: 12)
                    for line in estimateResult.lines {
                        (line.label as NSString).draw(at: CGPoint(x: margin, y: y),
                                                      withAttributes: [.font: rowFont, .foregroundColor: UIColor.black])
                        drawRightAligned(line.rangeText,
                                         attributes: [.font: rowFont, .foregroundColor: UIColor.darkGray], y: y)
                        y += 20
                    }
                    y += 4
                    brand.setFill()
                    UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: 1.5))
                    y += 10
                    let totalFont = UIFont.boldSystemFont(ofSize: 14)
                    ("Total rough range" as NSString).draw(at: CGPoint(x: margin, y: y),
                                                           withAttributes: [.font: totalFont, .foregroundColor: UIColor.black])
                    drawRightAligned(estimateResult.rangeText,
                                     attributes: [.font: totalFont, .foregroundColor: accent], y: y)
                    y += 30
                    y = drawKeyValueRow(label: "Materials (approx.)", value: estimateResult.materialsText, y: y)
                    y = drawKeyValueRow(label: "Labour (approx.)", value: estimateResult.labourText, y: y)
                    if !estimate.notes.isEmpty {
                        y += 10
                        y = drawText("Estimate notes", font: .boldSystemFont(ofSize: 13), color: brand, y: y)
                        y = drawText(String(estimate.notes.prefix(2000)),
                                     font: .systemFont(ofSize: 11), color: .darkGray, y: y)
                    }
                    y += 12
                    _ = drawText("Preliminary planning range only — not a quote. Final pricing requires a site visit and a detailed scope of work.",
                                 font: .italicSystemFont(ofSize: 9), color: .gray, y: y)
                }

                // MARK: Investment outlook (suite ROI)

                if let estimateResult,
                   let roiInputs = ScanStore.loadROI(for: project),
                   let roi = ROICalculator.calculate(
                        inputs: roiInputs,
                        estimateMidpoint: (estimateResult.totalLow + estimateResult.totalHigh) / 2) {
                    y = beginContentPage("Investment Outlook")
                    y = drawText("What the finished suite could return at the owner's numbers:",
                                 font: .systemFont(ofSize: 12), color: .darkGray, y: y)
                    y += 8
                    y = drawKeyValueRow(label: "Build cost", value: Money.format(roi.buildCost), y: y)
                    y = drawKeyValueRow(label: "Monthly rent",
                                        value: Money.format(roiInputs.monthlyRent), y: y)
                    y = drawKeyValueRow(label: "Vacancy allowance",
                                        value: String(format: "%.0f%%", roiInputs.vacancyPercent), y: y)
                    y = drawKeyValueRow(label: "Monthly costs",
                                        value: Money.format(roiInputs.monthlyCosts), y: y)
                    y += 10
                    y = drawKeyValueRow(label: "Net income per year",
                                        value: Money.format(roi.annualNetIncome), y: y)
                    y = drawKeyValueRow(label: "Payback", value: roi.paybackText, y: y)
                    y = drawKeyValueRow(label: "Annual yield",
                                        value: String(format: "%.1f%%", roi.annualYieldPercent), y: y)
                    y += 12
                    _ = drawText("Planning math only — not financial advice. Verify local rents, taxes, and financing.",
                                 font: .italicSystemFont(ofSize: 9), color: .gray, y: y)
                }

                // MARK: Material takeoff

                let takeoffRooms = ScanStore.loadRooms(for: project)
                if !takeoffRooms.isEmpty {
                    let takeoff = MaterialTakeoff.calculate(rooms: takeoffRooms.map(\.room))
                    if !takeoff.lines.isEmpty {
                        y = beginContentPage("Material Takeoff")
                        var currentCategory = ""
                        for line in takeoff.lines {
                            if y > pageRect.height - 80 {
                                y = beginContentPage("Material Takeoff (continued)")
                                currentCategory = ""
                            }
                            if line.category != currentCategory {
                                currentCategory = line.category
                                y += 8
                                y = drawText(currentCategory, font: .boldSystemFont(ofSize: 13),
                                             color: brand, y: y)
                            }
                            let included = takeoffAdjustments.isIncluded(line)
                            var rowText = line.note.isEmpty
                                ? "\(line.item): \(line.quantity)"
                                : "\(line.item): \(line.quantity)  (\(line.note))"
                            if let price = takeoffAdjustments.price(for: line) {
                                rowText += "  —  \(Money.format(price))"
                            }
                            if !included {
                                rowText += "  (excluded)"
                            }
                            y = drawText(rowText, font: .systemFont(ofSize: 11),
                                         color: included ? .black : .gray, y: y)
                        }
                        let includedTotal = takeoffAdjustments.total(for: takeoff)
                        if includedTotal > 0 {
                            y += 6
                            if y > pageRect.height - 80 {
                                y = beginContentPage("Material Takeoff (continued)")
                            }
                            y = drawKeyValueRow(label: "Included total",
                                                value: Money.format(includedTotal), y: y)
                        }
                        y += 10
                        _ = drawText("Quantities are planning estimates with a 10% waste factor — verify before ordering.",
                                     font: .italicSystemFont(ofSize: 9), color: .gray, y: y)
                    }
                }

                // MARK: Photos

                var photoIndex = 0
                while photoIndex < photoItems.count {
                    var photoY = beginContentPage("Photos")
                    for _ in 0..<2 {
                        guard photoIndex < photoItems.count else { break }
                        let item = photoItems[photoIndex]
                        let slot = CGRect(x: margin, y: photoY, width: contentWidth, height: 290)
                        let fitted = aspectFit(imageSize: item.image.size, in: slot)
                        item.image.draw(in: fitted)
                        var bottom = fitted.maxY + 4
                        if !item.caption.isEmpty {
                            bottom = drawText(item.caption, font: .systemFont(ofSize: 10),
                                              color: .darkGray, y: bottom)
                        }
                        photoY = max(slot.maxY, bottom) + 16
                        photoIndex += 1
                    }
                }
            }
            return outputURL
        } catch {
            return nil
        }
    }

    // MARK: - Drawing helpers

    // MARK: - Permit package

    /// The submission set: a bordered floor plan sheet with title block and
    /// north arrow, the suite compliance report, and the material takeoff.
    static func makePermitPackage(for project: RenovationProject,
                                  plan: FloorPlanModel?,
                                  estimate: EstimateInputs?,
                                  planning: PlanningChecklist?,
                                  useImperial: Bool,
                                  takeoffAdjustments: TakeoffAdjustments = TakeoffAdjustments(),
                                  layers: PlanLayers = PlanLayers()) -> URL? {
        guard let plan else { return nil }
        let profile = BusinessProfile.load()
        let rooms = ScanStore.loadRooms(for: project)
        let reportMarkers = ScanStore.loadMarkers(for: project)?.markers ?? []

        let canvasSide: CGFloat = 640
        // One plan sheet per storey when the rooms span multiple floors. Any
        // floor that fails to build falls the package back to the merged
        // sheet rather than silently dropping a storey.
        let floorNames = orderedFloorNames(of: rooms)
        var floorSheets: [(name: String, image: UIImage, plan: FloorPlanModel)] = []
        if floorNames.count > 1 {
            for floorName in floorNames {
                let floorRooms = rooms.filter { $0.floorDisplayName == floorName }
                guard let floorPlan = FloorPlanModel(rooms: floorRooms.map(\.room)),
                      let image = renderPlanImage(plan: floorPlan,
                                                  labels: roomLabels(for: floorRooms, useImperial: useImperial),
                                                  markers: reportMarkers,
                                                  layers: layers,
                                                  useImperial: useImperial,
                                                  side: canvasSide, scale: 3) else { continue }
                floorSheets.append((floorName, image, floorPlan))
            }
            if floorSheets.count != floorNames.count { floorSheets = [] }
        }
        var mergedPlanImage: UIImage?
        if floorSheets.isEmpty {
            guard let image = renderPlanImage(plan: plan,
                                              labels: roomLabels(for: rooms, useImperial: useImperial),
                                              markers: reportMarkers,
                                              layers: layers,
                                              useImperial: useImperial,
                                              side: canvasSide, scale: 3) else { return nil }
            mergedPlanImage = image
        }

        let generatedDate = Date.now.formatted(date: .abbreviated, time: .omitted)
        let safeName = project.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName) - Permit Package.pdf")

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: pageRect)
        do {
            try pdfRenderer.writePDF(to: outputURL) { context in
                var sheetNumber = 0

                func beginSheet(_ title: String) -> CGRect {
                    context.beginPage()
                    sheetNumber += 1
                    let border = CGRect(x: 22, y: 22,
                                        width: pageRect.width - 44, height: pageRect.height - 44)
                    UIColor.black.setStroke()
                    let borderPath = UIBezierPath(rect: border)
                    borderPath.lineWidth = 1.6
                    borderPath.stroke()

                    let blockHeight: CGFloat = 74
                    let block = CGRect(x: border.minX, y: border.maxY - blockHeight,
                                       width: border.width, height: blockHeight)
                    UIBezierPath(rect: block).stroke()
                    let columnWidth = block.width / 3
                    for columnIndex in 1..<3 {
                        let divider = UIBezierPath()
                        divider.move(to: CGPoint(x: block.minX + columnWidth * CGFloat(columnIndex),
                                                 y: block.minY))
                        divider.addLine(to: CGPoint(x: block.minX + columnWidth * CGFloat(columnIndex),
                                                    y: block.maxY))
                        divider.lineWidth = 0.8
                        divider.stroke()
                    }
                    func blockText(_ text: String, column: Int, row: Int, bold: Bool = false) {
                        guard !text.isEmpty else { return }
                        (text as NSString).draw(
                            at: CGPoint(x: block.minX + columnWidth * CGFloat(column) + 10,
                                        y: block.minY + 9 + CGFloat(row) * 16),
                            withAttributes: [
                                .font: bold ? UIFont.boldSystemFont(ofSize: 11)
                                            : UIFont.systemFont(ofSize: 8),
                                .foregroundColor: UIColor.black,
                            ])
                    }
                    blockText(profile.businessName, column: 0, row: 0, bold: true)
                    blockText([profile.phone, profile.email].filter { !$0.isEmpty }
                        .joined(separator: "  ·  "), column: 0, row: 1)
                    blockText(profile.gstNumber.isEmpty ? "" : "GST/HST # \(profile.gstNumber)",
                              column: 0, row: 2)
                    blockText(project.name, column: 1, row: 0, bold: true)
                    blockText(project.address, column: 1, row: 1)
                    blockText(project.clientName.isEmpty ? "" : "Client: \(project.clientName)",
                              column: 1, row: 2)
                    blockText(title, column: 2, row: 0, bold: true)
                    blockText("Sheet \(sheetNumber)   ·   \(generatedDate)", column: 2, row: 1)
                    blockText("Preliminary — verify all dimensions on site", column: 2, row: 2)

                    return CGRect(x: border.minX, y: border.minY,
                                  width: border.width, height: border.height - blockHeight)
                }

                // Sheet 1 — floor plan with north arrow and scale note; one
                // sheet per storey when the project spans multiple floors.
                @MainActor func drawPlanSheet(title: String, image: UIImage, sheetPlan: FloorPlanModel) {
                    let planContent = beginSheet(title)
                    let fitted = aspectFit(imageSize: image.size,
                                           in: planContent.insetBy(dx: 14, dy: 16))
                    image.draw(in: fitted)

                    let northCenter = CGPoint(x: planContent.maxX - 36, y: planContent.minY + 42)
                    UIColor.black.setStroke()
                    let circle = UIBezierPath(ovalIn: CGRect(x: northCenter.x - 13, y: northCenter.y - 13,
                                                             width: 26, height: 26))
                    circle.lineWidth = 1
                    circle.stroke()
                    let arrow = UIBezierPath()
                    arrow.move(to: CGPoint(x: northCenter.x, y: northCenter.y + 8))
                    arrow.addLine(to: CGPoint(x: northCenter.x, y: northCenter.y - 7))
                    arrow.addLine(to: CGPoint(x: northCenter.x - 4, y: northCenter.y - 2))
                    arrow.move(to: CGPoint(x: northCenter.x, y: northCenter.y - 7))
                    arrow.addLine(to: CGPoint(x: northCenter.x + 4, y: northCenter.y - 2))
                    arrow.lineWidth = 1.2
                    arrow.stroke()
                    ("N" as NSString).draw(at: CGPoint(x: northCenter.x - 4, y: northCenter.y - 29),
                                           withAttributes: [.font: UIFont.boldSystemFont(ofSize: 10),
                                                            .foregroundColor: UIColor.black])

                    let boundsMax = max(Double(sheetPlan.bounds.width), Double(sheetPlan.bounds.height), 0.5)
                    let usablePoints = Double(min(fitted.width, fitted.height)) * (1 - 92 / Double(canvasSide))
                    let scaleDenominator = max(Int((boundsMax * 2834.65 / max(usablePoints, 1)).rounded()), 1)
                    ("Scale ≈ 1:\(scaleDenominator)   ·   dimensions in \(useImperial ? "feet & inches" : "metres")" as NSString)
                        .draw(at: CGPoint(x: planContent.minX + 14, y: planContent.maxY - 20),
                              withAttributes: [.font: UIFont.systemFont(ofSize: 9),
                                               .foregroundColor: UIColor.darkGray])
                }

                if let mergedPlanImage {
                    drawPlanSheet(title: "FLOOR PLAN", image: mergedPlanImage, sheetPlan: plan)
                } else {
                    for sheet in floorSheets {
                        drawPlanSheet(title: "FLOOR PLAN — \(sheet.name.uppercased())",
                                      image: sheet.image, sheetPlan: sheet.plan)
                    }
                }

                // Sheet 2 — suite compliance.
                var content = beginSheet("SUITE COMPLIANCE")
                let compliance = SuiteCompliance.evaluate(
                    rooms: rooms,
                    planAreaSquareMeters: plan.approxFloorAreaSquareMeters,
                    planning: planning, estimate: estimate)
                var y = content.minY + 18
                y = drawText(compliance.headline, font: .boldSystemFont(ofSize: 13), y: y)
                y += 4
                for check in compliance.checks {
                    if y > content.maxY - 60 {
                        content = beginSheet("SUITE COMPLIANCE (CONT'D)")
                        y = content.minY + 18
                    }
                    let symbol: String
                    switch check.status {
                    case .pass: symbol = "✓"
                    case .warning: symbol = "!"
                    case .fail: symbol = "✕"
                    case .unknown: symbol = "?"
                    }
                    y = drawText("\(symbol)  \(check.title)",
                                 font: .systemFont(ofSize: 11, weight: .semibold), y: y)
                    y = drawText(check.detail, font: .systemFont(ofSize: 9),
                                 color: .darkGray, y: y, indent: 14)
                    y += 3
                }
                y += 6
                _ = drawText("Guidance only, based on \(compliance.preset.name) provisions — confirm with the local authority.",
                             font: .italicSystemFont(ofSize: 8), color: .gray, y: y)

                // Sheet — required application measurements.
                var permitContent = beginSheet("REQUIRED MEASUREMENTS")
                var permitY = permitContent.minY + 18
                @MainActor func permitRow(_ label: String, _ value: String) {
                    if permitY > permitContent.maxY - 96 {
                        permitContent = beginSheet("REQUIRED MEASUREMENTS (CONT'D)")
                        permitY = permitContent.minY + 18
                    }
                    permitY = drawText("\(label): \(value)", font: .systemFont(ofSize: 11), y: permitY)
                }
                let permit = ScanStore.loadPermitMeasurements(for: project) ?? PermitMeasurements()
                permitY = drawText("Basement application measurements", font: .boldSystemFont(ofSize: 13), y: permitY)
                permitY += 4
                permitRow("Bedrooms being created", "\(permit.bedroomsCreated)")
                if permit.beamHeightMeters > 0 {
                    permitRow("Finish height under beam / bulkhead",
                              Measure.length(permit.beamHeightMeters, imperial: useImperial))
                }
                if permit.stairHeadClearanceMeters > 0 {
                    permitRow("Head clearance at stairs",
                              Measure.length(permit.stairHeadClearanceMeters, imperial: useImperial))
                }
                // Grouped storey by storey when the project spans floors, with
                // the floor carried in each label — two floors can both have
                // a "Bedroom".
                let measurementRooms = floorNames.count > 1
                    ? floorNames.flatMap { name in rooms.filter { $0.floorDisplayName == name } }
                    : rooms
                func measurementName(_ entry: RoomEntry) -> String {
                    floorNames.count > 1 ? "\(entry.name) (\(entry.floorDisplayName))" : entry.name
                }
                for entry in measurementRooms {
                    if entry.room.ceilingHeightMeters > 0 {
                        permitRow("Ceiling height — \(measurementName(entry))",
                                  Measure.length(entry.room.ceilingHeightMeters, imperial: useImperial))
                    } else {
                        permitRow("Ceiling height — \(measurementName(entry))", "not recorded")
                    }
                }
                for entry in measurementRooms {
                    for window in entry.room.openings where window.kind == .window {
                        let windowHeightText: String
                        if let height = window.heightMeters {
                            windowHeightText = Measure.length(height, imperial: useImperial)
                        } else {
                            windowHeightText = "\(Measure.length(1.07, imperial: useImperial)) (assumed)"
                        }
                        permitRow("Window — \(measurementName(entry))",
                                  "\(Measure.length(window.widthMeters, imperial: useImperial)) × \(windowHeightText)")
                        if let clearW = window.clearWidthMeters, let clearH = window.clearHeightMeters {
                            permitRow("    Unobstructed opening",
                                      "\(Measure.length(clearW, imperial: useImperial)) × \(Measure.length(clearH, imperial: useImperial))")
                        } else {
                            permitRow("    Unobstructed opening", "not recorded")
                        }
                    }
                    for door in entry.room.openings where door.kind == .door || door.kind == .closetDoor {
                        let doorHeightText: String
                        if let height = door.heightMeters {
                            doorHeightText = Measure.length(height, imperial: useImperial)
                        } else {
                            doorHeightText = "\(Measure.length(2.03, imperial: useImperial)) (assumed)"
                        }
                        permitRow("Door — \(measurementName(entry))",
                                  "\(Measure.length(door.widthMeters, imperial: useImperial)) × \(doorHeightText)")
                    }
                }
                if !permit.notes.isEmpty {
                    permitY += 6
                    permitY = drawText("Notes: \(permit.notes)", font: .systemFont(ofSize: 10),
                                       color: .darkGray, y: permitY)
                }

                // Sheet 3 — material takeoff.
                if !rooms.isEmpty {
                    var takeoffContent = beginSheet("MATERIAL TAKEOFF")
                    let takeoff = MaterialTakeoff.calculate(rooms: rooms.map(\.room))
                    var takeoffY = takeoffContent.minY + 18
                    var currentCategory = ""
                    for line in takeoff.lines {
                        if takeoffY > takeoffContent.maxY - 50 {
                            takeoffContent = beginSheet("MATERIAL TAKEOFF (CONT'D)")
                            takeoffY = takeoffContent.minY + 18
                            currentCategory = ""
                        }
                        if line.category != currentCategory {
                            currentCategory = line.category
                            takeoffY += 6
                            takeoffY = drawText(currentCategory,
                                                font: .boldSystemFont(ofSize: 12), y: takeoffY)
                        }
                        let included = takeoffAdjustments.isIncluded(line)
                        var rowText = line.note.isEmpty
                            ? "\(line.item): \(line.quantity)"
                            : "\(line.item): \(line.quantity)  (\(line.note))"
                        if let price = takeoffAdjustments.price(for: line) {
                            rowText += "  —  \(Money.format(price))"
                        }
                        if !included {
                            rowText += "  (excluded)"
                        }
                        takeoffY = drawText(rowText, font: .systemFont(ofSize: 10),
                                            color: included ? .black : .gray, y: takeoffY)
                    }
                    let includedTotal = takeoffAdjustments.total(for: takeoff)
                    if includedTotal > 0 {
                        if takeoffY > takeoffContent.maxY - 50 {
                            takeoffContent = beginSheet("MATERIAL TAKEOFF (CONT'D)")
                            takeoffY = takeoffContent.minY + 18
                        }
                        takeoffY += 6
                        takeoffY = drawText("Included total: \(Money.format(includedTotal))",
                                            font: .boldSystemFont(ofSize: 11), y: takeoffY)
                    }
                    takeoffY += 8
                    _ = drawText("Planning quantities with a 10% waste factor — verify before ordering.",
                                 font: .italicSystemFont(ofSize: 8), color: .gray, y: takeoffY)
                }
            }
        } catch {
            return nil
        }
        return outputURL
    }

    /// Distinct storey names in room order. More than one means the plan is
    /// rendered per floor — storeys overlap in plan space, so a single merged
    /// image would draw them on top of each other.
    private static func orderedFloorNames(of entries: [RoomEntry]) -> [String] {
        var names: [String] = []
        for entry in entries where !names.contains(entry.floorDisplayName) {
            names.append(entry.floorDisplayName)
        }
        return names
    }

    private static func roomLabels(for entries: [RoomEntry],
                                   useImperial: Bool) -> [(name: String, area: String, center: CGPoint)] {
        entries.compactMap { entry in
            guard entry.room.corners.count >= 3 else { return nil }
            let count = Double(entry.room.corners.count)
            return (entry.name,
                    Measure.area(entry.room.floorAreaSquareMeters, imperial: useImperial),
                    CGPoint(x: entry.room.corners.map(\.x).reduce(0, +) / count,
                            y: entry.room.corners.map(\.z).reduce(0, +) / count))
        }
    }

    private static func renderPlanImage(plan: FloorPlanModel,
                                        labels: [(name: String, area: String, center: CGPoint)],
                                        markers: [PlanMarkers.Marker],
                                        layers: PlanLayers,
                                        useImperial: Bool,
                                        side: CGFloat,
                                        scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content:
            FloorPlanCanvas(plan: plan, useImperial: useImperial, markers: markers,
                            roomLabels: labels, layers: layers, exportBackground: true)
                .frame(width: side, height: side)
                .background(Color.white)
                .environment(\.colorScheme, .light))
        renderer.scale = scale
        return renderer.uiImage
    }

    private static func drawText(_ text: String,
                                 font: UIFont,
                                 color: UIColor = .black,
                                 y: CGFloat,
                                 indent: CGFloat = 0) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = contentWidth - indent
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil)
        (text as NSString).draw(
            with: CGRect(x: margin + indent, y: y, width: width, height: ceil(bounding.height)),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil)
        return y + ceil(bounding.height) + 6
    }

    private static func drawKeyValueRow(label: String, value: String, y: CGFloat) -> CGFloat {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor.gray,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: UIColor.black,
        ]
        let valueX = margin + 140
        let valueWidth = pageRect.width - margin - valueX
        (label.uppercased() as NSString).draw(at: CGPoint(x: margin, y: y + 2), withAttributes: labelAttrs)
        let bounding = (value as NSString).boundingRect(
            with: CGSize(width: valueWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: valueAttrs, context: nil)
        (value as NSString).draw(
            with: CGRect(x: valueX, y: y, width: valueWidth, height: ceil(bounding.height)),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: valueAttrs, context: nil)
        return y + max(ceil(bounding.height), 16) + 6
    }

    private static func drawRightAligned(_ text: String,
                                         attributes: [NSAttributedString.Key: Any],
                                         y: CGFloat) {
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: pageRect.width - margin - size.width, y: y),
                                withAttributes: attributes)
    }

    private static func drawCentered(_ text: String,
                                     attributes: [NSAttributedString.Key: Any],
                                     y: CGFloat) {
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: (pageRect.width - size.width) / 2, y: y),
                                withAttributes: attributes)
    }

    private static func scopeSummary(_ inputs: EstimateInputs, squareFeet: Double) -> String {
        var parts: [String] = []
        if inputs.bedrooms > 0 { parts.append("\(inputs.bedrooms) bedroom\(inputs.bedrooms == 1 ? "" : "s")") }
        if inputs.bathrooms > 0 { parts.append("\(inputs.bathrooms) bathroom\(inputs.bathrooms == 1 ? "" : "s")") }
        if inputs.kitchen != .none { parts.append(inputs.kitchen.rawValue.lowercased()) }
        if inputs.egressWindows > 0 { parts.append("\(inputs.egressWindows) egress window\(inputs.egressWindows == 1 ? "" : "s")") }
        if inputs.sideDoorEntrance { parts.append("side-door entrance") }
        if inputs.laundry { parts.append("laundry") }
        if inputs.demolition { parts.append("demolition") }
        let scope = parts.isEmpty ? "General basement development" : parts.joined(separator: ", ")
        return "Scope: \(scope) — \(inputs.finishLevel.rawValue) finish, \(inputs.flooring.rawValue.lowercased()) flooring, \(inputs.ceiling.rawValue.lowercased()) ceiling, \(Int(squareFeet.rounded())) sq ft"
    }

    private static func aspectFit(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.minY, width: size.width, height: size.height)
    }
}


/// Full-screen preview of the generated report with sharing.
struct PDFPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFKitView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Report Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
