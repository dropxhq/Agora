import Foundation
import AgoraA2A

class A2AClient {
    static let protocolVersion = "1.0"

    let baseURL: URL
    let requestHeaders: [String: String]
    let messageMetadata: [String: Any]?

    private lazy var session: A2aSession = {
        let metadataJSON: String?
        if let messageMetadata,
           JSONSerialization.isValidJSONObject(messageMetadata),
           let data = try? JSONSerialization.data(withJSONObject: messageMetadata),
           let string = String(data: data, encoding: .utf8) {
            metadataJSON = string
        } else {
            metadataJSON = nil
        }
        return try! A2aSession(
            baseUrl: baseURL.serverOrigin.absoluteString,
            requestHeaders: requestHeaders,
            messageMetadataJson: metadataJSON
        )
    }()

    init(
        baseURL: URL,
        requestHeaders: [String: String] = [:],
        messageMetadata: [String: Any]? = nil
    ) {
        self.baseURL = baseURL
        self.requestHeaders = requestHeaders
        self.messageMetadata = messageMetadata
    }

    /// Send a message and return streaming events as JSON strings for ConversationVM.apply.
    func sendStreamingMessage(text: String, contextId: String? = nil) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let observer = StreamContinuationObserver(continuation: continuation)
            let handle = session.startStream(text: text, contextId: contextId, observer: observer)
            continuation.onTermination = { @Sendable _ in
                handle.cancel()
            }
        }
    }

    /// Fetch current task state (for re-sync after background).
    func getTask(taskId: String) async throws -> TaskStatus {
        let json = try await session.getTask(taskId: taskId)
        guard let data = json.data(using: .utf8) else {
            throw A2AClientError.message("Invalid UTF-8 in getTask response")
        }
        return try JSONDecoder().decode(GetTaskResult.self, from: data).status
    }

    /// Fetch agent card from the official A2A well-known path on the server origin.
    func fetchAgentCard() async throws -> AgentCard {
        let json = try await session.fetchAgentCard()
        guard let data = json.data(using: .utf8) else {
            throw A2AClientError.message("Invalid UTF-8 in agent card response")
        }
        let card = try JSONDecoder().decode(AgentCard.self, from: data)
        return card.rewritingLocalHost(with: baseURL.serverOrigin.host)
    }
}

private final class StreamContinuationObserver: StreamObserver, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func onEvent(json: String) {
        continuation.yield(json)
    }

    func onComplete() {
        continuation.finish()
    }

    func onError(message: String) {
        continuation.finish(throwing: A2AClientError.message(message))
    }
}

enum A2AClientError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private extension URL {
    /// Scheme + host + port, stripping any JSONRPC path suffix from the configured Server URL.
    var serverOrigin: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        return components.url ?? self
    }
}

private struct GetTaskResult: Decodable {
    let status: TaskStatus
}
