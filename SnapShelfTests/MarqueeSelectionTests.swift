import Foundation
import Testing
@testable import SnapShelf

@Suite("MarqueeSelection")
struct MarqueeSelectionTests {
    // MARK: - Mode

    @Test
    func modeFromCommandModifierIsToggle() {
        #expect(MarqueeSelection.Mode(modifiers: [.command]) == .toggle)
    }

    @Test
    func modeFromShiftModifierIsExtend() {
        #expect(MarqueeSelection.Mode(modifiers: [.shift]) == .extend)
    }

    @Test
    func modeWithNoModifiersIsReplace() {
        #expect(MarqueeSelection.Mode(modifiers: []) == .replace)
    }

    @Test
    func commandWinsOverShiftWhenBothAreHeld() {
        #expect(MarqueeSelection.Mode(modifiers: [.command, .shift]) == .toggle)
    }

    // MARK: - rect

    @Test
    func rectNormalizesADragToTheLowerRight() {
        let rect = MarqueeSelection.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 60))
        #expect(rect == CGRect(x: 10, y: 10, width: 40, height: 50))
    }

    @Test
    func rectNormalizesADragToTheUpperLeft() {
        let rect = MarqueeSelection.rect(from: CGPoint(x: 50, y: 60), to: CGPoint(x: 10, y: 10))
        #expect(rect == CGRect(x: 10, y: 10, width: 40, height: 50))
    }

    @Test
    func rectNormalizesADragToTheUpperRight() {
        let rect = MarqueeSelection.rect(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 50, y: 10))
        #expect(rect == CGRect(x: 10, y: 10, width: 40, height: 50))
    }

    @Test
    func rectNormalizesADragToTheLowerLeft() {
        let rect = MarqueeSelection.rect(from: CGPoint(x: 50, y: 10), to: CGPoint(x: 10, y: 60))
        #expect(rect == CGRect(x: 10, y: 10, width: 40, height: 50))
    }

    // MARK: - hits

    @Test
    func hitsIncludeCellsThatIntersectTheRect() {
        let a = UUID()
        let b = UUID()
        let frames = [a: CGRect(x: 0, y: 0, width: 10, height: 10), b: CGRect(x: 100, y: 100, width: 10, height: 10)]
        let hits = MarqueeSelection.hits(in: CGRect(x: 0, y: 0, width: 20, height: 20), frames: frames, orderedIDs: [a, b])
        #expect(hits == [a])
    }

    @Test
    func hitsExcludeACellThatOnlyTouchesTheRectsEdge() {
        // `CGRect.intersects` treats a zero-area overlap as no intersection, so a frame that's
        // merely adjacent to the marquee — not overlapping it — isn't selected.
        let a = UUID()
        let frames = [a: CGRect(x: 10, y: 0, width: 10, height: 10)]
        let hits = MarqueeSelection.hits(in: CGRect(x: 0, y: 0, width: 10, height: 10), frames: frames, orderedIDs: [a])
        #expect(hits.isEmpty)
    }

    @Test
    func hitsIncludeACellWithOnlyAOnePointOverlap() {
        let a = UUID()
        let frames = [a: CGRect(x: 9, y: 0, width: 10, height: 10)]
        let hits = MarqueeSelection.hits(in: CGRect(x: 0, y: 0, width: 10, height: 10), frames: frames, orderedIDs: [a])
        #expect(hits == [a])
    }

    @Test
    func hitsAreReturnedInDisplayOrder() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let frames = [
            a: CGRect(x: 0, y: 0, width: 10, height: 10),
            b: CGRect(x: 20, y: 0, width: 10, height: 10),
            c: CGRect(x: 40, y: 0, width: 10, height: 10),
        ]
        // orderedIDs deliberately not in frame-insertion order.
        let hits = MarqueeSelection.hits(in: rect, frames: frames, orderedIDs: [c, a, b])
        #expect(hits == [c, a, b])
    }

    @Test
    func hitsSkipIDsMissingFromOrderedIDs() {
        let a = UUID()
        let stale = UUID()
        let frames = [a: CGRect(x: 0, y: 0, width: 10, height: 10), stale: CGRect(x: 0, y: 0, width: 10, height: 10)]
        // `stale` has a frame but is no longer in `orderedIDs` (e.g. deleted or filtered out).
        let hits = MarqueeSelection.hits(in: CGRect(x: 0, y: 0, width: 10, height: 10), frames: frames, orderedIDs: [a])
        #expect(hits == [a])
    }

    @Test
    func hitsSkipIDsWithNoRecordedFrame() {
        let a = UUID()
        let hits = MarqueeSelection.hits(in: CGRect(x: 0, y: 0, width: 10, height: 10), frames: [:], orderedIDs: [a])
        #expect(hits.isEmpty)
    }

    // MARK: - selection

    @Test
    func replaceModeIgnoresTheBaseSelection() {
        let base: Set<UUID> = [UUID()]
        let hit = UUID()
        #expect(MarqueeSelection.selection(base: base, hits: [hit], mode: .replace) == [hit])
    }

    @Test
    func extendModeUnionsWithTheBaseSelection() {
        let existing = UUID()
        let hit = UUID()
        let result = MarqueeSelection.selection(base: [existing], hits: [hit], mode: .extend)
        #expect(result == [existing, hit])
    }

    @Test
    func toggleModeFlipsMembershipOfHits() {
        let alreadySelected = UUID()
        let newlyHit = UUID()
        let result = MarqueeSelection.selection(base: [alreadySelected], hits: [alreadySelected, newlyHit], mode: .toggle)
        #expect(result == [newlyHit])
    }

    // MARK: - autoscrollDelta

    @Test
    func autoscrollDeltaIsZeroInTheDeadZone() {
        let delta = MarqueeSelection.autoscrollDelta(pointerY: 100, viewportHeight: 400, edge: 32, maxSpeed: 24)
        #expect(delta == 0)
    }

    @Test
    func autoscrollDeltaIsNegativeAtTheTopEdge() {
        let delta = MarqueeSelection.autoscrollDelta(pointerY: 0, viewportHeight: 400, edge: 32, maxSpeed: 24)
        #expect(delta < 0)
    }

    @Test
    func autoscrollDeltaIsPositiveAtTheBottomEdge() {
        let delta = MarqueeSelection.autoscrollDelta(pointerY: 400, viewportHeight: 400, edge: 32, maxSpeed: 24)
        #expect(delta > 0)
    }

    @Test
    func autoscrollDeltaIsCappedAtMaxSpeedPastTheEdge() {
        let justPastEdge = MarqueeSelection.autoscrollDelta(pointerY: 400, viewportHeight: 400, edge: 32, maxSpeed: 24)
        let wayPastEdge = MarqueeSelection.autoscrollDelta(pointerY: 4000, viewportHeight: 400, edge: 32, maxSpeed: 24)
        #expect(wayPastEdge == 24)
        #expect(justPastEdge <= 24)
    }

    @Test
    func autoscrollDeltaIsZeroForAZeroHeightViewport() {
        let delta = MarqueeSelection.autoscrollDelta(pointerY: 0, viewportHeight: 0, edge: 32, maxSpeed: 24)
        #expect(delta == 0)
    }
}
