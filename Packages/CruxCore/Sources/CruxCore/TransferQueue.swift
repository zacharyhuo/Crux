import CryptoKit
import Foundation

/// Runs at most two transfers at a time, persists their state, and never
/// installs a cancelled or failed download.
///
/// Each job downloads (unless it is a local import) into the application
/// downloads directory, then hands the file to `DocsetInstaller`. Staging and
/// activation stay on the destination volume; this queue only owns the
/// transfer and the registry update that follows a successful install.
public actor TransferQueue {
    public static let maximumConcurrentJobs = 2

    private let downloadClient: any DownloadClient
    private let installer: DocsetInstaller
    private let registry: DocsetRegistry
    private let layout: AppDirectoryLayout
    private var jobs: [UUID: TransferJob] = [:]
    private var running = 0
    private var scheduled: Set<UUID> = []
    private var waiters: [UUID: Task<Void, Never>] = [:]
    private var observer: (@Sendable ([TransferJob]) -> Void)?
    private var schedulingPaused = false
    private var libraryMutationInProgress = false

    public init(
        downloadClient: any DownloadClient,
        installer: DocsetInstaller = DocsetInstaller(),
        registry: DocsetRegistry,
        layout: AppDirectoryLayout
    ) {
        self.downloadClient = downloadClient
        self.installer = installer
        self.registry = registry
        self.layout = layout
    }

    public func setObserver(_ observer: (@Sendable ([TransferJob]) -> Void)?) {
        self.observer = observer
        observer?(snapshot)
    }

    public var snapshot: [TransferJob] {
        jobs.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func restorePersistedJobs(startQueued: Bool = true) async throws {
        schedulingPaused = !startQueued
        let destination = try await resolvedDestination()
        try await DocsetReplacementTransaction(registry: registry, docsetsDirectory: destination, installer: installer).recoverPending()
        let stored = try await registry.allJobs()
        for var job in stored.sorted(by: { $0.createdAt < $1.createdAt }) {
            if let key = job.slotKey, hasActiveSlot(key) {
                job.status = .failed(message: DocsetReplacementError.slotBusy.localizedDescription)
                jobs[job.id] = job
                continue
            }
            switch job.status {
            case .completed, .cancelled:
                continue
            case .failed:
                jobs[job.id] = job
            case .queued:
                if !(await sourceIsAvailable(for: job)) { job.status = .cancelled }
                jobs[job.id] = job
            case .downloading, .installing:
                // A mid-flight job cannot be resumed without the original
                // URLSession task, so it converges to a clear failure.
                job.status = .failed(message: TransferError.notRestored.errorDescription ?? "not restored")
                jobs[job.id] = job
            }
        }
        try await persist()
        publish()
        pump()
    }

    public func resumeScheduling() {
        schedulingPaused = false
        pump()
    }

    /// Reserve an idle library before destructive maintenance. Requests may be
    /// queued during the reservation, but none may start until it is released.
    public func beginLibraryMutation() -> Bool {
        guard !libraryMutationInProgress, scheduled.isEmpty,
              !jobs.values.contains(where: \.isActive) else { return false }
        libraryMutationInProgress = true
        return true
    }

    public func endLibraryMutation() {
        libraryMutationInProgress = false
        pump()
    }

    @discardableResult
    public func enqueue(_ request: TransferRequest) -> TransferJob {
        if let existing = jobs.values.first(where: { $0.isActive && $0.sourceURL == request.sourceURL && $0.target == request.target && $0.sourceConfigurationID == request.sourceConfigurationID }) {
            return existing
        }
        var job = TransferJob(
            kind: request.kind,
            displayName: request.displayName,
            sourceURL: request.sourceURL,
            expectedIdentifier: request.expectedIdentifier,
            catalogName: request.catalogName,
            catalogSourceId: request.catalogSourceId,
            feedURL: request.feedURL,
            advertisedVersion: request.advertisedVersion,
            fallbackIconData: request.fallbackIconData,
            target: request.target,
            sourceConfigurationID: request.sourceConfigurationID, sourceName: request.sourceName,
            transportPolicy: request.transportPolicy, installationIdentifier: request.installationIdentifier
        )
        if let key = job.slotKey, hasActiveSlot(key) { job.status = .failed(message: DocsetReplacementError.slotBusy.localizedDescription) }
        jobs[job.id] = job
        publishSoon()
        pump()
        return job
    }

    public func cancel(_ id: UUID) {
        guard var job = jobs[id], job.isActive else { return }
        waiters[id]?.cancel()
        waiters[id] = nil
        job.status = .cancelled
        jobs[id] = job
        if let fileURL = job.downloadedFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        publishSoon()
        pump()
    }

    public func cancel(sourceConfigurationID: UUID) {
        for job in jobs.values where job.sourceConfigurationID == sourceConfigurationID && job.isActive { cancel(job.id) }
    }

    public func retry(_ id: UUID) {
        guard var job = jobs[id] else { return }
        switch job.status {
        case .failed, .cancelled:
            if let key = job.slotKey, hasActiveSlot(key, excluding: id) {
                job.status = .failed(message: DocsetReplacementError.slotBusy.localizedDescription)
                jobs[id] = job
                publishSoon()
                return
            }
            guard !scheduled.contains(id) else { return }
            job.status = .queued
            jobs[id] = job
            publishSoon()
            pump()
        default:
            break
        }
    }

    public func clearFinished() {
        jobs = jobs.filter { $0.value.isActive }
        publishSoon()
    }

    public func pendingCount(matching request: TransferRequest) -> Int {
        jobs.values.filter { job in
            (job.isActive || scheduled.contains(job.id)) && job.sourceConfigurationID == request.sourceConfigurationID &&
                (request.target.map { $0.slotKey == job.target?.slotKey } ?? (job.sourceURL == request.sourceURL))
        }.count
    }

    private func hasActiveSlot(_ key: String, excluding: UUID? = nil) -> Bool {
        jobs.values.contains { $0.id != excluding && ($0.isActive || scheduled.contains($0.id)) && $0.slotKey == key }
    }

    // MARK: - Scheduling

    private func pump() {
        guard !schedulingPaused, !libraryMutationInProgress else { return }
        while running < Self.maximumConcurrentJobs {
            guard let next = jobs.values
                .filter({ job in
                    guard case .queued = job.status else { return false }
                    if job.kind == .localImport, scheduled.contains(where: { jobs[$0]?.kind == .localImport }) { return false }
                    return !scheduled.contains(job.id)
                })
                .min(by: { $0.createdAt < $1.createdAt })
            else { return }
            running += 1
            scheduled.insert(next.id)
            let id = next.id
            waiters[id] = Task {
                await self.perform(id)
            }
        }
    }

    private func perform(_ id: UUID) async {
        defer {
            running = max(0, running - 1)
            scheduled.remove(id)
            waiters[id] = nil
            pump()
        }
        guard var job = jobs[id], case .queued = job.status else { return }
        do {
            try Task.checkCancellation()
            guard await sourceIsAvailable(for: job) else { throw DocsetSourceError.sourceUnavailable }
            if let target = job.target {
                try target.validate()
                guard job.kind == .catalog, job.sourceURL == target.release.downloadURL,
                      job.catalogSourceId == target.sourceId, job.catalogName == target.familyId,
                      job.expectedIdentifier == target.release.identifier,
                      job.advertisedVersion == target.release.advertisedVersion,
                      job.sourceConfigurationID == target.sourceConfigurationID else { throw DocsetReplacementError.targetMismatch }
            }
            let artifactURL: URL
            if job.kind == .localImport {
                artifactURL = job.sourceURL
            } else {
                try (job.transportPolicy ?? .strictHTTPS).validate(job.sourceURL)
                try FileManager.default.createDirectory(at: layout.downloadsDirectory, withIntermediateDirectories: true)
                let fileURL = layout.downloadsDirectory.appending(path: "\(job.id.uuidString).tgz", directoryHint: .notDirectory)
                job.downloadedFileURL = fileURL
                job.status = .downloading(bytesReceived: 0, bytesExpected: nil)
                jobs[id] = job
                publish()
                try await downloadClient.download(from: job.sourceURL, to: fileURL, progress: { [weak self] received, expected in
                    guard let self else { return }
                    Task { await self.updateProgress(id: id, received: received, expected: expected) }
                }, transportPolicy: job.transportPolicy ?? .strictHTTPS)
                try Task.checkCancellation()
                artifactURL = fileURL
            }

            guard jobs[id]?.status.isCancelled != true else { return }
            guard await sourceIsAvailable(for: job) else { throw DocsetSourceError.sourceUnavailable }
            job.status = .installing
            jobs[id] = job
            publish()

            let destination = try await resolvedDestination()
            let existing = try await existingRecord(for: job)
            let descriptor: DocsetDescriptor
            if let target = job.target {
                descriptor = try await DocsetReplacementTransaction(registry: registry, docsetsDirectory: destination, installer: installer)
                    .perform(target: target, artifactAt: artifactURL, existing: existing, sourceName: job.sourceName).descriptor
            } else {
                guard existing?.installTarget == nil else { throw DocsetReplacementError.conflictingInstall }
                let sourceConfigurationID = job.sourceConfigurationID
                let localResolver: (@Sendable (DocsetDescriptor) async throws -> DocsetDescriptor?)?
                if sourceConfigurationID == DocsetSourceConfiguration.localID {
                    localResolver = { [registry] candidate in
                        let record = try await registry.localImport(bundleIdentifier: candidate.bundleIdentifier,
                            sourceConfigurationID: DocsetSourceConfiguration.localID)
                        return record?.descriptor
                    }
                } else { localResolver = nil }
                let candidateValidator: @Sendable (DocsetDescriptor, URL) async throws -> Void = { [registry] candidate, destination in
                    let records: [InstalledDocset] = try await registry.allInstalled()
                    var expectedID = existing?.identifier
                    if expectedID == nil, sourceConfigurationID == DocsetSourceConfiguration.localID {
                        let local = try await registry.localImport(bundleIdentifier: candidate.bundleIdentifier,
                            sourceConfigurationID: DocsetSourceConfiguration.localID)
                        expectedID = local?.identifier
                    }
                    if expectedID == nil, sourceConfigurationID != nil, FileManager.default.fileExists(atPath: destination.path) {
                        throw DocsetReplacementError.conflictingInstall
                    }
                    for record in records {
                        if record.descriptor.bundleURL.path == destination.path, record.identifier != expectedID {
                            throw DocsetReplacementError.conflictingInstall
                        }
                        if sourceConfigurationID == nil, record.installTarget != nil,
                           record.descriptor.bundleIdentifier == candidate.bundleIdentifier { throw DocsetReplacementError.conflictingInstall }
                    }
                }
                let installedCandidate = try await installer.install(
                    artifactAt: artifactURL, into: destination, replacing: existing?.descriptor,
                    expectedIdentifier: job.expectedIdentifier ?? existing?.descriptor.bundleIdentifier, fallbackIconData: job.fallbackIconData,
                    destinationFileName: job.sourceConfigurationID.map { id in
                        let scope = "\(id.uuidString)/\(job.catalogSourceId ?? "")/\(job.catalogName ?? job.feedURL?.absoluteString ?? job.id.uuidString)"
                        return "crux-\(SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()).docset"
                    },
                    resolveExisting: localResolver,
                    validateCandidate: candidateValidator
                )
                var runtimeID = existing?.identifier
                if runtimeID == nil, sourceConfigurationID == DocsetSourceConfiguration.localID {
                    runtimeID = try await registry.localImport(bundleIdentifier: installedCandidate.bundleIdentifier,
                        sourceConfigurationID: DocsetSourceConfiguration.localID)?.identifier
                }
                descriptor = installedCandidate.identified(as: runtimeID ??
                    (sourceConfigurationID == nil ? installedCandidate.identifier : UUID().uuidString.lowercased()))
                _ = try await registry.upsert(InstalledDocset(descriptor: descriptor, source: job.source,
                    advertisedVersion: job.advertisedVersion ?? DocsetVersion(descriptor: descriptor),
                    sourceConfigurationID: job.sourceConfigurationID, sourceName: job.sourceName))
            }
            if let fileURL = job.downloadedFileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            job.status = .completed(identifier: descriptor.identifier)
            jobs[id] = job
            try await persist()
            publish()
        } catch is CancellationError {
            if var job = jobs[id] {
                job.status = .cancelled
                jobs[id] = job
                if let fileURL = job.downloadedFileURL {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            publishSoon()
        } catch {
            if var job = jobs[id] {
                job.status = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                jobs[id] = job
                if let fileURL = job.downloadedFileURL {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            publishSoon()
        }
    }

    private func updateProgress(id: UUID, received: Int64, expected: Int64?) {
        guard var job = jobs[id], job.isActive else { return }
        if case .downloading = job.status {
            job.status = .downloading(bytesReceived: received, bytesExpected: expected)
            jobs[id] = job
            observer?(snapshot)
        }
    }

    private func existingRecord(for job: TransferJob) async throws -> InstalledDocset? {
        if let target = job.target {
            return try await registry.installed(sourceConfigurationID: job.sourceConfigurationID, sourceId: target.sourceId, familyId: target.familyId)
        }
        if let id = job.installationIdentifier {
            guard let record = try await registry.installed(identifier: id), record.sourceConfigurationID == job.sourceConfigurationID else {
                throw DocsetReplacementError.conflictingInstall
            }
            return record
        }
        if let identifier = job.expectedIdentifier {
            return try await registry.installed(identifier: identifier)
        }
        if let catalogName = job.catalogName, let sourceId = job.catalogSourceId {
            return try await registry.allInstalled().first { record in
                if case let .catalog(name, id) = record.source {
                    return record.sourceConfigurationID == job.sourceConfigurationID && name == catalogName && id == sourceId
                }
                return false
            }
        }
        if let feedURL = job.feedURL {
            return try await registry.allInstalled().first { record in
                if case let .feed(url) = record.source { return record.sourceConfigurationID == job.sourceConfigurationID && url == feedURL }
                return false
            }
        }
        return nil
    }

    private func sourceIsAvailable(for job: TransferJob) async -> Bool {
        guard job.kind != .localImport, let id = job.sourceConfigurationID else { return true }
        guard let source = try? await registry.source(id: id), source.canFetch,
              source.transportPolicy == (job.transportPolicy ?? .strictHTTPS) else { return false }
        return true
    }

    private func resolvedDestination() async throws -> URL {
        let settings = try await registry.loadSettings()
        let destination = settings.resolvedDocsetsDirectory(layout: layout)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    private func persist() async throws {
        try await registry.saveJobs(snapshot.filter { job in
            switch job.status {
            case .completed, .cancelled: false
            default: true
            }
        })
    }

    private func publish() {
        observer?(snapshot)
        Task { try? await persist() }
    }

    private func publishSoon() {
        publish()
    }
}

private extension TransferJob.Status {
    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

private extension TransferJob {
    var source: DocsetSource {
        switch kind {
        case .catalog:
            .catalog(name: catalogName ?? displayName, sourceId: catalogSourceId ?? "com.kapeli")
        case .feed:
            .feed(feedURL: feedURL ?? sourceURL)
        case .localImport:
            .localImport
        }
    }
}
