import Foundation
import Combine
import CryptoKit

struct UnknownSessionDeliveryError: LocalizedError {
    let sessionID: String
    let cause: Error
    var errorDescription: String? { cause.localizedDescription }
}

struct UnknownTaskDeliveryError: LocalizedError {
    let taskID: String
    let cause: Error
    var errorDescription: String? { cause.localizedDescription }
}

@MainActor
final class NewConversationCoordinator: ObservableObject {
    private static var instances: [String: NewConversationCoordinator] = [:]

    static func shared(serverID: String, scope: String = "default") -> NewConversationCoordinator {
        let identity = "\(serverID)|\(scope)"
        if let existing = instances[identity] { return existing }
        let coordinator = NewConversationCoordinator(storageKey: storageKey(serverID: serverID, scope: scope))
        instances[identity] = coordinator
        return coordinator
    }

    private static func storageKey(serverID: String, scope: String) -> String {
        let digest = SHA256.hash(data: Data("\(serverID)|\(scope)|new-conversation".utf8))
        let fingerprint = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "wand.new-conversation.state.\(fingerprint)"
    }

    enum Phase: Equatable {
        case idle
        case conversationOnly
        case creating
        case taskAccepted(taskID: String)
        case accepted(sessionID: String, taskID: String?)
        case deliveryUnknown(String)
        case rejected(String)
    }

    enum Adoption: Equatable {
        case adopted
        case sourceChanged
        case targetAlreadyHasContent
    }

    enum UnknownOperation: String, Equatable {
        case task
        case session
    }

    @Published private(set) var phase: Phase
    @Published private(set) var creationError: String?
    private(set) var unknownOperation: UnknownOperation?
    private(set) var unknownSessionID: String?
    private(set) var unknownTaskID: String?
    private let storageKey: String
    private let defaults: UserDefaults
    private var acceptedTaskID: String?
    private var taskWasAccepted = false
    private var creationRequestID: String?
    private(set) var skipsTaskCreation = false

    init(defaults: UserDefaults = .standard) {
        self.storageKey = "wand.new-conversation.state.default"
        self.defaults = defaults
        phase = .idle
        restore()
    }

    init(storageKey: String, defaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.defaults = defaults
        phase = .idle
        restore()
    }

    var canSubmit: Bool { phase == .idle || phase == .conversationOnly || isDefiniteRejection }
    var currentCreationRequestID: String? { creationRequestID }
    var isDefiniteRejection: Bool { if case .rejected = phase { return true }; return false }
    var acceptedTaskIDForContinuation: String? {
        if case .taskAccepted(let taskID) = phase { return taskID }
        return acceptedTaskID
    }
    var acceptedSessionIDForContinuation: String? {
        if case .accepted(let sessionID, _) = phase { return sessionID }
        return nil
    }

    func retryRejectedTaskCreation() {
        guard case .rejected = phase, !taskWasAccepted else { return }
        phase = skipsTaskCreation ? .conversationOnly : .idle
    }

    func abandonAcceptedSession(sessionID: String) {
        guard case .accepted(let acceptedID, let taskID) = phase, acceptedID == sessionID else { return }
        persist(.accepted(sessionID: acceptedID, taskID: taskID))
    }

    private func keepAcceptedSessionForResume(_ sessionID: String) {
        phase = .accepted(sessionID: sessionID, taskID: nil)
        persist(phase)
    }

    func resetAfterHandoff(sessionID: String) {
        guard case .accepted(let acceptedID, _) = phase, acceptedID == sessionID else { return }
        phase = .idle
        acceptedTaskID = nil
        taskWasAccepted = false
        skipsTaskCreation = false
        creationError = nil
        defaults.removeObject(forKey: storageKey)
        creationRequestID = nil
        unknownOperation = nil
        unknownSessionID = nil
        unknownTaskID = nil
    }

    func acknowledgeDeliveryUnknown(confirmedChecked: Bool) {
        guard confirmedChecked, case .deliveryUnknown = phase,
              unknownOperation == .task, taskWasAccepted, let acceptedTaskID else { return }
        unknownOperation = nil
        unknownSessionID = nil
        unknownTaskID = nil
        phase = .taskAccepted(taskID: acceptedTaskID)
        persist(phase)
    }

    /// The unknown operation only created a task container; it never sent a message
    /// or created a session. An explicit choice may continue without that container.
    func continueWithoutTask() {
        guard case .deliveryUnknown = phase, unknownOperation == .task,
              !taskWasAccepted, unknownSessionID == nil else { return }
        if let saved = defaults.dictionary(forKey: storageKey) {
            let requestID = creationRequestID ?? UUID().uuidString
            defaults.set(saved, forKey: "\(storageKey).unresolved-task.\(requestID)")
        }
        skipsTaskCreation = true
        creationRequestID = nil
        unknownOperation = nil
        unknownTaskID = nil
        phase = .conversationOnly
        persist(phase)
    }

    func keepDeliveryUnknown(_ message: String) {
        guard case .deliveryUnknown = phase else { return }
        phase = .deliveryUnknown(message)
        persist(phase)
    }

    func markTaskAccepted(_ taskID: String) {
        acceptedTaskID = taskID
        taskWasAccepted = true
        creationRequestID = nil
        unknownOperation = nil
        unknownSessionID = nil
        unknownTaskID = nil
        phase = .taskAccepted(taskID: taskID)
        persist(.taskAccepted(taskID: taskID))
    }

    func createTask(using operation: () async throws -> String) async -> String? {
        await createTask(requestID: UUID().uuidString.lowercased(), using: operation)
    }

    func createTask(requestID: String, using operation: () async throws -> String) async -> String? {
        guard !skipsTaskCreation, phase == .idle || (isDefiniteRejection && !taskWasAccepted) else { return nil }
        if isDefiniteRejection { phase = .idle }
        taskWasAccepted = false
        acceptedTaskID = nil
        creationError = nil
        creationRequestID = requestID
        unknownOperation = nil
        unknownSessionID = nil
        unknownTaskID = nil
        phase = .creating
        persistCreating(operation: .task)
        do {
            let taskID = try await operation()
            markTaskAccepted(taskID)
            return taskID
        } catch {
            settleFailure(error, operation: .task)
            return nil
        }
    }

    func beginSessionContinuation() {
        guard case .taskAccepted(let taskID) = phase else { return }
        acceptedTaskID = taskID
    }

    func resolveUnknownSession(_ snapshot: SessionSnapshot) {
        guard unknownOperation == .session, case .deliveryUnknown = phase else { return }
        unknownOperation = nil
        unknownSessionID = nil
        unknownTaskID = nil
        phase = .accepted(sessionID: snapshot.id, taskID: acceptedTaskID)
        persist(phase)
    }

    func rejectUnknownSessionAfterCheck() {
        guard unknownOperation == .session, case .deliveryUnknown = phase else { return }
        keepDeliveryUnknown("会话创建结果仍无法与请求可靠关联；请勿重复创建。")
    }

    func rejectUnknownTaskAfterCheck() {
        guard unknownOperation == .task, case .deliveryUnknown = phase else { return }
        keepDeliveryUnknown("任务创建结果仍无法与请求可靠关联；请勿重复创建。")
    }

    func resolveUnknownTask(_ taskID: String) {
        guard unknownOperation == .task, case .deliveryUnknown = phase else { return }
        markTaskAccepted(taskID)
    }

    func create(_ operation: () async throws -> SessionSnapshot) async -> SessionSnapshot? {
        await create(requestID: UUID().uuidString.lowercased(), using: operation)
    }

    func create(requestID: String, using operation: () async throws -> SessionSnapshot) async -> SessionSnapshot? {
        let taskID: String?
        switch phase {
        case .idle, .conversationOnly:
            taskID = nil
        case .rejected where !taskWasAccepted:
            taskID = nil
        case .taskAccepted(let acceptedID):
            taskID = acceptedID
        default:
            return nil
        }
        unknownOperation = nil
        unknownSessionID = nil
        unknownTaskID = nil
        creationError = nil
        creationRequestID = requestID
        if isDefiniteRejection { phase = .idle }
        if let taskID { acceptedTaskID = taskID }
        phase = .creating
        persistCreating(operation: .session)
        do {
            let snapshot = try await operation()
            unknownOperation = nil
            unknownSessionID = nil
            phase = .accepted(sessionID: snapshot.id, taskID: taskID)
            creationRequestID = nil
            persist(.accepted(sessionID: snapshot.id, taskID: taskID))
            return snapshot
        } catch {
            settleFailure(error, operation: .session)
            return nil
        }
    }

    func adopt(_ text: String, expectedSourceRevision: Int, currentSourceRevision: Int,
               expectedAttachmentRevision: Int, currentAttachmentRevision: Int, sourceText: String,
               attachments: [UploadedFile] = [], targetSessionID: String, into draft: ComposerDraftState) -> Adoption {
        guard case .accepted(let sessionID, _) = phase, sessionID == targetSessionID else {
            return .targetAlreadyHasContent
        }
        guard expectedSourceRevision == currentSourceRevision,
              expectedAttachmentRevision == currentAttachmentRevision,
              sourceText == text else { return .sourceChanged }
        guard draft.adoptInitialDraft(text: text, expectedSourceRevision: expectedSourceRevision,
                                      expectedText: sourceText, attachments: attachments) else {
            return .targetAlreadyHasContent
        }
        return .adopted
    }

    func adopt(_ text: String, targetSessionID: String, into draft: ComposerDraftState) -> Adoption {
        adopt(text, expectedSourceRevision: 0, currentSourceRevision: 0,
              expectedAttachmentRevision: 0, currentAttachmentRevision: 0,
              sourceText: text, targetSessionID: targetSessionID, into: draft)
    }

    private func settleFailure(_ error: Error, operation: UnknownOperation) {
        creationError = error.localizedDescription
        unknownOperation = operation
        unknownSessionID = (error as? UnknownSessionDeliveryError)?.sessionID
        unknownTaskID = (error as? UnknownTaskDeliveryError)?.taskID
        if isDefiniteInputRejection(error) {
            unknownOperation = nil
            unknownSessionID = nil
            unknownTaskID = nil
            if taskWasAccepted, let acceptedTaskID {
                phase = .taskAccepted(taskID: acceptedTaskID)
                persist(phase)
            } else if skipsTaskCreation {
                phase = .rejected(error.localizedDescription)
                persist(.conversationOnly)
            } else {
                phase = .rejected(error.localizedDescription)
                persist(phase)
            }
            return
        }
        let reason = error.localizedDescription
        var state: [String: Any] = ["phase": "deliveryUnknown", "reason": reason, "operation": operation.rawValue]
        if skipsTaskCreation { state["skipsTaskCreation"] = true }
        if let creationRequestID { state["requestID"] = creationRequestID }
        if let acceptedTaskID { state["taskID"] = acceptedTaskID }
        if let unknownSessionID { state["sessionID"] = unknownSessionID }
        if let unknownTaskID { state["unknownTaskID"] = unknownTaskID }
        defaults.set(state, forKey: storageKey)
        phase = .deliveryUnknown(reason)
    }

    private func restore() {
        guard let saved = defaults.dictionary(forKey: storageKey),
              let phaseName = saved["phase"] as? String else { return }
        skipsTaskCreation = saved["skipsTaskCreation"] as? Bool ?? false
        switch phaseName {
        case "conversationOnly":
            skipsTaskCreation = true
            phase = .conversationOnly
        case "taskAccepted":
            guard let taskID = saved["taskID"] as? String, !taskID.isEmpty else { return }
            taskWasAccepted = true
            acceptedTaskID = taskID
            phase = .taskAccepted(taskID: taskID)
        case "accepted":
            guard let sessionID = saved["sessionID"] as? String, !sessionID.isEmpty else { return }
            let taskID = saved["taskID"] as? String
            taskWasAccepted = taskID != nil
            acceptedTaskID = taskID
            phase = .accepted(sessionID: sessionID, taskID: taskID)
        case "deliveryUnknown":
            acceptedTaskID = saved["taskID"] as? String
            taskWasAccepted = acceptedTaskID != nil
            unknownOperation = (saved["operation"] as? String).flatMap(UnknownOperation.init(rawValue:))
            unknownSessionID = saved["sessionID"] as? String
            unknownTaskID = saved["unknownTaskID"] as? String
            creationRequestID = saved["requestID"] as? String
            phase = .deliveryUnknown(saved["reason"] as? String ?? "创建结果未知，请先核对")
        default: break
        }
    }

    private func persistCreating(operation: UnknownOperation) {
        var state: [String: Any] = [
            "phase": "deliveryUnknown",
            "reason": "创建结果未知，请先核对",
            "operation": operation.rawValue
        ]
        if let creationRequestID { state["requestID"] = creationRequestID }
        if let acceptedTaskID { state["taskID"] = acceptedTaskID }
        if skipsTaskCreation { state["skipsTaskCreation"] = true }
        // A reopened owner must assume unknown delivery. The live owner still has
        // the request in flight and must not offer recovery before it settles.
        defaults.set(state, forKey: storageKey)
        unknownOperation = operation
        unknownSessionID = nil
        unknownTaskID = nil
    }

    private func persist(_ value: Phase) {
        var saved: [String: Any]
        switch value {
        case .conversationOnly: saved = ["phase": "conversationOnly"]
        case .taskAccepted(let taskID): saved = ["phase": "taskAccepted", "taskID": taskID]
        case .accepted(let sessionID, let taskID):
            var state: [String: Any] = ["phase": "accepted", "sessionID": sessionID]
            if let taskID { state["taskID"] = taskID }
            saved = state
        case .deliveryUnknown(let reason):
            var state: [String: Any] = ["phase": "deliveryUnknown", "reason": reason]
            if let unknownOperation { state["operation"] = unknownOperation.rawValue }
            if let creationRequestID { state["requestID"] = creationRequestID }
            if let unknownSessionID { state["sessionID"] = unknownSessionID }
            if let unknownTaskID { state["unknownTaskID"] = unknownTaskID }
            if taskWasAccepted, let acceptedTaskID { state["taskID"] = acceptedTaskID }
            saved = state
        default: defaults.removeObject(forKey: storageKey); return
        }
        if skipsTaskCreation { saved["skipsTaskCreation"] = true }
        defaults.set(saved, forKey: storageKey)
    }
}
