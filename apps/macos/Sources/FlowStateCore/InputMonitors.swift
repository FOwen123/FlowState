@preconcurrency import AppKit
import Carbon.HIToolbox
import Foundation

/// Observes a small set of user input events while desktop automation is
/// active. Events tagged by Flow State's own injected-event source are ignored.
@MainActor
public final class InputTakeoverMonitor {
    nonisolated public static let automationEventTag: UInt64 = 0x464C4F5753544154

    private var globalToken: Any?
    private var localToken: Any?
    private var callback: (() -> Void)?
    private var generation: UInt64 = 0

    public init() {}

    public func start(shortcut: VoiceShortcut = .controlShiftSpace, onTakeover: @escaping () -> Void) {
        stop()
        callback = onTakeover
        let token = generation
        let mask: NSEvent.EventTypeMask = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel
        ]
        globalToken = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard !Self.isAutomationEvent(event), !GlobalVoiceShortcutMonitor.matches(event, shortcut: shortcut) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.callback?()
            }
        }
        localToken = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            // A local monitor only receives events dispatched by Flow State's
            // own windows. Interacting with the settings/menu UI must not pause
            // automation running in the explicitly approved target app.
            guard !Self.isFlowStateOwnedLocalEvent(event),
                  !Self.isAutomationEvent(event),
                  !GlobalVoiceShortcutMonitor.matches(event, shortcut: shortcut) else { return event }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.callback?()
            }
            return event
        }
    }

    public func stop() {
        generation &+= 1
        if let globalToken { NSEvent.removeMonitor(globalToken) }
        if let localToken { NSEvent.removeMonitor(localToken) }
        globalToken = nil
        localToken = nil
        callback = nil
    }

    nonisolated public static func isAutomationEvent(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Int64(bitPattern: automationEventTag)
    }

    /// Local event monitors are scoped to the current application, so their
    /// events belong to Flow State's own UI and are never a target-app
    /// takeover. Global monitoring remains responsible for physical input in
    /// other applications.
    nonisolated public static func isFlowStateOwnedLocalEvent(_ event: NSEvent) -> Bool {
        true
    }

    isolated deinit { stop() }
}

/// Monotonic tokens used by the app model to reject callbacks from an older
/// input grant after cancellation, replacement, or physical takeover.
public struct InputEpochGate: Sendable, Equatable {
    public private(set) var current: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func advance() -> UInt64 {
        current &+= 1
        return current
    }

    public func isCurrent(_ token: UInt64) -> Bool {
        token == current
    }
}

public struct VoiceShortcutRegistrationError: Error, Equatable, LocalizedError, Sendable {
    public let shortcut: VoiceShortcut
    public let status: Int32

    public init(shortcut: VoiceShortcut, status: Int32) {
        self.shortcut = shortcut
        self.status = status
    }

    public var errorDescription: String? {
        "Could not register \(shortcut.displayName) (Carbon status \(status)). Choose another shortcut."
    }
}

@MainActor
public final class GlobalVoiceShortcutMonitor {
    private var keyDown: (() -> Void)?
    private var keyUp: (() -> Void)?
    private var pressState = ShortcutPressState()
    private var shortcut = VoiceShortcut.controlShiftSpace
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registrationID: UInt32 = 0

    private static let carbonSignature: OSType = 0x46535448 // FSTH
    private static let carbonHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        let monitor = Unmanaged<GlobalVoiceShortcutMonitor>
            .fromOpaque(userData)
            .takeUnretainedValue()
        var identifier = EventHotKeyID(signature: 0, id: 0)
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr, identifier.signature == carbonSignature else { return noErr }
        let kind = GetEventKind(event)
        let id = identifier.id
        Task { @MainActor [weak monitor] in
            guard let monitor, monitor.isRegistered, monitor.registrationID == id else { return }
            monitor.handleCarbonEvent(kind)
        }
        return noErr
    }

    public init() {}

    public private(set) var registrationError: VoiceShortcutRegistrationError?

    public var isRegistered: Bool { hotKeyRef != nil && handlerRef != nil }

    /// Reconnects a monitor that could not be installed earlier, without
    /// resetting an active shortcut press.
    @discardableResult
    public func startIfNeeded(
        shortcut: VoiceShortcut = .controlShiftSpace,
        onKeyDown: @escaping () -> Void,
        onKeyUp: @escaping () -> Void
    ) -> Bool {
        guard hotKeyRef == nil, handlerRef == nil, !pressState.isActive else { return isRegistered }
        return start(shortcut: shortcut, onKeyDown: onKeyDown, onKeyUp: onKeyUp)
    }

    public var isPressActive: Bool { pressState.isActive }

    @discardableResult
    public func start(
        shortcut: VoiceShortcut = .controlShiftSpace,
        onKeyDown: @escaping () -> Void,
        onKeyUp: @escaping () -> Void
    ) -> Bool {
        stop()
        self.shortcut = shortcut
        keyDown = onKeyDown
        keyUp = onKeyUp
        registrationID &+= 1
        let identifier = EventHotKeyID(signature: Self.carbonSignature, id: registrationID)
        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            Self.carbonModifiers(for: shortcut),
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &registeredHotKey
        )
        guard registrationStatus == noErr, let registeredHotKey else {
            registrationError = VoiceShortcutRegistrationError(shortcut: shortcut, status: registrationStatus)
            return false
        }

        let specifications = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        var installedHandler: EventHandlerRef?
        let handlerStatus = specifications.withUnsafeBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                Self.carbonHandler,
                buffer.count,
                buffer.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &installedHandler
            )
        }
        guard handlerStatus == noErr, let installedHandler else {
            _ = UnregisterEventHotKey(registeredHotKey)
            registrationError = VoiceShortcutRegistrationError(shortcut: shortcut, status: handlerStatus)
            return false
        }
        hotKeyRef = registeredHotKey
        handlerRef = installedHandler
        registrationError = nil
        return true
    }

    public func stop() {
        if let handlerRef { _ = RemoveEventHandler(handlerRef) }
        if let hotKeyRef { _ = UnregisterEventHotKey(hotKeyRef) }
        handlerRef = nil
        hotKeyRef = nil
        keyDown = nil
        keyUp = nil
        pressState = ShortcutPressState()
        registrationError = nil
    }

    nonisolated public static func carbonModifiers(for shortcut: VoiceShortcut) -> UInt32 {
        switch shortcut {
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .controlShiftSpace: UInt32(controlKey | shiftKey)
        case .optionSpace: UInt32(optionKey)
        }
    }

    nonisolated public static func matchesOptionSpace(_ event: NSEvent) -> Bool {
        matches(event, shortcut: .optionSpace)
    }

    nonisolated public static func matches(_ event: NSEvent, shortcut: VoiceShortcut) -> Bool {
        guard event.keyCode == 49 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let required: NSEvent.ModifierFlags
        switch shortcut {
        case .controlOptionSpace: required = [.control, .option]
        case .controlShiftSpace: required = [.control, .shift]
        case .optionSpace: required = [.option]
        }
        guard flags.intersection([.option, .control, .shift]) == required else { return false }
        return !flags.contains(.command)
    }

    private func handleCarbonEvent(_ kind: UInt32) {
        let pressed: Bool?
        switch kind {
        case UInt32(kEventHotKeyPressed): pressed = pressState.press()
        case UInt32(kEventHotKeyReleased): pressed = pressState.release()
        default: pressed = nil
        }
        guard let pressed else { return }
        if pressed { keyDown?() } else { keyUp?() }
    }

    isolated deinit { stop() }
}

struct ShortcutPressState {
    private var isDown = false

    var isActive: Bool { isDown }

    mutating func press() -> Bool? {
        guard !isDown else { return nil }
        isDown = true
        return true
    }

    mutating func release() -> Bool? {
        guard isDown else { return nil }
        isDown = false
        return false
    }

    mutating func consume(_ event: NSEvent, shortcut: VoiceShortcut = .optionSpace) -> Bool? {
        if event.type == .keyDown, GlobalVoiceShortcutMonitor.matches(event, shortcut: shortcut) {
            return press()
        }
        // Modifier keys can be released before Space; still finish this press.
        if event.type == .keyUp, event.keyCode == 49, isDown {
            return release()
        }
        return nil
    }
}
