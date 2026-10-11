import Foundation

/// Applies UI-friendly debounce and latest-query-wins cancellation semantics.
public actor SearchCoordinator {
    private let service: any SearchService
    private var currentTask: Task<[SymbolSearchResult], any Error>?
    private var generation = 0

    public init(service: any SearchService) {
        self.service = service
    }

    public func search(
        _ rawQuery: String,
        in docsets: [DocsetDescriptor],
        limit: Int = 1_000,
        debounce: Duration = .milliseconds(150)
    ) async throws -> [SymbolSearchResult] {
        currentTask?.cancel()
        generation += 1
        let requestGeneration = generation
        let task = Task { [service] in
            if debounce > .zero {
                try await Task.sleep(for: debounce)
            }
            try Task.checkCancellation()
            return try await service.search(rawQuery, in: docsets, limit: limit)
        }
        currentTask = task

        do {
            let results = try await task.value
            guard generation == requestGeneration else {
                throw CancellationError()
            }
            currentTask = nil
            return results
        } catch {
            if generation == requestGeneration {
                currentTask = nil
            }
            throw error
        }
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        generation += 1
    }
}
