import CryptoKit
import Darwin
import Foundation

/// A recoverable filesystem + registry transaction for trusted, exact releases.
/// Hidden staging/backups are never scanned or registered as another version.
public actor DocsetReplacementTransaction {
    private let registry: DocsetRegistry
    private let root: URL
    private let installer: DocsetInstaller
    private let parser = DocsetParser()

    public init(registry: DocsetRegistry, docsetsDirectory: URL, installer: DocsetInstaller = DocsetInstaller()) {
        self.registry = registry
        root = docsetsDirectory.standardizedFileURL
        self.installer = installer
    }

    @discardableResult
    public func perform(target: DocsetInstallTarget, artifactAt archive: URL,
                        existing expected: InstalledDocset? = nil, sourceName: String? = nil) async throws -> InstalledDocset {
        try target.validate()
        try Task.checkCancellation()
        let stateRoot = try await prepareStateRoot()
        let lock = try ReplacementFileLock(at: stateRoot.appending(path: target.slotFileName + ".lock"))
        defer { lock.close() }
        let operation = stateRoot.appending(path: target.slotFileName, directoryHint: .isDirectory)
        guard !exists(operation) else { throw DocsetReplacementError.recoveryRequired }
        let existing = try await registry.installed(sourceConfigurationID: target.sourceConfigurationID, sourceId: target.sourceId, familyId: target.familyId)
        guard existing == expected,
              existing?.installTarget?.slotKey == nil || existing?.installTarget?.slotKey == target.slotKey else {
            throw DocsetReplacementError.conflictingInstall
        }
        if target.sourceConfigurationID == nil,
           let byIdentifier = try await registry.installed(identifier: target.release.identifier), byIdentifier != existing {
            throw DocsetReplacementError.conflictingInstall
        }
        var journal = ReplacementJournal(id: UUID(), target: target, previous: existing, prepared: false)
        let destination = try destination(for: journal)
        if let existing {
            guard try parser.parse(bundleAt: destination).identified(as: existing.identifier) == existing.descriptor else { throw DocsetReplacementError.conflictingInstall }
        } else if exists(destination) { throw DocsetReplacementError.conflictingInstall }

        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: false)
        try save(journal, in: operation)
        do {
            let localArchive = operation.appending(path: "artifact.tgz")
            try await copyAndVerify(archive, to: localArchive, release: target.release)
            let candidateRoot = operation.appending(path: "candidate", directoryHint: .isDirectory)
            let candidate = try await installer.install(artifactAt: localArchive, into: candidateRoot,
                                                        expectedIdentifier: target.release.identifier)
            try target.validate(candidate)
            guard candidate.bundleURL.lastPathComponent == target.bundleName + ".docset" else { throw DocsetReplacementError.targetMismatch }
            try Task.checkCancellation()
            journal.prepared = true
            try save(journal, in: operation)
            if existing != nil {
                try FileManager.default.moveItem(at: destination, to: operation.appending(path: "previous.docset"))
            }
            try FileManager.default.moveItem(at: candidate.bundleURL, to: destination)
            let runtimeID = existing?.identifier ?? (target.sourceConfigurationID == nil ? target.release.identifier : UUID().uuidString.lowercased())
            let descriptor = try parser.parse(bundleAt: destination).identified(as: runtimeID)
            try target.validate(descriptor)
            try Task.checkCancellation()
            let installed = InstalledDocset(descriptor: descriptor, source: .catalog(name: target.familyId, sourceId: target.sourceId),
                                           advertisedVersion: target.release.advertisedVersion,
                                           selectionPolicy: target.selectionPolicy, installTarget: target,
                                           sourceConfigurationID: target.sourceConfigurationID, sourceName: sourceName ?? existing?.sourceName)
            try await registry.commitReplacement(installed, replacing: existing, transactionId: journal.id)
            // Once committed, cancellation cannot turn a successful install into
            // a failed one. Cleanup is retried at launch if it is interrupted.
            try? FileManager.default.removeItem(at: operation)
            return installed
        } catch {
            try await recover(journal, in: operation)
            throw error
        }
    }

    /// Call before scanning bundles or restoring queued transfers.
    public func recoverPending() async throws {
        let stateRoot = root.appending(path: ".crux-replacements", directoryHint: .isDirectory)
        guard exists(stateRoot) else { return }
        _ = try await prepareStateRoot()
        for operation in try FileManager.default.contentsOfDirectory(at: stateRoot, includingPropertiesForKeys: nil) {
            let name = operation.lastPathComponent
            guard ReleaseValidation.matches(name, "[0-9a-f]{64}") else { continue }
            let lock = try ReplacementFileLock(at: stateRoot.appending(path: name + ".lock"))
            defer { lock.close() }
            try requireDirectory(operation)
            let file = operation.appending(path: "journal.json")
            try requireRegular(file, maximumSize: 1_048_576)
            let journal = try JSONDecoder().decode(ReplacementJournal.self, from: Data(contentsOf: file))
            guard journal.schemaVersion == 1, journal.target.slotFileName == name else { throw DocsetReplacementError.unsafeState }
            try await recover(journal, in: operation)
        }
    }

    private func recover(_ journal: ReplacementJournal, in operation: URL) async throws {
        let destination = try destination(for: journal)
        let current = try await registry.installed(sourceConfigurationID: journal.target.sourceConfigurationID, sourceId: journal.target.sourceId, familyId: journal.target.familyId)
        if try await registry.hasReplacementCommit(journal.id) {
            guard current?.installTarget == journal.target,
                  try parser.parse(bundleAt: destination).identified(as: current!.identifier) == current?.descriptor else { throw DocsetReplacementError.unsafeState }
        } else {
            guard current == journal.previous else { throw DocsetReplacementError.unsafeState }
            let backup = operation.appending(path: "previous.docset")
            if exists(backup) {
                guard let previous = journal.previous, journal.prepared else { throw DocsetReplacementError.unsafeState }
                try previous.installTarget?.validate(parser.parse(bundleAt: backup))
                if exists(destination) {
                    try journal.target.validate(parser.parse(bundleAt: destination))
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: backup, to: destination)
            } else if let previous = journal.previous {
                guard try parser.parse(bundleAt: destination).identified(as: previous.identifier) == previous.descriptor else { throw DocsetReplacementError.unsafeState }
            } else if exists(destination) {
                guard journal.prepared else { throw DocsetReplacementError.unsafeState }
                try journal.target.validate(parser.parse(bundleAt: destination))
                try FileManager.default.removeItem(at: destination)
            }
        }
        try FileManager.default.removeItem(at: operation)
    }

    private func destination(for journal: ReplacementJournal) throws -> URL {
        try journal.target.validate()
        let destination = journal.previous?.descriptor.bundleURL
            ?? root.appending(path: "crux-\(journal.target.slotFileName).docset", directoryHint: .isDirectory)
        guard destination.standardizedFileURL.deletingLastPathComponent().path == root.path,
              destination.pathExtension == "docset",
              (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw DocsetReplacementError.unsafeState
        }
        if let previous = journal.previous {
            guard previous.installTarget?.slotKey == journal.target.slotKey,
                  previous.descriptor.bundleIdentifier == journal.target.release.identifier else { throw DocsetReplacementError.unsafeState }
            try previous.installTarget?.validate(previous.descriptor)
        }
        return destination
    }

    private func prepareStateRoot() async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try requireDirectory(root)
        // Different source slots may perform their first install concurrently.
        // Fence only state-root initialization; version replacement locks remain per slot.
        let deadline = ContinuousClock.now + .seconds(5)
        var initializationLock: ReplacementFileLock?
        while initializationLock == nil {
            try Task.checkCancellation()
            do { initializationLock = try ReplacementFileLock(at: root.appending(path: ".crux-replacements-init.lock")) }
            catch DocsetReplacementError.slotBusy {
                guard ContinuousClock.now < deadline else { throw DocsetReplacementError.slotBusy }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { initializationLock?.close() }
        let stateRoot = root.appending(path: ".crux-replacements", directoryHint: .isDirectory)
        let marker = stateRoot.appending(path: "owner.json")
        let owner = Data(#"{"owner":"crux-replacements","schemaVersion":1}"#.utf8)
        if exists(stateRoot) {
            try requireDirectory(stateRoot)
            try requireRegular(marker, maximumSize: 1024)
            guard try Data(contentsOf: marker) == owner else { throw DocsetReplacementError.unsafeState }
        } else {
            try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false)
            try owner.write(to: marker, options: .atomic)
        }
        return stateRoot
    }

    private func save(_ journal: ReplacementJournal, in operation: URL) throws {
        let file = operation.appending(path: "journal.json")
        try JSONEncoder().encode(journal).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// Own the input copy before hashing/extracting, so a changed download cannot
    /// be substituted between digest validation and extraction.
    private func copyAndVerify(_ source: URL, to destination: URL, release: DocsetRelease) async throws {
        try requireRegular(source, maximumSize: release.bytes)
        let worker = Task.detached(priority: .utility) {
            try FileManager.default.copyItem(at: source, to: destination)
            let input = try FileHandle(forReadingFrom: destination)
            defer { try? input.close() }
            var hash = SHA256(), count: Int64 = 0
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                count += Int64(chunk.count)
                guard count <= release.bytes else { throw DocsetReplacementError.artifactMismatch }
                hash.update(data: chunk)
            }
            guard count == release.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == release.sha256 else {
                throw DocsetReplacementError.artifactMismatch
            }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw DocsetReplacementError.unsafeState }
    }

    private func requireRegular(_ url: URL, maximumSize: Int64) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DocsetReplacementError.unsafeState }
        guard Int64(values.fileSize ?? 0) <= maximumSize else { throw DocsetReplacementError.artifactMismatch }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

private struct ReplacementJournal: Codable {
    var schemaVersion = 1
    let id: UUID
    let target: DocsetInstallTarget
    let previous: InstalledDocset?
    var prepared: Bool
}

/// Persistent lock files are never unlinked: unlinking can let another process
/// lock a new inode while the first process still holds the old one.
private final class ReplacementFileLock {
    private var descriptor: Int32
    init(at url: URL) throws {
        descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DocsetReplacementError.unsafeState }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw DocsetReplacementError.unsafeState
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw DocsetReplacementError.slotBusy
        }
    }
    func close() {
        if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}
