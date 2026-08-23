import Foundation

struct AgentActivityItem: Decodable, Identifiable {
    let sessionId: String
    let missionId: String?
    let attemptId: String?
    let state: String
    let title: String
    let summary: String?
    let provider: String?
    let cwd: String?
    let updatedAt: String
    let readAt: String?

    var id: String { sessionId }
    var needsAttention: Bool { state == "needs_input" || state == "needs_permission" }
}

struct MissionWorktreeOptions: Decodable {
    let baseRef: String?
    let sharedDirectories: [String]
    let copyPaths: [String]
}

struct MissionAttempt: Decodable, Identifiable {
    let id: String
    let missionId: String
    let sessionId: String?
    let provider: String
    let state: String
    let branch: String?
    let worktreePath: String?
    let baseRef: String?
    let summary: String?
    let error: String?
    let createdAt: String
    let updatedAt: String
}

struct MissionReviewComment: Decodable, Identifiable {
    let id: String
    let missionId: String
    let attemptId: String
    let filePath: String
    let line: Int?
    let side: String
    let body: String
    let status: String
    let createdAt: String
    let sentAt: String?
    let resolvedAt: String?
}

struct MissionInfo: Decodable, Identifiable {
    let id: String
    let title: String
    let prompt: String
    let cwd: String
    let taskId: String?
    let status: String
    let worktree: MissionWorktreeOptions
    let createdAt: String
    let updatedAt: String
    let attempts: [MissionAttempt]
    let comments: [MissionReviewComment]

    func pendingComments(for attemptId: String) -> [MissionReviewComment] {
        comments.filter { $0.attemptId == attemptId && $0.status == "pending" }
    }
}

struct MissionDiffFile: Decodable, Identifiable {
    let path: String
    let status: String

    var id: String { "\(status)-\(path)" }
}

struct MissionDiff: Decodable {
    let missionId: String
    let attemptId: String
    let baseRef: String
    let files: [MissionDiffFile]
    let patch: String
    let truncated: Bool
}

struct MissionInboxResponse: Decodable { let items: [AgentActivityItem] }
struct MissionListResponse: Decodable { let missions: [MissionInfo] }
struct MissionReviewResponse: Decodable { let comments: [MissionReviewComment] }
struct MissionOKResponse: Decodable { let ok: Bool }

