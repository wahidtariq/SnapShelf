import Foundation
import Testing
@testable import SnapShelf

@Suite("ImportKind.classify")
struct ImportKindTests {
    @Test(
        "Recognized image extensions classify as .image",
        arguments: [
            "shot.png", "shot.PNG",
            "photo.jpg", "photo.JPG",
            "photo.jpeg", "photo.JPEG",
            "capture.heic", "capture.HEIC",
            "scan.tiff", "scan.TIFF",
            "document.pdf", "document.PDF"
        ]
    )
    func classifiesImages(named name: String) {
        #expect(ImportKind.classify(URL(fileURLWithPath: "/tmp/\(name)")) == .image)
    }

    @Test(
        "Recognized movie extensions classify as .movie",
        arguments: ["recording.mov", "recording.MOV", "clip.mp4", "clip.MP4"]
    )
    func classifiesMovies(named name: String) {
        #expect(ImportKind.classify(URL(fileURLWithPath: "/tmp/\(name)")) == .movie)
    }

    @Test(
        "Unsupported names classify as .ignore",
        arguments: ["notes.txt", "README", ".DS_Store"]
    )
    func classifiesUnsupportedAsIgnore(named name: String) {
        #expect(ImportKind.classify(URL(fileURLWithPath: "/tmp/\(name)")) == .ignore)
    }
}
