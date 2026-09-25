import Foundation
import SwiftData

/// A single imported screenshot. Image bytes are never stored here — only metadata — because
/// SwiftData loads a model's full contents into memory whenever it's fetched, and screenshot
/// images would make the thumbnail grid slow. The actual file lives on disk under
/// `LibraryPaths.library`, addressed by `fileName`.
@Model
final class Screenshot {
    #Index<Screenshot>([\.createdAt])

    var id: UUID
    var createdAt: Date

    /// Relative path under `LibraryPaths.library`, e.g. `1F3.../Screenshot 2026-09-24 at 10.15.03.png`.
    var fileName: String
    /// The original file name (without the SnapShelf-owned uuid folder), e.g.
    /// "Screenshot 2026-09-24 at 10.15.03".
    var originalName: String
    /// UTType identifier, e.g. `public.png`.
    var contentType: String
    var pixelWidth: Int
    var pixelHeight: Int
    var byteSize: Int

    var isFavorite: Bool
    /// Non-nil once the shot has been soft-deleted (moved to Recently Deleted).
    var deletedAt: Date?

    /// Text found in the image by `TextRecognitionService`. Empty until recognition has run.
    var recognizedText: String
    /// Whether `TextRecognitionService` has already processed this shot — distinct from
    /// `recognizedText.isEmpty`, which is also true for a shot that was recognized but contained
    /// no text. Needs a default value so SwiftData's lightweight migration can add this column to
    /// an existing store without a custom migration plan.
    var isTextRecognized: Bool = false

    init(
        id: UUID = UUID(),
        createdAt: Date,
        fileName: String,
        originalName: String,
        contentType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteSize: Int,
        isFavorite: Bool = false,
        deletedAt: Date? = nil,
        recognizedText: String = "",
        isTextRecognized: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.fileName = fileName
        self.originalName = originalName
        self.contentType = contentType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteSize = byteSize
        self.isFavorite = isFavorite
        self.deletedAt = deletedAt
        self.recognizedText = recognizedText
        self.isTextRecognized = isTextRecognized
    }

    /// Full on-disk location of the imported file.
    var fileURL: URL {
        LibraryPaths.fileURL(forRelativePath: fileName)
    }
}
