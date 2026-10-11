import Foundation

/// The network surface catalog and feed fetching need.
///
/// Keeping this as a protocol lets tests supply canned responses without
/// standing up a real HTTPS server.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Compatibility surface for callers that require an exclusively HTTPS destination.
/// Source-aware clients validate each hop through `SourceTransportPolicy` instead.
public enum HTTPSRedirectPolicy {
    public static func allows(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return (try? SourceTransportPolicy.strictHTTPS.validate(url)) != nil
    }
}

private final class TransportRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: SourceTransportPolicy
    private let lock = NSLock()
    private var failure: (any Error)?

    init(policy: SourceTransportPolicy) {
        self.policy = policy
    }

    var rejection: (any Error)? { lock.withLock { failure } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            guard let from = response.url, let to = request.url else { throw SourceTransportError.invalidURL }
            try policy.validateRedirect(from: from, to: to)
            completionHandler(request)
        } catch {
            lock.withLock { failure = error }
            completionHandler(nil)
            task.cancel()
        }
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let transportPolicy: SourceTransportPolicy

    public init(session: URLSession = .shared, transportPolicy: SourceTransportPolicy = .strictHTTPS) {
        self.session = session
        self.transportPolicy = transportPolicy
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let originalURL = request.url else { throw SourceTransportError.invalidURL }
        try transportPolicy.validate(originalURL)
        let delegate = TransportRedirectDelegate(policy: transportPolicy)
        do {
            let result = try await session.data(for: request, delegate: delegate)
            if let rejection = delegate.rejection { throw rejection }
            guard let finalURL = result.1.url else { throw SourceTransportError.invalidURL }
            try transportPolicy.validateRedirect(from: originalURL, to: finalURL)
            return result
        } catch {
            throw delegate.rejection ?? error
        }
    }
}

/// Copies a remote file to disk while reporting byte progress.
public protocol DownloadClient: Sendable {
    func download(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws

    func download(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void,
        transportPolicy: SourceTransportPolicy
    ) async throws
}

public extension DownloadClient {
    /// Keeps clients implementing only the original trailing-closure API source compatible.
    func download(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void,
        transportPolicy: SourceTransportPolicy
    ) async throws {
        try transportPolicy.validate(url)
        try await download(from: url, to: destinationURL, progress: progress)
    }
}

/// A download client built on `URLSession` download tasks.
///
/// Requests use a foreground session because background URLSession tasks follow
/// redirects without asking their delegate. Accepting a background configuration
/// preserves the factory API without creating a competing session identifier;
/// these policy-controlled tasks do not survive process termination.
public final class URLSessionDownloadClient: NSObject, DownloadClient, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private struct Waiter {
        let originalURL: URL
        let transportPolicy: SourceTransportPolicy
        let destinationURL: URL
        let progress: @Sendable (Int64, Int64?) -> Void
        let continuation: CheckedContinuation<Void, any Error>
        var rejection: (any Error)?
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]
    private let transportPolicy: SourceTransportPolicy
    /// Assigned after `super.init()` because the session needs this object as its delegate.
    private var session: URLSession!

    public init(configuration: URLSessionConfiguration, transportPolicy: SourceTransportPolicy = .strictHTTPS) {
        self.transportPolicy = transportPolicy
        let controlledConfiguration: URLSessionConfiguration
        if configuration.identifier != nil {
            controlledConfiguration = .ephemeral
            controlledConfiguration.timeoutIntervalForRequest = configuration.timeoutIntervalForRequest
            controlledConfiguration.timeoutIntervalForResource = configuration.timeoutIntervalForResource
            controlledConfiguration.httpAdditionalHeaders = configuration.httpAdditionalHeaders
            controlledConfiguration.httpMaximumConnectionsPerHost = configuration.httpMaximumConnectionsPerHost
            controlledConfiguration.allowsCellularAccess = configuration.allowsCellularAccess
            controlledConfiguration.allowsExpensiveNetworkAccess = configuration.allowsExpensiveNetworkAccess
            controlledConfiguration.allowsConstrainedNetworkAccess = configuration.allowsConstrainedNetworkAccess
            controlledConfiguration.connectionProxyDictionary = configuration.connectionProxyDictionary
        } else {
            controlledConfiguration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        }
        controlledConfiguration.waitsForConnectivity = true
        super.init()
        session = URLSession(configuration: controlledConfiguration, delegate: self, delegateQueue: nil)
    }

    /// Legacy factory. See the foreground-session constraint above.
    public static func background(
        identifier: String = "com.zacharyhuo.Crux.docset-downloads",
        transportPolicy: SourceTransportPolicy = .strictHTTPS
    ) -> URLSessionDownloadClient {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        // Launch events would relaunch Crux without activating its windows, which
        // breaks UI tests and ordinary clicks. Mid-flight jobs already fail clearly
        // on the next launch via TransferQueue.restorePersistedJobs().
        configuration.sessionSendsLaunchEvents = false
        return URLSessionDownloadClient(configuration: configuration, transportPolicy: transportPolicy)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func download(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        try await download(from: url, to: destinationURL, progress: progress, transportPolicy: transportPolicy)
    }

    public func download(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void,
        transportPolicy: SourceTransportPolicy
    ) async throws {
        try transportPolicy.validate(url)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let cancellation = DownloadTaskCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = session.downloadTask(with: request)
                lock.withLock {
                    waiters[task.taskIdentifier] = Waiter(
                        originalURL: url,
                        transportPolicy: transportPolicy,
                        destinationURL: destinationURL,
                        progress: progress,
                        continuation: continuation,
                        rejection: nil
                    )
                }
                cancellation.register(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let progress = lock.withLock { waiters[downloadTask.taskIdentifier]?.progress }
        progress?(totalBytesWritten, expected)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let waiter = lock.withLock({ waiters[task.taskIdentifier] }) else {
            completionHandler(nil)
            task.cancel()
            return
        }
        do {
            guard let from = response.url, let to = request.url else { throw SourceTransportError.invalidURL }
            try waiter.transportPolicy.validateRedirect(from: from, to: to)
            completionHandler(request)
        } catch {
            lock.withLock { waiters[task.taskIdentifier]?.rejection = error }
            completionHandler(nil)
            task.cancel()
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let waiter = lock.withLock { waiters.removeValue(forKey: downloadTask.taskIdentifier) }
        guard let waiter else { return }
        do {
            if let rejection = waiter.rejection { throw rejection }
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw TransferError.installFailed("The download server returned an invalid HTTP response.")
            }
            guard let responseURL = response.url else {
                throw TransferError.installFailed("The download response did not include a final URL.")
            }
            try waiter.transportPolicy.validateRedirect(from: waiter.originalURL, to: responseURL)
            // The session deletes `location` when this method returns, so the
            // bytes have to be copied before we hand control back.
            if FileManager.default.fileExists(atPath: waiter.destinationURL.path) {
                try FileManager.default.removeItem(at: waiter.destinationURL)
            }
            try FileManager.default.copyItem(at: location, to: waiter.destinationURL)
            waiter.continuation.resume()
        } catch {
            waiter.continuation.resume(throwing: error)
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        let waiter = lock.withLock { waiters.removeValue(forKey: task.taskIdentifier) }
        guard let waiter else { return }
        if let rejection = waiter.rejection {
            waiter.continuation.resume(throwing: rejection)
        } else if (error as NSError).code == NSURLErrorCancelled {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            waiter.continuation.resume(throwing: error)
        }
    }
}

/// Cancels this invocation's task, including cancellation before it was registered.
private final class DownloadTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func register(_ task: URLSessionTask) {
        let shouldCancel = lock.withLock {
            self.task = task
            return isCancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}
