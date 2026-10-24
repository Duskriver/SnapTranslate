import Foundation

/// Bound concurrent uploads/responses while allowing new selections to capture
/// before waiting. Encoded PNGs belong to individual cancellable request tasks.
actor WorkerNetworkAdmission {
    static let shared = WorkerNetworkAdmission()
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if active == 2 { waiters.append((id, continuation)) }
                else { active += 1; continuation.resume() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // A grant can race cancellation. Return that slot exactly once.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
