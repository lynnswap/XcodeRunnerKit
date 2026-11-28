import Foundation
import XcodeRunnerHostApp

/// A local Actions service for the separate-process host checks. Only the fixture executable links this transport.
@main
struct RunnerHostProbe {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        let home: URL
        if let index = arguments.firstIndex(of: "--home-directory"), arguments.indices.contains(index + 1) {
            home = URL(filePath: arguments[index + 1])
        } else {
            home = .homeDirectory
        }
        let actions = Actions(home: home)
        RunnerHostApplication.main(authorization: { repository, id, access in
            guard !FileManager.default.fileExists(atPath: home.appending(path: "disconnected").path) else {
                try Data().write(to: home.appending(path: "denied-\(id)"))
                throw CocoaError(.userCancelled)
            }
            return access == .connect ? .init(repository: repository, registrationToken: String(id), labels: ["fixture"]) : nil
        }, transport: { try await actions.send($0) })
    }
}

private actor Actions {
    let home: URL
    private var delivered: Set<Int> = []

    init(home: URL) { self.home = home }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let parts = url.pathComponents
        let response: Any
        var status = 200
        if parts.last == "runner-registration" {
            let id = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst("RemoteAuth ".count))
            response = ["url": "https://fixture.invalid/" + id, "token": "admin"]
        } else {
            guard parts.count >= 3, let id = Int(parts[1]) else { throw URLError(.badURL) }
            let roots = home.appending(path: "Library/XcodeRunnerKit/runners")
            let folder = try FileManager.default.contentsOfDirectory(at: roots, includingPropertiesForKeys: nil).first { folder in
                guard let data = try? Data(contentsOf: folder.appending(path: ".runner")),
                      let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return settings["agentId"] as? Int == id
            }
            switch (request.httpMethod, parts.last) {
            case ("GET", "runnerscalesets"): response = ["value": []]
            case ("POST", "runnerscalesets"): response = ["id": id, "labels": [["name": "fixture", "type": "System"]]]
            case ("POST", "sessions"):
                delivered.remove(id)
                if let folder { try Data().write(to: folder.appending(path: "subscribed")) }
                response = ["sessionId": UUID().uuidString, "messageQueueUrl": "https://fixture.invalid/\(id)/messages",
                            "messageQueueAccessToken": "queue", "statistics": ["totalAssignedJobs": 0]]
            case ("PATCH", _) where parts.contains("sessions"):
                response = ["sessionId": parts.last!, "messageQueueUrl": "https://fixture.invalid/\(id)/messages",
                            "messageQueueAccessToken": "renewed-queue", "statistics": ["totalAssignedJobs": 0]]
            case ("GET", "messages"):
                guard let folder else { throw CocoaError(.fileNoSuchFile) }
                if FileManager.default.fileExists(atPath: folder.appending(path: "expire-credentials").path),
                   request.value(forHTTPHeaderField: "Authorization") == "Bearer queue" {
                    return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                }
                if delivered.contains(id), let capacity = request.value(forHTTPHeaderField: "X-ScaleSetMaxCapacity") {
                    try Data(capacity.utf8).write(to: folder.appending(path: "capacity-after-offer"), options: .atomic)
                }
                if delivered.contains(id) || FileManager.default.fileExists(atPath: folder.appending(path: "no-work").path) {
                    try await Task.sleep(for: .milliseconds(100))
                    return (Data(), HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!)
                }
                delivered.insert(id)
                let assigned = FileManager.default.fileExists(atPath: folder.appending(path: "assigned").path)
                let type = assigned ? "JobAssigned" : "JobAvailable"
                response = ["messageId": 1, "body": "[{\"messageType\":\"\(type)\",\"runnerRequestId\":\(id)}]",
                            "statistics": ["totalAssignedJobs": assigned ? 1 : 0]]
            case ("POST", "acquirejobs"):
                if let folder { try Data().write(to: folder.appending(path: "acquired")) }
                response = ["value": [id]]
            case ("POST", "generatejitconfig"):
                guard let folder else { throw CocoaError(.fileNoSuchFile) }
                let expiry = folder.appending(path: "expire-credentials")
                if FileManager.default.fileExists(atPath: expiry.path) {
                    try FileManager.default.removeItem(at: expiry)
                    return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                }
                try Data().write(to: folder.appending(path: "provisioned"))
                response = ["encodedJITConfig": folder.path, "runner": ["id": id]]
            case ("DELETE", _) where parts.contains("messages") || parts.contains("sessions")
                || Array(parts.dropLast().suffix(5)) == ["_apis", "distributedtask", "pools", "0", "agents"]:
                response = [:]
                status = 204
            default: throw URLError(.unsupportedURL)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: response)
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
