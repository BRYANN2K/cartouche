import Foundation

// A store job that failed: Activity keeps it, with its reason, until Try Again or Dismiss.
struct StoreFailure: Identifiable, Equatable, Sendable {
    // The failed job's own ID
    let id: UUID
    let gameID: String
    let title: String
    let label: String
    let reason: String
    // An import's folder is not kept with the job, so only Dismiss is offered.
    let canRetry: Bool

    init(id: UUID, gameID: String, title: String, kind: StoreJob.Kind, reason: String) {
        self.id = id
        self.gameID = gameID
        self.title = title
        self.reason = reason
        label = switch kind {
        case .install: String(localized: "Download failed")
        case .update: String(localized: "Update failed")
        case .verify: String(localized: "Verification failed")
        case .importing: String(localized: "Import failed")
        }
        if case .importing = kind { canRetry = false } else { canRetry = true }
    }
}

extension StoreCenter {

    var failures: [StoreFailure] {
        jobs.compactMap { job in
            guard case .failed(let reason) = job.phase else { return nil }
            return StoreFailure(id: job.id, gameID: job.gameID, title: job.title, kind: job.kind, reason: reason)
        }
    }

    func dismiss(_ failure: StoreFailure) {
        guard let job = jobs.first(where: { $0.id == failure.id }) else { return }
        dismiss(job)
    }

    // The same job again, queued as a fresh one once the failed one leaves the list.
    func retry(_ failure: StoreFailure) {
        guard failure.canRetry, let job = jobs.first(where: { $0.id == failure.id }),
              let game = library?.game(failure.gameID) else { return }
        dismiss(job)
        switch job.kind {
        case .install: install(game)
        case .update: update(game)
        case .verify: verify(game)
        case .importing: break
        }
    }
}
