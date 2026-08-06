import Foundation

/// Small process-wide HTTP client with explicit timeouts, bounded connection
/// fan-out and a hard response-body cap. The SDK must not inherit an embedding
/// app's URLSession configuration or buffer an arbitrarily large response.
final class BoundedHTTPClient: NSObject, URLSessionDataDelegate {
    typealias Completion = (_ status: Int?, _ data: Data?) -> Void

    private final class TaskState {
        var status: Int?
        var data = Data()
        var exceededLimit = false
        let completion: Completion

        init(completion: @escaping Completion) {
            self.completion = completion
        }
    }

    private let maxResponseBytes: Int
    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private let delegateQueue: OperationQueue = {
        let value = OperationQueue()
        value.name = "com.trackhub.sdk.http"
        value.maxConcurrentOperationCount = 1
        return value
    }()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
    }()

    init(maxResponseBytes: Int = 64 * 1024) {
        self.maxResponseBytes = max(1, maxResponseBytes)
        super.init()
    }

    func data(for request: URLRequest, completion: @escaping Completion) {
        let task = session.dataTask(with: request)
        lock.lock()
        states[task.taskIdentifier] = TaskState(completion: completion)
        lock.unlock()
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let expected = response.expectedContentLength
        lock.lock()
        let state = states[dataTask.taskIdentifier]
        state?.status = (response as? HTTPURLResponse)?.statusCode
        if expected > Int64(maxResponseBytes) { state?.exceededLimit = true }
        let exceeded = state?.exceededLimit == true
        lock.unlock()
        completionHandler(exceeded ? .cancel : .allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var shouldCancel = false
        lock.lock()
        if let state = states[dataTask.taskIdentifier] {
            if state.data.count + data.count > maxResponseBytes {
                state.exceededLimit = true
                shouldCancel = true
            } else {
                state.data.append(data)
            }
        }
        lock.unlock()
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }
        let data = state.exceededLimit ? nil : state.data
        state.completion(state.status, data)
    }
}
