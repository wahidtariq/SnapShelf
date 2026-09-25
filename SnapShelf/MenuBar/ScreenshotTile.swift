import SwiftUI

/// A single tile in the popover grid: click to copy, hover for Copy/Favorite/Markup/Delete controls and
/// a relative time label, drag out for a real file. Not itself a `Button` — a real `Button`
/// wrapping content that contains other `Button`s (the hover controls) doesn't hit-test
/// correctly, so the tap-to-copy gesture uses `onTapGesture` instead.
struct ScreenshotTile: View {
    let screenshot: Screenshot
    let isSelected: Bool
    let onCopy: () -> Void
    let onToggleFavorite: () -> Void
    let onMarkup: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        // Built from a fixed-shape `Color.clear` base, not the thumbnail itself: a `.fill`
        // aspect ratio makes a view lay out *larger* than the proposed size (that's how it fills
        // without distortion), so clipping the thumbnail directly only trims that oversized
        // frame and the tile still overflows its grid cell. Clipping this inert base instead
        // guarantees the tile is never bigger than 16:10, whatever the source image's shape.
        Color.clear
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                ScreenshotThumbnail(url: screenshot.fileURL, contentMode: .fill)
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .overlay {
                if isHovering {
                    hoverOverlay
                }
            }
            .contentShape(.rect(cornerRadius: 8))
            .onTapGesture(perform: onCopy)
            .onHover { isHovering = $0 }
            .onDrag {
                NSItemProvider(object: screenshot.fileURL as NSURL)
            }
            .help(screenshot.originalName)
            .accessibilityLabel("\(screenshot.originalName), \(relativeTime)")
            .accessibilityAddTraits(.isButton)
    }

    private var relativeTime: String {
        Self.relativeFormatter.localizedString(for: screenshot.createdAt, relativeTo: .now)
    }

    private var hoverOverlay: some View {
        VStack {
            HStack(spacing: 4) {
                overlayButton(systemImage: "doc.on.doc", help: "Copy", action: onCopy)
                overlayButton(
                    systemImage: screenshot.isFavorite ? "star.fill" : "star",
                    help: screenshot.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    action: onToggleFavorite
                )
                overlayButton(systemImage: "pencil.tip.crop.circle", help: "Markup", action: onMarkup)
                overlayButton(systemImage: "trash", help: "Delete", action: onDelete)
                Spacer(minLength: 0)
            }
            .padding(6)
            .glassEffect(.regular, in: .capsule)
            .padding(6)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Text(relativeTime)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .glassEffect(.regular, in: .capsule)
            }
            .padding(6)
        }
    }

    private func overlayButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
