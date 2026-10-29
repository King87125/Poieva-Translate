import Foundation

private final class RejectServiceRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One cancellable request per provider. No redirects, cookies, persistent cache or raw error bodies.
@MainActor
final class TranslationHTTPClient {
    private let session: URLSession
    private let ownsSession: Bool
    private var task: Task<Data, Error>?
    private var revision = UUID()

    init(session: URLSession? = nil) {
        if let session { self.session = session; ownsSession = false }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.urlCache = nil; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
            settings.requestCachePolicy = .reloadIgnoringLocalCacheData
            settings.timeoutIntervalForRequest = 30; settings.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: settings, delegate: RejectServiceRedirects(), delegateQueue: nil)
            ownsSession = true
        }
    }
    deinit { task?.cancel(); if ownsSession { session.invalidateAndCancel() } }
    func send(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        cancel()
        let id = UUID(); revision = id
        let session = self.session
        let operation = Task<Data, Error> {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw RemoteTranslationFailure.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw RemoteTranslationFailure.status(response.statusCode) }
            guard data.count <= 1_048_576 else { throw RemoteTranslationFailure.tooLarge }
            return data
        }
        task = operation
        defer { if revision == id { task = nil } }
        do {
            let data = try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
            try Task.checkCancellation()
            guard revision == id else { throw CancellationError() }
            return data
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw RemoteTranslationFailure.timeout }
            throw RemoteTranslationFailure.connection
        }
    }
    func cancel() { task?.cancel(); task = nil; revision = UUID() }
}
