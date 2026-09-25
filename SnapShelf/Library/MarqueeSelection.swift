import AppKit
import Foundation

/// Pure geometry and set arithmetic behind the Library grid's Finder-style drag-to-select,
/// kept separate from `ScreenshotGrid` so it's trivially unit-testable without a live view.
///
/// `nonisolated` — none of this touches state that needs the project's default main-actor
/// isolation, and tests call it synchronously.
enum MarqueeSelection {
    /// How a completed drag combines with the selection that existed before it started.
    nonisolated enum Mode: Equatable {
        case replace
        case extend
        case toggle

        /// ⌘ wins over ⇧ when both are held, matching Finder's own modifier precedence.
        init(modifiers: NSEvent.ModifierFlags) {
            if modifiers.contains(.command) {
                self = .toggle
            } else if modifiers.contains(.shift) {
                self = .extend
            } else {
                self = .replace
            }
        }
    }

    /// The normalised rectangle spanning two drag points, regardless of which direction the
    /// drag ran in.
    nonisolated static func rect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        )
    }

    /// IDs whose frame intersects `rect`, in `orderedIDs`' display order. `frames` may hold
    /// stale entries for IDs no longer in `orderedIDs` (e.g. deleted or filtered-out items);
    /// those are ignored rather than selected.
    nonisolated static func hits(in rect: CGRect, frames: [UUID: CGRect], orderedIDs: [UUID]) -> [UUID] {
        orderedIDs.filter { id in
            guard let frame = frames[id] else { return false }
            return rect.intersects(frame)
        }
    }

    /// Combines the selection that existed before the drag started with this drag's hits,
    /// per `mode`.
    nonisolated static func selection(base: Set<UUID>, hits: Set<UUID>, mode: Mode) -> Set<UUID> {
        switch mode {
        case .replace: return hits
        case .extend: return base.union(hits)
        case .toggle: return base.symmetricDifference(hits)
        }
    }

    /// How far to autoscroll per tick, given the drag pointer's Y in viewport space. Negative
    /// scrolls up, positive scrolls down, zero inside the dead zone between the edge bands.
    /// Magnitude scales linearly with how far past the edge the pointer is, capped at `maxSpeed`.
    nonisolated static func autoscrollDelta(
        pointerY: CGFloat,
        viewportHeight: CGFloat,
        edge: CGFloat = 32,
        maxSpeed: CGFloat = 24
    ) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        if pointerY < edge {
            let penetration = edge - pointerY
            return -min(penetration, edge) / edge * maxSpeed
        }
        let bottomEdgeStart = viewportHeight - edge
        if pointerY > bottomEdgeStart {
            let penetration = pointerY - bottomEdgeStart
            return min(penetration, edge) / edge * maxSpeed
        }
        return 0
    }
}
