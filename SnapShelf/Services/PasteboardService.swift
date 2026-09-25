import AppKit
import UniformTypeIdentifiers

/// Writes screenshots to a pasteboard as PNG data, TIFF data, and a file URL in one pasteboard
/// item per image, so pasting works everywhere from Finder to Slack, Figma, and Messages. Writing
/// only an `NSImage` (or only TIFF) is not enough — several apps, including Slack and Figma,
/// don't accept TIFF-only pasteboard content.
struct PasteboardService {
    /// `libraryRoot` defaults to the real `LibraryPaths.library`; overridable so tests can point
    /// file resolution at a temporary folder instead.
    func copy(_ screenshots: [Screenshot], to pasteboard: NSPasteboard = .general, libraryRoot: URL = LibraryPaths.library) {
        pasteboard.clearContents()

        let items: [NSPasteboardItem] = screenshots.compactMap { screenshot in
            let fileURL = libraryRoot.appendingPathComponent(screenshot.fileName)
            guard let fileData = try? Data(contentsOf: fileURL) else { return nil }

            let isPNG = screenshot.contentType == UTType.png.identifier
            let image = NSImage(data: fileData)
            let tiffData = image?.tiffRepresentation

            let pngData: Data?
            if isPNG {
                pngData = fileData
            } else if let tiffData, let bitmap = NSBitmapImageRep(data: tiffData) {
                pngData = bitmap.representation(using: .png, properties: [:])
            } else {
                pngData = nil
            }

            guard pngData != nil || tiffData != nil else { return nil }

            let item = NSPasteboardItem()
            if let pngData {
                item.setData(pngData, forType: .png)
            }
            if let tiffData {
                item.setData(tiffData, forType: .tiff)
            }
            item.setString(fileURL.absoluteString, forType: .fileURL)
            return item
        }

        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
