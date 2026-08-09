import SwiftUI
import SwiftData
import PhotosUI
import ImageIO

/// Small in-memory cache of decoded thumbnails, keyed by file path, so the
/// grid doesn't re-decode full-resolution images on the main thread for its
/// 84 pt cells (QA-026).
enum PhotoThumbnailCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func cached(for path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    static func store(_ image: UIImage, for path: String) {
        cache.setObject(image, forKey: path as NSString)
    }

    /// Decode only a downsampled thumbnail (never the full-resolution image)
    /// straight from the file, sized for the grid cell.
    static func makeThumbnail(from url: URL, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

struct PhotoSection: View {
    @Bindable var project: RenovationProject

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var captions: [String: String] = [:]
    @State private var selectedPhoto: SelectedPhoto?

    struct SelectedPhoto: Identifiable {
        let name: String
        var id: String { name }
    }

    var body: some View {
        // Renders inside the dashboard's "Photos & Notes" card, so this is a
        // plain stack (not a Form Section) — the card supplies the heading.
        VStack(alignment: .leading, spacing: 8) {
            if !project.photoFileNames.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(Array(project.photoFileNames.enumerated()), id: \.element) { index, name in
                        Button {
                            selectedPhoto = SelectedPhoto(name: name)
                        } label: {
                            PhotoThumbnail(name: name, project: project)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(photoLabel(index: index, name: name))
                        .accessibilityHint("Double tap to add or edit a caption")
                        .contextMenu {
                            Button("Delete Photo", role: .destructive) {
                                delete(name)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                Label("Add Photos", systemImage: "photo.badge.plus")
            }
            .accessibilityLabel("Add Photos")
            .accessibilityHint("Choose up to 10 photos from your library")
            Text("Tap a photo to add a caption — captions print under photos in the PDF report.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            captions = ScanStore.loadPhotoCaptions(for: project)
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let name = try? ScanStore.addPhoto(data, to: project) {
                        project.photoFileNames.append(name)
                    }
                }
                pickerItems = []
            }
        }
        .sheet(item: $selectedPhoto) { selected in
            PhotoCaptionSheet(project: project,
                              name: selected.name,
                              caption: captions[selected.name] ?? "") { newCaption in
                captions[selected.name] = newCaption.isEmpty ? nil : newCaption
                try? ScanStore.savePhotoCaptions(captions, for: project)
            }
        }
    }

    private func photoLabel(index: Int, name: String) -> String {
        let base = "Photo \(index + 1) of \(project.photoFileNames.count)"
        if let caption = captions[name], !caption.isEmpty {
            return "\(base), \(caption)"
        }
        return base
    }

    private func delete(_ name: String) {
        ScanStore.deletePhoto(named: name, in: project)
        project.photoFileNames.removeAll { $0 == name }
        captions[name] = nil
        try? ScanStore.savePhotoCaptions(captions, for: project)
    }
}

struct PhotoThumbnail: View {
    let name: String
    let project: RenovationProject

    @State private var thumbnail: UIImage?

    // 84 pt cell at up to 3× — a 256 px thumbnail covers it without ever
    // decoding the full-resolution photo (QA-026).
    private static let maxPixelSize = 256

    var body: some View {
        Group {
            if let thumbnail {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .task(id: name) { await loadThumbnail() }
    }

    @MainActor
    private func loadThumbnail() async {
        guard let url = ScanStore.photoURL(named: name, in: project) else {
            thumbnail = nil
            return
        }
        if let cached = PhotoThumbnailCache.cached(for: url.path) {
            thumbnail = cached
            return
        }
        let maxPixelSize = Self.maxPixelSize
        let image = await Task.detached(priority: .userInitiated) {
            PhotoThumbnailCache.makeThumbnail(from: url, maxPixelSize: maxPixelSize)
        }.value
        if let image {
            PhotoThumbnailCache.store(image, for: url.path)
        }
        thumbnail = image
    }
}

struct PhotoCaptionSheet: View {
    let project: RenovationProject
    let name: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var caption: String
    @State private var preview: UIImage?

    // The detail preview tops out around 420 pt tall; a 1400 px decode is
    // ample and avoids loading the full-resolution photo on the main thread
    // (QA-026).
    private static let maxPixelSize = 1400

    init(project: RenovationProject, name: String, caption: String, onSave: @escaping (String) -> Void) {
        self.project = project
        self.name = name
        self.onSave = onSave
        _caption = State(initialValue: caption)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Photo preview")
                }
                TextField("Caption (prints under the photo in the report)", text: $caption, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding()
            .task { await loadPreview() }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(caption.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }

    @MainActor
    private func loadPreview() async {
        guard let url = ScanStore.photoURL(named: name, in: project) else { return }
        let maxPixelSize = Self.maxPixelSize
        preview = await Task.detached(priority: .userInitiated) {
            PhotoThumbnailCache.makeThumbnail(from: url, maxPixelSize: maxPixelSize)
        }.value
    }
}
