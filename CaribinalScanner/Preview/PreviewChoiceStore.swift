#if canImport(UIKit)
import Foundation

/// Preview choices kept with the project: one small file in the project's
/// own folder, beside its plan history. It syncs through iCloud and
/// travels in a backup with the rest of the project, goes when the
/// project is deleted, and belongs to that project alone, so an imported
/// copy never shares choices with the original. Version 1.0.2 never opens
/// a file by this name, so an older device cannot damage it.
///
/// The samples have no project. Their choices last until the app closes.
struct PreviewChoiceStore {
    static let fileName = "preview_choices.json"
    static let sample = PreviewChoiceStore(url: nil)
    private static var visitOnly: [String: Any] = [:]

    private let url: URL?

    private init(url: URL?) { self.url = url }

    init(project: RenovationProject) {
        url = (try? ScanStore.folder(for: project))?.appendingPathComponent(Self.fileName)
    }

    private func read() -> [String: Any] {
        guard let url else { return Self.visitOnly }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// The saved value for a key, or nil when there is none or it cannot
    /// be read. One unreadable entry never affects the others.
    func value<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let object = read()[key], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func set<T: Encodable>(_ value: T, for key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return }
        var all = read()
        all[key] = object
        guard let url else {
            Self.visitOnly = all
            return
        }
        guard let file = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return }
        try? ScanStore.coordinatedWrite(file, to: url)
    }
}
#endif
