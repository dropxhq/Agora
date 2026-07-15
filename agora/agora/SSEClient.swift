import Foundation

struct ServerResponseError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum ServerErrorMessage {
    static func parse(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parse(from: object)
    }

    static func parse(from payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return parse(from: object)
    }

    private static func parse(from object: [String: Any]) -> String? {
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }

        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let data = error["data"] as? String, !data.isEmpty {
                return parse(from: data) ?? data
            }
        }

        if let content = object["content"] as? String, !content.isEmpty {
            return content
        }

        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }

        if let status = object["status"] as? [String: Any],
           let message = extractStatusMessage(from: status) {
            return message
        }

        if let result = object["result"] as? [String: Any] {
            if let statusUpdate = result["statusUpdate"] as? [String: Any],
               let status = statusUpdate["status"] as? [String: Any],
               let message = extractStatusMessage(from: status) {
                return message
            }
        }

        return nil
    }

    static func extractStatusMessage(from status: [String: Any]) -> String? {
        guard let message = status["message"] as? [String: Any],
              let parts = message["parts"] as? [[String: Any]] else {
            return nil
        }

        for part in parts {
            if let text = part["text"] as? String, !text.isEmpty {
                return text
            }
            if let data = part["data"] as? [String: Any] {
                if let error = data["error"] as? String, !error.isEmpty {
                    return error
                }
                if data["message_type"] as? String == "error" {
                    if let inner = data["data"] as? String, !inner.isEmpty {
                        return parse(from: inner) ?? inner
                    }
                }
            }
        }
        return nil
    }
}

struct SSEClient {
    /// Legacy URLSession SSE transport. Prefer `A2AClient` (Rust/UniFFI via AgoraA2A).
    static func stream(request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }

                    var dataBuffer = ""
                    var rawLines: [String] = []
                    var yieldedAny = false

                    for try await line in bytes.lines {
                        rawLines.append(line)
                        if line.hasPrefix("data:") {
                            if !dataBuffer.isEmpty {
                                continuation.yield(dataBuffer)
                                yieldedAny = true
                            }
                            dataBuffer = String(line.dropFirst(5)).trimmingCharacters(in: .init(charactersIn: " "))
                        } else if line.isEmpty, !dataBuffer.isEmpty {
                            continuation.yield(dataBuffer)
                            yieldedAny = true
                            dataBuffer = ""
                        }
                    }

                    if !dataBuffer.isEmpty {
                        continuation.yield(dataBuffer)
                        yieldedAny = true
                    }

                    let body = rawLines.joined(separator: "\n")
                    if !(200..<300).contains(http.statusCode) {
                        let message = ServerErrorMessage.parse(from: body) ?? "HTTP \(http.statusCode)"
                        continuation.finish(throwing: ServerResponseError(message: message))
                        return
                    }

                    if !yieldedAny, let message = ServerErrorMessage.parse(from: body) {
                        continuation.finish(throwing: ServerResponseError(message: message))
                        return
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
