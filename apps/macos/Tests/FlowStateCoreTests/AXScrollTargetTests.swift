import CoreGraphics
import Testing
@testable import FlowStateCore

@Test("AX scrolling chooses the nearest offscreen content in the requested direction")
func axScrollingChoosesDirectionalTarget() {
    let viewport = CGRect(x: 0, y: 100, width: 800, height: 400)
    let candidates = [
        CGRect(x: 0, y: 80, width: 100, height: 20),
        CGRect(x: 0, y: 160, width: 100, height: 20),
        CGRect(x: 0, y: 520, width: 100, height: 20),
        CGRect(x: 0, y: 700, width: 100, height: 20),
    ]

    #expect(axScrollTargetIndex(candidates: candidates, viewport: viewport, lines: 3) == 0)
    #expect(axScrollTargetIndex(candidates: candidates, viewport: viewport, lines: -3) == 2)
    #expect(axScrollTargetIndex(candidates: [candidates[1]], viewport: viewport, lines: 3) == nil)
    #expect(axScrollTargetIndex(candidates: [candidates[1]], viewport: viewport, lines: -3) == nil)
    #expect(axScrollTargetIndex(candidates: candidates, viewport: viewport, lines: 0) == nil)
}

@Test("Brave clipped offscreen nodes remain directional scroll targets")
func axScrollingIncludesClippedTargets() {
    let viewport = CGRect(x: 0, y: 100, width: 800, height: 400)
    let candidates = [
        CGRect(x: 0, y: 100, width: 100, height: 1),
        CGRect(x: 0, y: 100, width: 100, height: 1),
        CGRect(x: 0, y: 160, width: 100, height: 20),
        CGRect(x: 0, y: 500, width: 100, height: 0),
        CGRect(x: 0, y: 500, width: 100, height: 0),
    ]
    #expect(axScrollTargetIndex(candidates: candidates, viewport: viewport, lines: 3) == 1)
    #expect(axScrollTargetIndex(candidates: candidates, viewport: viewport, lines: -3) == 3)
}
