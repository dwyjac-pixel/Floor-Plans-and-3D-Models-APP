import SwiftUI

/// App-wide preferences behind the Settings screen. Stored in UserDefaults
/// under stable keys with safe fallbacks, so a device that has never opened
/// Settings behaves exactly like the app did before Settings existed.
enum AppSettings {
    static let appearanceKey = "appAppearance"          // "system" | "light" | "dark"
    static let wall3DHexKey = "model3DWallHex"          // "" = built-in warm white
    static let labels3DKey = "model3DShowLabels"
    static let defaultCeilingKey = "defaultCeilingMeters"

    /// The forced colour scheme, or nil to follow the device.
    static func colorScheme(_ raw: String) -> ColorScheme? {
        switch raw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Measurement chips and dimension lines in the 3D model (default on).
    static var show3DLabels: Bool {
        UserDefaults.standard.object(forKey: labels3DKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: labels3DKey)
    }

    /// Seed for new corner-capture / traced / manual rooms. LiDAR scans
    /// always use the measured height instead.
    static var defaultCeilingMeters: Double {
        let value = UserDefaults.standard.double(forKey: defaultCeilingKey)
        return value >= 1.5 ? value : 2.4
    }

    /// The 3D model's unpainted-wall colour override; nil = built-in.
    static var wall3DUIColor: UIColor? {
        guard let hex = UserDefaults.standard.string(forKey: wall3DHexKey),
              !hex.isEmpty,
              let color = Color(hexString: hex) else { return nil }
        return UIColor(color)
    }
}
