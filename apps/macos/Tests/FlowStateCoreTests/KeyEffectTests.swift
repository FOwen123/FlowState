import Foundation
import Testing
@testable import FlowStateCore

private func keyObservation(field: String = "one", value: String = "hello", location: Int = 0, length: Int = 0) -> DesktopObservation {
    DesktopObservation(bundleIdentifier: "com.example.Editor", focusedElementID: field, value: value,
        selectedTextRange: DesktopTextRange(location: location, length: length))
}
@Test("keyboard delivery alone is not a verified effect")
func keyDeliveryNeedsEffect() {
    let before = keyObservation()
    #expect(!keyboardEffectObserved(key: "Tab", modifiers: nil, before: before, after: before, clipboardChanged: false))
    #expect(!keyboardEffectObserved(key: "Escape", modifiers: nil, before: before, after: before, clipboardChanged: false))
    #expect(keyboardEffectObserved(key: "Tab", modifiers: nil, before: before, after: keyObservation(field: "two"), clipboardChanged: false))
    #expect(keyboardEffectObserved(key: "ArrowRight", modifiers: nil, before: before, after: keyObservation(location: 1), clipboardChanged: false))
    #expect(keyboardEffectObserved(key: "A", modifiers: "Command", before: before, after: keyObservation(length: 5), clipboardChanged: false))
    #expect(!keyboardEffectObserved(key: "A", modifiers: "Command", before: before, after: keyObservation(length: 2), clipboardChanged: false))
    #expect(keyboardEffectObserved(key: "C", modifiers: "Command", before: before, after: before, clipboardChanged: true))
}
