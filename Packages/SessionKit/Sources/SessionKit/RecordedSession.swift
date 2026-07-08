import Foundation

/// Session metadata placeholder — the full channel model, append-only writer,
/// and GRDB store arrive in Phase 3 (08-build-plan.md).
public struct RecordedSession: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date

    public init(id: UUID = UUID(), startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }
}
