import Foundation
import TranslationCore

/// Serializes session retirement with new submissions, keeping at most one child.
@MainActor
final class WorkerClient {
    static let shared = WorkerClient()
    private var session: Session?
    private let makeProcess: () throws -> WorkerProcess
    var isRetiring: Bool { session?.closing == true }

    init(makeProcess: @escaping () throws -> WorkerProcess = {
        guard let executable = Bundle.main.executableURL else { throw TranslationError.invalidResponse }
        return WorkerProcess(executable: executable, arguments: [TranslationWorker.argument])
    }) {
        self.makeProcess = makeProcess
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        guard let session, !session.closing else { return }
        do { try session.process.send(TranslationWorker.Command.shortcut(shortcut)) }
        catch { session.process.cancel() }
    }

    func translate(_ request: TranslationWorker.Request, delivery: TranslationDelivery) async throws {
        let current = try await availableSession()
        try await withTaskCancellationHandler {
            if Task.isCancelled {
                retireIfEmpty(current)
                throw CancellationError()
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                current.pending[request.id] = Pending(continuation: continuation, delivery: delivery)
                do { try current.process.send(TranslationWorker.Command.translate(request)) }
                catch {
                    current.pending.removeValue(forKey: request.id)?.continuation.resume(throwing: error)
                    current.process.cancel()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request.id, in: current) }
        }
    }

    private func availableSession() async throws -> Session {
        while let previous = session, previous.closing {
            await previous.process.waitForCompletion()
            if session === previous { session = nil }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        if let session { return session }
        let current = Session(process: try makeProcess())
        let events = current.process.events()
        session = current
        current.listener = Task { @MainActor [weak self, current] in
            var failure: (any Error)?
            do {
                for try await event in events { await self?.handle(event, in: current) }
            } catch { failure = error }
            await current.process.waitForCompletion()
            self?.finish(current, error: current.failure ?? failure ?? TranslationError.incompleteStream)
            current.listener = nil
        }
        return current
    }

    private func handle(_ event: TranslationWorker.Event, in current: Session) async {
        switch event {
        case .captured(let id):
            if let pending = current.pending[id] { await pending.delivery.onCaptureComplete() }
        case .closed(let id): current.pending.removeValue(forKey: id)?.continuation.resume()
        case .action(let id, let action):
            let pending = id.flatMap { current.pending[$0] } ?? (id == nil ? current.pending.values.first : nil)
            // Deliver before a following closed event resumes the request and
            // invalidates its app callback (e.g. "open screen recording settings").
            if let pending { await pending.delivery.onAction(action) }
        case .failure(let id, let failure):
            if let id { current.pending.removeValue(forKey: id)?.continuation.resume(throwing: failure.error) }
            else { current.failure = failure.error; current.closing = true; current.process.cancel() }
        case .idle:
            retireIfEmpty(current)
        }
    }

    private func retireIfEmpty(_ current: Session) {
        if current.pending.isEmpty, !current.closing {
            current.closing = true
            do { try current.process.send(TranslationWorker.Command.shutdown) }
            catch { current.process.cancel() }
        }
    }

    private func cancel(_ id: UUID, in current: Session) {
        guard let pending = current.pending.removeValue(forKey: id) else { return }
        do { try current.process.send(TranslationWorker.Command.cancel(id)) }
        catch { current.process.cancel() }
        pending.continuation.resume(throwing: CancellationError())
    }

    private func finish(_ current: Session, error: any Error) {
        let pending = current.pending
        current.pending.removeAll()
        for value in pending.values { value.continuation.resume(throwing: error) }
        if session === current { session = nil }
    }

    private struct Pending {
        let continuation: CheckedContinuation<Void, any Error>
        let delivery: TranslationDelivery
    }

    @MainActor private final class Session {
        let process: WorkerProcess
        var pending: [UUID: Pending] = [:]
        var closing = false
        var failure: (any Error)?
        var listener: Task<Void, Never>?
        init(process: WorkerProcess) { self.process = process }
    }
}
