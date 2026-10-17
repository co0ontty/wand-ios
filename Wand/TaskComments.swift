import Foundation

struct WandTaskComment: Decodable, Equatable, Identifiable {
    let id: String
    let taskId: String
    let authorName: String
    let body: String
    let createdAt: String
}

struct WandTaskCommentsResponse: Decodable {
    let comments: [WandTaskComment]
}

/// A request identity prevents a late A response from replacing B (or a newly reopened A).
struct WandTaskCommentState {
    private(set) var taskId = ""
    private(set) var requestId = UUID()
    private(set) var comments: [WandTaskComment] = []

    mutating func begin(taskId: String) -> UUID {
        if self.taskId != taskId { comments = [] }
        self.taskId = taskId
        requestId = UUID()
        return requestId
    }

    mutating func accept(_ comments: [WandTaskComment], taskId: String, requestId: UUID) {
        guard self.taskId == taskId, self.requestId == requestId else { return }
        self.comments = comments.filter { $0.taskId == taskId }
    }

    func visible(taskId: String) -> [WandTaskComment] {
        self.taskId == taskId ? comments : []
    }
}
