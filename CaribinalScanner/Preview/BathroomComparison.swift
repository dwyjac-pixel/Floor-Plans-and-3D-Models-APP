#if canImport(UIKit)
import SwiftUI

struct BathroomFinishOption: Codable {
    let selection: PreviewFinish.Selection
    let light: PreviewBathroomLight
    let mirror: PreviewBathroomMirror
    let clearanceConfirmed: Bool
}

struct BathroomFinishOptions: Codable {
    var a: BathroomFinishOption?
    var b: BathroomFinishOption?

    static func load(for key: String) -> Self {
        guard let data = UserDefaults.standard.data(forKey: "bathroom-options.\(key)"),
              let options = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return options
    }

    func save(for key: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "bathroom-options.\(key)")
        }
    }
}

struct BathroomComparison: Identifiable {
    struct Picture: Identifiable {
        let title: String
        let image: UIImage
        let finishes: [String]
        var id: String { title }
    }

    let id = UUID()
    let pictures: [Picture]
    let assumptions: String?

    init?(layout: PreviewLayout, a: BathroomFinishOption, b: BathroomFinishOption) {
        let room = PreviewRoomScene(layout: layout)
        guard let doorway = room.stops.first(where: { $0.kind == .doorway }) else { return nil }
        var pictures: [Picture] = []
        for (title, option) in [("Option A", a), ("Option B", b)] {
            room.apply(option.selection)
            room.setBathroomLighting(option.light, mirror: option.mirror,
                                     clearanceConfirmed: option.clearanceConfirmed)
            guard let image = PreviewStill.render(room, from: doorway, width: 1440) else { return nil }
            var finishes = PreviewFinish.Slot.choices.compactMap { slot -> String? in
                guard let id = room.shownFinishes[slot], let finish = PreviewFinish.finish(id) else { return nil }
                return "\(slot.title): \(finish.name)"
            }
            finishes.append("Light fixture: \(room.lightStyle.rawValue)")
            if room.vanityMount != nil { finishes.append("Mirror: \(room.mirrorStyle.rawValue)") }
            pictures.append(Picture(title: title, image: UIImage(cgImage: image), finishes: finishes))
        }
        self.pictures = pictures
        assumptions = PreviewCaption.assumptionText(layout.assumptions)
    }
}

struct BathroomComparisonSheet: View {
    let comparison: BathroomComparison
    let source: FinishedPreviewSource
    let useImperial: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pdf: Report?
    @State private var exportFailed = false

    private struct Report: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(comparison.pictures) { picture in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(picture.title).font(.headline)
                            Image(uiImage: picture.image).resizable().scaledToFit()
                                .accessibilityLabel("\(picture.title) from the doorway")
                            ForEach(picture.finishes, id: \.self) { Text($0).font(.caption) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                if let assumptions = comparison.assumptions {
                    Text(assumptions).font(.footnote).padding(.horizontal)
                }
            }
            .navigationTitle("Bathroom Comparison")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Export PDF") {
                        do {
                            pdf = Report(url: try PDFExporter.makeBathroomComparison(comparison, source: source,
                                                                                     useImperial: useImperial))
                        } catch {
                            exportFailed = true
                        }
                    }
                }
            }
            .sheet(item: $pdf) { PDFPreviewSheet(url: $0.url) }
            .alert("Could Not Export the PDF", isPresented: $exportFailed) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}
#endif
