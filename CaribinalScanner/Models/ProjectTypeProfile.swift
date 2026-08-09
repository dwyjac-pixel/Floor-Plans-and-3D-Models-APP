import Foundation

/// What a project's type MEANS for the app: which dashboard card leads,
/// whether suite-code compliance applies, how the Deal Analyzer should be
/// seeded, and what lens the AI advisor takes. The type picker stops being
/// a label and starts steering the experience — by adaptation, never
/// lockout: every feature stays reachable for every type.
struct ProjectTypeProfile {
    /// Which dashboard card carries the job's centre of gravity.
    enum Emphasis {
        case plan          // site/exterior work: the drawings lead
        case quote         // renovation work: pricing leads
        case compliance    // suite conversions: code and permit lead
        case investment    // flips/rentals: the deal leads
    }

    let emphasis: Emphasis
    /// Show the NBC suite-compliance check (egress, ceiling heights). Only
    /// meaningful when the job creates or legalizes a dwelling unit.
    let isSuiteProject: Bool
    /// Strategy to preselect in the Deal Analyzer when no deal is saved yet.
    let defaultDealStrategy: DealInputs.Strategy?
    /// One extra line of framing for the AI quote advisor's context.
    let aiGuidance: String

    static func profile(for projectType: String) -> ProjectTypeProfile {
        switch projectType {
        case "Property Flip":
            ProjectTypeProfile(
                emphasis: .investment, isSuiteProject: false, defaultDealStrategy: .flip,
                aiGuidance: "This is a flip: weigh every line against resale value, flag over-renovation for the neighbourhood, and favour cheap high-impact wins.")
        case "Basement Development":
            ProjectTypeProfile(
                emphasis: .compliance, isSuiteProject: true, defaultDealStrategy: .rental,
                aiGuidance: "This is a basement development: watch ceiling heights, egress windows, moisture, and mechanical-room clearances before finishes.")
        case "Legal Secondary Suite":
            ProjectTypeProfile(
                emphasis: .compliance, isSuiteProject: true, defaultDealStrategy: .rental,
                aiGuidance: "This is a suite legalization: code compliance drives the scope — egress, ceiling height, separation, and permits come before cosmetic work.")
        case "Multi Family":
            ProjectTypeProfile(
                emphasis: .investment, isSuiteProject: true, defaultDealStrategy: .rental,
                aiGuidance: "This is a multi-family project: think per-unit rents and costs, and flag work that triggers code upgrades across units.")
        case "Exterior":
            ProjectTypeProfile(
                emphasis: .plan, isSuiteProject: false, defaultDealStrategy: nil,
                aiGuidance: "This is exterior work: focus on roofing, siding, grading, drainage, and curb appeal; interior line items are likely out of scope.")
        case "Renovation", "Whole House":
            ProjectTypeProfile(
                emphasis: .quote, isSuiteProject: false, defaultDealStrategy: nil,
                aiGuidance: "This is a renovation: keep the scope disciplined against the budget and flag scope creep between the plan and the quote.")
        default:
            ProjectTypeProfile(
                emphasis: .quote, isSuiteProject: false, defaultDealStrategy: nil,
                aiGuidance: "")
        }
    }
}
