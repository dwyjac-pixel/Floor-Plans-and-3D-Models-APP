import SwiftUI

/// Preview-before-send wrapper for generated files: shows the content and
/// the file's name and size, and only then offers the share sheet — so
/// nothing leaves the app unseen.
struct ExportPreviewSheet<Content: View>: View {
    let title: String
    let url: URL
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                fileFooter
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                    .accessibilityHint("Opens the system share sheet for this file")
                }
            }
        }
    }

    private var fileFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .accessibilityHidden(true)
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let bytes = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("File: \(url.lastPathComponent)")
    }
}
