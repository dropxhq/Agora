import Foundation

struct SSEClient {
    static func stream(request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }
                    var dataBuffer = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("data:") {
                            dataBuffer = String(line.dropFirst(5)).trimmingCharacters(in: .init(charactersIn: " "))
                        } else if line.isEmpty, !dataBuffer.isEmpty {
                            continuation.yield(dataBuffer)
                            dataBuffer = ""
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
