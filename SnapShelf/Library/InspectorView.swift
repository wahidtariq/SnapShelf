import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Library window's trailing inspector: a preview plus metadata for a single selection, or a
/// simple summary for a multi-selection. Recognized text is shown selectable so users can copy a
/// phrase straight out of a screenshot without opening it.
struct InspectorView: View {
    /// The currently selected screenshots, in the grid's display order.
    let screenshots: [Screenshot]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if screenshots.isEmpty {
                    ContentUnavailableView("No Selection", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if screenshots.count == 1 {
                    singleSelection(screenshots[0])
                } else {
                    multiSelection
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Single selection

    @ViewBuilder
    private func singleSelection(_ screenshot: Screenshot) -> some View {
        InspectorPreview(url: screenshot.fileURL)

        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Dimensions", value: "\(screenshot.pixelWidth) × \(screenshot.pixelHeight)")
            LabeledContent("Size", value: Self.byteCountFormatter.format(Int64(screenshot.byteSize)))
            LabeledContent("Created", value: screenshot.createdAt, format: .dateTime.month().day().year().hour().minute())
            LabeledContent("Type", value: Self.typeDescription(for: screenshot.contentType))
        }
        .font(.callout)

        Divider()

        recognizedTextSection(screenshot)
    }

    @ViewBuilder
    private func recognizedTextSection(_ screenshot: Screenshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recognized Text")
                .font(.callout.weight(.semibold))

            if !screenshot.isTextRecognized {
                Text("Recognizing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if screenshot.recognizedText.isEmpty {
                Text("No text found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(screenshot.recognizedText)
                    .font(.callout)
                    .textSelection(.enabled)

                Button("Copy Text") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(screenshot.recognizedText, forType: .string)
                }
            }
        }
    }

    // MARK: - Multi-selection

    private var multiSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(screenshots.count) Screenshots Selected")
                .font(.headline)
            let totalBytes = screenshots.reduce(0) { $0 + $1.byteSize }
            Text(Self.byteCountFormatter.format(Int64(totalBytes)) + " total")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Formatting

    private static let byteCountFormatter: ByteCountFormatStyle = .byteCount(style: .file)

    private static func typeDescription(for identifier: String) -> String {
        UTType(identifier)?.localizedDescription ?? identifier
    }
}

/// An aspect-fit preview of one screenshot, decoded via the shared `ThumbnailProvider` cache.
private struct InspectorPreview: View {
    let url: URL

    @Environment(ThumbnailProvider.self) private var thumbnailProvider
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            image = await thumbnailProvider.thumbnail(for: url, maxPixelSize: 800)
        }
    }
}
