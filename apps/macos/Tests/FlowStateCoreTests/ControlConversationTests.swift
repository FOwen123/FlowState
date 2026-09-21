import Foundation
import Testing
@testable import FlowStateCore

@Test("a first hold creates a task before returning its token")
@MainActor func firstHoldCreatesConversationTask() {
    let session = ControlConversationSession()
    let expiry = Date().addingTimeInterval(60)

    let token = session.beginHoldIfCurrent(
        targetBundleIdentifier: "com.example.Editor",
        grantExpiresAt: expiry
    )

    #expect(token != nil)
    #expect(session.taskID == token?.taskID)
    #expect(session.targetBundleIdentifier == "com.example.Editor")
    #expect(session.grantExpiresAt == expiry)
}

@Test("control conversation keeps one task ID across hold activations")
@MainActor func conversationTaskIDIsStableAcrossHolds() {
    let session = ControlConversationSession(maxTurns: 4)
    let first = session.beginTask(request: "Open Brave")
    let second = session.beginHold()

    #expect(first.taskID == second.taskID)
    #expect(first.generation != second.generation)
    #expect(session.originalRequest == "Open Brave")
}

@Test("conversation bounds turns and exposes pending clarification and verified result")
@MainActor func conversationStateIsBounded() {
    let session = ControlConversationSession(maxTurns: 2)
    _ = session.beginTask(request: "Open Brave")
    session.appendTurn(role: .user, text: "Open Brave")
    session.appendTurn(role: .assistant, text: "Which Brave window?")
    session.appendTurn(role: .user, text: "The project window")
    session.setPendingClarification("Which Brave window?")
    session.recordVerifiedResult("Brave is open")

    #expect(session.turns.count == 2)
    #expect(session.pendingClarification == "Which Brave window?")
    #expect(session.latestVerifiedResult == "Brave is open")
    #expect(session.recentInteraction?.contains("control update") == true)
}

@Test("clear, expiry, and new task reject stale replies and approvals")
@MainActor func conversationRejectsStaleTokens() {
    let session = ControlConversationSession()
    let old = session.beginTask(request: "Open Brave")
    session.requireApproval()
    #expect(session.accepts(old))

    session.clear()
    #expect(!session.accepts(old))
    #expect(session.taskID == nil)
    #expect(session.approvalGeneration == nil)

    let next = session.beginTask(request: "Open Safari")
    #expect(next.taskID != old.taskID)
    session.expire()
    #expect(!session.accepts(next))
}

@Test("conversation redacts sensitive values before recent interaction")
@MainActor func conversationRedactsSensitiveInteraction() {
    let session = ControlConversationSession()
    _ = session.beginTask(request: "Use password=secret-value")
    session.appendTurn(role: .user, text: "My one-time code is 123456")

    let recent = session.recentInteraction ?? ""
    #expect(!recent.contains("secret-value"))
    #expect(!recent.contains("123456"))
    #expect(recent.contains("control update"))
}

@Test("recent interaction keeps message content and private URLs out of cloud context")
@MainActor func conversationRedactsStructuredPrivateContent() {
    let session = ControlConversationSession()
    _ = session.beginTask(request: "Draft to owner@example.com with body: \"quarterly results are private\"")
    session.appendTurn(role: .user, text: "Open https://private.example/account?token=abc123 and quote 'account balance: 42'")

    let recent = session.recentInteraction ?? ""
    #expect(!recent.contains("owner@example.com"))
    #expect(!recent.contains("quarterly results are private"))
    #expect(!recent.contains("https://private.example/account?token=abc123"))
    #expect(!recent.contains("account balance: 42"))
}

@Test("recent interaction is a bounded action summary even for unlabeled prose")
@MainActor func conversationDoesNotLeakUnlabeledPrivateProse() {
    let session = ControlConversationSession()
    _ = session.beginTask(request: "Tell owner@example.com that violet-cedar-phrase-741 is private")
    session.appendTurn(role: .user, text: "Open https://private.example/account?query=violet-cedar-query-852")

    let recent = session.recentInteraction ?? ""
    #expect(!recent.contains("violet-cedar-phrase-741"))
    #expect(!recent.contains("violet-cedar-query-852"))
}

@Test("a new hold clears an inactive or expired target conversation")
@MainActor func holdRejectsExpiredConversationState() {
    let start = Date(timeIntervalSince1970: 1_000)
    let session = ControlConversationSession(maxTurns: 4, inactivityTimeout: 10)
    let first = session.beginTask(request: "Open the editor")
    session.bindExecution(
        targetBundleIdentifier: "com.example.Editor",
        grantExpiresAt: start.addingTimeInterval(60),
        now: start
    )
    #expect(session.accepts(first))
    #expect(session.beginHoldIfCurrent(
        now: start.addingTimeInterval(11),
        targetBundleIdentifier: "com.example.Editor",
        grantExpiresAt: start.addingTimeInterval(60)
    ) == nil)
    #expect(session.taskID == nil)

    let second = session.beginTask(request: "Open the editor")
    session.bindExecution(
        targetBundleIdentifier: "com.example.Editor",
        grantExpiresAt: start.addingTimeInterval(1),
        now: start
    )
    #expect(session.beginHoldIfCurrent(
        now: start.addingTimeInterval(2),
        targetBundleIdentifier: "com.example.Editor",
        grantExpiresAt: start.addingTimeInterval(1)
    ) == nil)
    #expect(!session.accepts(second))

    let missingGrantSession = ControlConversationSession()
    _ = missingGrantSession.beginTask(request: "Open the editor")
    missingGrantSession.bindExecution(
        targetBundleIdentifier: "com.example.Editor",
        grantExpiresAt: start.addingTimeInterval(60),
        now: start
    )
    #expect(missingGrantSession.beginHoldIfCurrent(now: start.addingTimeInterval(1)) == nil)
}
