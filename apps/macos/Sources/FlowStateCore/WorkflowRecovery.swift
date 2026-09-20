import Foundation

public enum WorkflowStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case uncertain
    case cancelled
}

public enum RecoveryAction: String, Codable, Equatable, Sendable {
    case resume
    case retry
    case reconcile
    case done
    case askUser
}

public struct WorkflowCheckpoint: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let operationID: String
    public var title: String
    public var status: WorkflowStatus
    public var step: String?
    public var reason: String?
    public var attempt: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        operationID: String,
        title: String,
        status: WorkflowStatus = .queued,
        step: String? = nil,
        reason: String? = nil,
        attempt: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.operationID = operationID
        self.title = title
        self.status = status
        self.step = step
        self.reason = reason
        self.attempt = attempt
        self.updatedAt = updatedAt
    }
}

public struct RetryBudget: Codable, Equatable, Sendable {
    public let maxAttempts: Int
    public private(set) var attempts: Int

    public init(maxAttempts: Int = 2, attempts: Int = 0) {
        self.maxAttempts = max(0, maxAttempts)
        self.attempts = max(0, attempts)
    }

    public mutating func consume() -> Bool {
        guard attempts < maxAttempts else { return false }
        attempts += 1
        return true
    }
}

public actor WorkflowRecoveryStore {
    private let defaults: UserDefaults
    private let key = "flowstate.workflow-recovery.v1"
    private var checkpoints: [String: WorkflowCheckpoint]

    public init(suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: WorkflowCheckpoint].self, from: data) {
            checkpoints = decoded
        } else {
            checkpoints = [:]
        }
    }

    public func begin(operationID: String, title: String) throws {
        checkpoints[operationID] = WorkflowCheckpoint(operationID: operationID, title: title, status: .running)
        try save()
    }

    public func checkpoint(
        operationID: String,
        step: String,
        status: WorkflowStatus = .running
    ) throws {
        guard var current = checkpoints[operationID] else { throw WorkflowRecoveryError.unknownOperation }
        current.step = step
        current.status = status
        current.attempt += 1
        current.updatedAt = Date()
        checkpoints[operationID] = current
        try save()
    }

    public func markUncertain(operationID: String, reason: String) throws {
        guard var current = checkpoints[operationID] else { throw WorkflowRecoveryError.unknownOperation }
        current.status = .uncertain
        current.reason = reason
        current.updatedAt = Date()
        checkpoints[operationID] = current
        try save()
    }

    public func finish(operationID: String, status: WorkflowStatus) throws {
        guard var current = checkpoints[operationID] else { throw WorkflowRecoveryError.unknownOperation }
        current.status = status
        current.updatedAt = Date()
        checkpoints[operationID] = current
        try save()
    }

    public func checkpoint(operationID: String) -> WorkflowCheckpoint? {
        checkpoints[operationID]
    }

    public func recoveryAction(operationID: String) -> RecoveryAction? {
        guard let checkpoint = checkpoints[operationID] else { return nil }
        return switch checkpoint.status {
        case .queued, .running: RecoveryAction.resume
        case .failed: RecoveryAction.retry
        case .uncertain: RecoveryAction.reconcile
        case .succeeded: RecoveryAction.done
        case .cancelled: RecoveryAction.askUser
        }
    }

    private func save() throws {
        guard let data = try? JSONEncoder().encode(checkpoints) else {
            throw WorkflowRecoveryError.persistenceFailed
        }
        defaults.set(data, forKey: key)
    }
}

public enum WorkflowRecoveryError: Error, Equatable, LocalizedError, Sendable {
    case unknownOperation
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .unknownOperation: "This workflow operation is not known on this Mac."
        case .persistenceFailed: "The workflow checkpoint could not be saved."
        }
    }
}
