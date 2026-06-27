import Foundation

class A2AClient {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Send a message and return streaming SSE events
    func sendStreamingMessage(text: String, contextId: String? = nil) -> AsyncThrowingStream<String, Error> {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "tasks/sendSubscribe",
            "id": UUID().uuidString,
            "params": [
                "message": [
                    "role": "user",
                    "parts": [["text": text]]
                ],
                "contextId": contextId as Any
            ]
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent(""))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return SSEClient.stream(request: req)
    }

    /// Fetch current task state (for re-sync after background)
    func getTask(taskId: String) async throws -> TaskStatus {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "tasks/get",
            "id": UUID().uuidString,
            "params": ["id": taskId]
        ]
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(JSONRPCResponse<TaskStatusResult>.self, from: data)
        return resp.result.status
    }
}

private struct JSONRPCResponse<T: Decodable>: Decodable {
    let result: T
}
private struct TaskStatusResult: Decodable {
    let status: TaskStatus
}
