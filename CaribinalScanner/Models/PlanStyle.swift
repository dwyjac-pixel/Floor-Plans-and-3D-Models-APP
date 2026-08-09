import SwiftUI
import UIKit

/// User-customisable floor plan drawing style: wall line thickness and
/// colours for walls, doors, and windows. Applies on screen and in every
/// export (PDF, PNG).
struct PlanStyle: Codable, Equatable {
    var wallWidth: Double = 5
    var wallHex: String = "default"   // "default" adapts to light/dark mode
    var doorHex: String = "#FF9500"
    var windowHex: String = "#30B0C7"
    var backgroundHex: String = "default"
    var doubleLineWalls: Bool = true  // drafting-style hollow walls

    static let storageKey = "planStyle"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case wallWidth, wallHex, doorHex, windowHex, backgroundHex, doubleLineWalls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wallWidth = try container.decodeIfPresent(Double.self, forKey: .wallWidth) ?? 5
        wallHex = try container.decodeIfPresent(String.self, forKey: .wallHex) ?? "default"
        doorHex = try container.decodeIfPresent(String.self, forKey: .doorHex) ?? "#FF9500"
        windowHex = try container.decodeIfPresent(String.self, forKey: .windowHex) ?? "#30B0C7"
        backgroundHex = try container.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "default"
        doubleLineWalls = try container.decodeIfPresent(Bool.self, forKey: .doubleLineWalls) ?? true
    }

    static func load() -> PlanStyle {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let style = try? JSONDecoder().decode(PlanStyle.self, from: data) else {
            return PlanStyle()
        }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    var wallColor: Color {
        wallHex == "default" ? .primary : (Color(hexString: wallHex) ?? .primary)
    }

    var doorColor: Color { Color(hexString: doorHex) ?? .orange }
    var windowColor: Color { Color(hexString: windowHex) ?? .teal }

    /// Drafting-paper background: warm off-white in light mode, deep
    /// blue-slate in dark mode, or a custom colour.
    var backgroundColor: Color {
        if backgroundHex != "default", let custom = Color(hexString: backgroundHex) {
            return custom
        }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.11, green: 0.13, blue: 0.17, alpha: 1)
                : UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1)
        })
    }
}

/// Which drawing layers are visible — the mobile take on CAD layers.
/// Applies on screen and in every export (PNG, PDF).
struct PlanLayers: Codable, Equatable {
    var dimensions = true
    var openings = true
    var interiorWalls = true
    var fixtures = true
    var markers = true
    var rightAngles = true

    static let storageKey = "planLayers"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case dimensions, openings, interiorWalls, fixtures, markers, rightAngles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dimensions = try container.decodeIfPresent(Bool.self, forKey: .dimensions) ?? true
        openings = try container.decodeIfPresent(Bool.self, forKey: .openings) ?? true
        interiorWalls = try container.decodeIfPresent(Bool.self, forKey: .interiorWalls) ?? true
        fixtures = try container.decodeIfPresent(Bool.self, forKey: .fixtures) ?? true
        markers = try container.decodeIfPresent(Bool.self, forKey: .markers) ?? true
        rightAngles = try container.decodeIfPresent(Bool.self, forKey: .rightAngles) ?? true
    }

    static func load() -> PlanLayers {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let layers = try? JSONDecoder().decode(PlanLayers.self, from: data) else {
            return PlanLayers()
        }
        return layers
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

extension UIColor {
    convenience init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt64(value, radix: 16) else { return nil }
        self.init(red: CGFloat((int >> 16) & 0xFF) / 255,
                  green: CGFloat((int >> 8) & 0xFF) / 255,
                  blue: CGFloat(int & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt64(value, radix: 16) else { return nil }
        self.init(red: Double((int >> 16) & 0xFF) / 255,
                  green: Double((int >> 8) & 0xFF) / 255,
                  blue: Double(int & 0xFF) / 255)
    }

    func hexString() -> String {
        let color = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X",
                      Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
    }
}
