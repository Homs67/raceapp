import Foundation

/// Scripted transport: maps commands to canned responses, delivered in small
/// chunks to exercise the response accumulator exactly like a real BLE link.
/// Used by unit tests, replayed driveway transcripts, and demo mode.
public final class ReplayTransport: ObdTransport, @unchecked Sendable {

    public let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var responseQueues: [String: [String]]
    private var recordedCommands: [String] = []
    private let chunkSize: Int

    /// - Parameter responses: command → queue of response bodies (without the
    ///   trailing prompt; "\r>" is appended automatically). The last response
    ///   for a command is sticky — repeated once the queue drains.
    public init(responses: [String: [String]], chunkSize: Int = 8) {
        self.responseQueues = responses
        self.chunkSize = max(1, chunkSize)
        var continuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Convenience: one fixed response per command.
    public convenience init(simple: [String: String], chunkSize: Int = 8) {
        self.init(responses: simple.mapValues { [$0] }, chunkSize: chunkSize)
    }

    /// Commands received so far, in order (for test assertions).
    public var sentCommands: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedCommands
    }

    public func send(_ data: Data) async throws {
        guard let command = String(data: data, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let full = nextResponse(for: command) + "\r>"
        var remaining = Substring(full)
        while !remaining.isEmpty {
            let chunk = remaining.prefix(chunkSize)
            continuation.yield(Data(chunk.utf8))
            remaining = remaining.dropFirst(chunk.count)
        }
    }

    public func finish() {
        continuation.finish()
    }

    private func nextResponse(for command: String) -> String {
        lock.lock(); defer { lock.unlock() }
        recordedCommands.append(command)
        guard var queue = responseQueues[command], !queue.isEmpty else {
            return "?" // ELM's response to an unknown command
        }
        let body = queue.count == 1 ? queue[0] : queue.removeFirst()
        responseQueues[command] = queue
        return body
    }
}
