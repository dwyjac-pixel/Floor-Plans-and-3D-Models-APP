import Foundation

/// Code-aware secondary-suite checks. Measured checks are computed straight
/// from the captured geometry (windows, ceilings, areas); declared checks
/// read the planning checklist, estimate scope, and placed fixtures.
/// Thresholds follow National Building Code secondary-suite provisions as
/// adopted in Manitoba — guidance only; editions and municipal requirements
/// vary, so everything must be confirmed with the local authority.
struct SuiteCompliance {
    struct Preset {
        let name: String
        let minCeilingMeters: Double        // suite living space
        let egressOpenAreaM2: Double        // unobstructed opening
        let egressMinDimensionMeters: Double
        let maxSillMeters: Double           // practical reach guidance
        let bedroomLightRatio: Double       // glass area ÷ floor area

        static let manitoba = Preset(name: "Manitoba (NBC-based)",
                                     minCeilingMeters: 1.95,
                                     egressOpenAreaM2: 0.35,
                                     egressMinDimensionMeters: 0.38,
                                     maxSillMeters: 1.5,
                                     bedroomLightRatio: 0.05)
    }

    enum Status {
        case pass, warning, fail, unknown
    }

    struct Check: Identifiable {
        let id = UUID()
        let title: String
        let status: Status
        let detail: String
        let reference: String
        let measured: Bool   // true = computed from the plan geometry
    }

    let preset: Preset
    let checks: [Check]

    var measuredChecks: [Check] { checks.filter(\.measured) }
    var declaredChecks: [Check] { checks.filter { !$0.measured } }
    var failCount: Int { checks.filter { $0.status == .fail }.count }
    var warningCount: Int { checks.filter { $0.status == .warning }.count }

    var headline: String {
        if failCount == 0, warningCount == 0 {
            return "No issues found in these checks."
        }
        if failCount == 0 {
            return "\(warningCount) item\(warningCount == 1 ? "" : "s") to verify."
        }
        return "\(failCount) item\(failCount == 1 ? "" : "s") need attention, \(warningCount) to verify."
    }

    static func evaluate(rooms: [RoomEntry],
                         planAreaSquareMeters: Double?,
                         planning: PlanningChecklist?,
                         estimate: EstimateInputs?,
                         preset: Preset = .manitoba) -> SuiteCompliance {
        var checks: [Check] = []

        // MARK: Measured — ceiling height (worst room governs)

        let ceilings = rooms.map(\.room.ceilingHeightMeters).filter { $0 > 0.5 }
        if let lowest = ceilings.min() {
            checks.append(Check(
                title: "Ceiling height",
                status: lowest >= preset.minCeilingMeters ? .pass : .fail,
                detail: "Lowest recorded ceiling is \(Measure.length(lowest, imperial: true)); a secondary suite needs \(Measure.length(preset.minCeilingMeters, imperial: true)) over required areas.",
                reference: "NBC 9.5.3 — suite ceiling heights",
                measured: true))
        } else if !rooms.isEmpty {
            checks.append(Check(
                title: "Ceiling height",
                status: .unknown,
                detail: "No ceiling height recorded — set it with Adjust Ceiling Height in the floor plan editor.",
                reference: "NBC 9.5.3",
                measured: true))
        }

        // MARK: Measured — suite size and bedroom capacity

        if let area = planAreaSquareMeters, area > 0 {
            let squareFeet = area * 10.7639
            let capacity: Int
            switch squareFeet {
            case ..<350: capacity = 0
            case ..<550: capacity = 1
            case ..<750: capacity = 2
            default: capacity = 3
            }
            checks.append(Check(
                title: "Suite floor area",
                status: capacity == 0 ? .warning : .pass,
                detail: capacity == 0
                    ? "\(Int(squareFeet.rounded())) sq ft is small for a self-contained suite — best suited to partial development."
                    : "\(Int(squareFeet.rounded())) sq ft supports up to \(capacity) bedroom\(capacity == 1 ? "" : "s").",
                reference: "Planning guidance (350/550/750 sq ft)",
                measured: true))
        }

        // MARK: Measured — bedroom windows (egress, light, sill)

        var namedBedrooms = 0
        for entry in rooms {
            let room = entry.room
            guard entry.name.lowercased().contains("bed") else { continue }
            namedBedrooms += 1
            let windows = room.openings.filter { $0.kind == .window }

            guard !windows.isEmpty else {
                checks.append(Check(
                    title: "\(entry.name) — egress window",
                    status: .fail,
                    detail: "No window on this bedroom's plan. Every suite bedroom needs an openable egress window unless the home is sprinklered.",
                    reference: "NBC 9.9.10.1",
                    measured: true))
                continue
            }

            // Prefer the recorded unobstructed (clear) opening when present —
            // that is what egress is actually judged on (QA-017). Only fall
            // back to the rough frame heuristic (casement opens the full
            // frame, a slider roughly half the width) when no clear opening
            // was measured, and never treat a frame pass that leaned on the
            // assumed default height as a measured pass.
            var passesAsSlider = false
            var passesAsCasement = false
            var clearMeasuredPass = false
            var anyClearRecorded = false
            var frameHeightAssumed = false
            var bestSill = Double.greatestFiniteMagnitude
            var glassArea = 0.0
            for window in windows {
                let height = window.heightMeters ?? 1.07
                let width = window.widthMeters
                glassArea += width * height

                if let cw = window.clearWidthMeters, let ch = window.clearHeightMeters {
                    anyClearRecorded = true
                    let clearOK = min(cw, ch) >= preset.egressMinDimensionMeters
                        && cw * ch >= preset.egressOpenAreaM2
                    if clearOK {
                        clearMeasuredPass = true
                        bestSill = min(bestSill, window.sillMeters ?? 0.91)
                    }
                    continue   // authoritative — skip the frame/slider guess
                }

                let fullOK = min(width, height) >= preset.egressMinDimensionMeters
                    && width * height >= preset.egressOpenAreaM2
                let halfOK = min(width / 2, height) >= preset.egressMinDimensionMeters
                    && (width / 2) * height >= preset.egressOpenAreaM2
                if fullOK || halfOK {
                    bestSill = min(bestSill, window.sillMeters ?? 0.91)
                    if window.heightMeters == nil { frameHeightAssumed = true }
                }
                passesAsCasement = passesAsCasement || fullOK
                passesAsSlider = passesAsSlider || halfOK
            }

            let sizeText = windows.count == 1 ? "its window" : "its best window"
            if clearMeasuredPass {
                checks.append(Check(
                    title: "\(entry.name) — egress window",
                    status: .pass,
                    detail: "Recorded clear opening meets the \(String(format: "%.2f", preset.egressOpenAreaM2)) m² unobstructed opening with no dimension under 380 mm.",
                    reference: "NBC 9.9.10.1",
                    measured: true))
            } else if passesAsSlider, !frameHeightAssumed {
                checks.append(Check(
                    title: "\(entry.name) — egress window",
                    status: .pass,
                    detail: "Meets the \(String(format: "%.2f", preset.egressOpenAreaM2)) m² unobstructed opening with no dimension under 380 mm — even as a slider.",
                    reference: "NBC 9.9.10.1",
                    measured: true))
            } else if passesAsSlider {
                checks.append(Check(
                    title: "\(entry.name) — egress window",
                    status: .warning,
                    detail: "\(sizeText.capitalized) looks large enough, but its height was assumed (1.07 m default) and no unobstructed opening was recorded — measure the clear opening to confirm egress.",
                    reference: "NBC 9.9.10.1",
                    measured: true))
            } else if passesAsCasement {
                checks.append(Check(
                    title: "\(entry.name) — egress window",
                    status: .warning,
                    detail: "\(sizeText.capitalized) passes only if it opens fully (casement/awning). A slider of this size would not clear \(String(format: "%.2f", preset.egressOpenAreaM2)) m² — confirm the window style.",
                    reference: "NBC 9.9.10.1",
                    measured: true))
            } else {
                checks.append(Check(
                    title: "\(entry.name) — egress window",
                    status: .fail,
                    detail: anyClearRecorded
                        ? "The recorded clear opening is below the \(String(format: "%.2f", preset.egressOpenAreaM2)) m² / 380 mm egress minimum. Plan a larger egress window here."
                        : "No window on this room is large enough for egress (\(String(format: "%.2f", preset.egressOpenAreaM2)) m² opening, min 380 mm each way). Plan an egress window here.",
                    reference: "NBC 9.9.10.1",
                    measured: true))
            }

            if bestSill < Double.greatestFiniteMagnitude, bestSill > preset.maxSillMeters {
                checks.append(Check(
                    title: "\(entry.name) — window sill height",
                    status: .warning,
                    detail: "Egress sill sits \(Measure.length(bestSill, imperial: true)) above the floor — above the \(Measure.length(preset.maxSillMeters, imperial: true)) guidance. Built-in steps or furniture fixed below the window may be required.",
                    reference: "NBC 9.9.10.1 guidance",
                    measured: true))
            }

            let area = room.floorAreaSquareMeters
            if area > 1 {
                let ratio = glassArea / area
                checks.append(Check(
                    title: "\(entry.name) — natural light",
                    status: ratio >= preset.bedroomLightRatio ? .pass : .warning,
                    detail: String(format: "Window glass is %.1f%% of the floor area (%.0f%% required for bedrooms).",
                                   ratio * 100, preset.bedroomLightRatio * 100),
                    reference: "NBC 9.7.2.3",
                    measured: true))
            }
        }

        if namedBedrooms == 0, !rooms.isEmpty, (estimate?.bedrooms ?? 0) > 0 {
            checks.append(Check(
                title: "Bedroom identification",
                status: .unknown,
                detail: "The estimate plans \(estimate?.bedrooms ?? 0) bedroom(s), but no room is named \"Bedroom\". Rename rooms in the project's Rooms section to check egress and light automatically.",
                reference: "—",
                measured: true))
        }

        // MARK: Declared — planning checklist, estimate scope, fixtures

        func planned(_ title: String) -> Bool {
            planning?.items.first { $0.title == title }?.planned ?? false
        }
        let fixtures = rooms.flatMap(\.room.fixtures)
        let hasToilet = fixtures.contains { $0.kind == .toilet }
        let hasKitchenFixture = fixtures.contains { $0.kind == .stove || $0.kind == .baseCabinets }

        func declared(_ title: String, ok: Bool, okDetail: String, missingDetail: String,
                      reference: String, missingStatus: Status = .warning) {
            checks.append(Check(title: title,
                                status: ok ? .pass : missingStatus,
                                detail: ok ? okDetail : missingDetail,
                                reference: reference,
                                measured: false))
        }

        declared("Separate entrance",
                 ok: planned("Side-door entrance") || (estimate?.sideDoorEntrance ?? false),
                 okDetail: "A separate entrance is in the plan.",
                 missingDetail: "A secondary suite needs its own entrance — add the side-door entrance to the plan or confirm one exists.",
                 reference: "NBC 9.9.9 — egress from suites")

        declared("Fire separation",
                 ok: planned("Fire separation"),
                 okDetail: "Fire separation between the suite and the rest of the house is planned.",
                 missingDetail: "A fire separation (typically 30 min, or smoke-tight with sprinklers/interconnected alarms) is required between dwelling units — not yet in the plan.",
                 reference: "NBC 9.10.9")

        declared("Smoke & CO alarms",
                 ok: planned("Smoke & CO alarms (interconnected)"),
                 okDetail: "Interconnected smoke/CO alarms are planned.",
                 missingDetail: "Interconnected smoke alarms (suite + main dwelling) and CO alarms are required — not yet in the checklist.",
                 reference: "NBC 9.10.19 / 9.32.3.9")

        declared("Bathroom",
                 ok: planned("Bathroom") || (estimate?.bathrooms ?? 0) > 0 || hasToilet,
                 okDetail: "A bathroom is in the plan.",
                 missingDetail: "A self-contained suite needs its own bathroom — none found in the plan, estimate, or fixtures.",
                 reference: "MB secondary suite guidelines")

        declared("Kitchen",
                 ok: planned("Kitchen / kitchenette") || (estimate.map { $0.kitchen != .none } ?? false) || hasKitchenFixture,
                 okDetail: "A kitchen or kitchenette is in the plan.",
                 missingDetail: "A self-contained suite needs cooking facilities — none found in the plan, estimate, or fixtures.",
                 reference: "MB secondary suite guidelines")

        declared("Sound separation",
                 ok: planned("Sound separation"),
                 okDetail: "Sound separation is planned.",
                 missingDetail: "Sound separation between units is recommended (and required in some municipalities).",
                 reference: "NBC 9.11")

        return SuiteCompliance(preset: preset, checks: checks)
    }
}
