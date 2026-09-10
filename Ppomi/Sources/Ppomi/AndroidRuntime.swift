import Foundation

/// The Mac transports requests; the companion's AccessibilityService performs Android input.
/// This first version deliberately targets an explicitly paired emulator, never the first attached phone.
enum AndroidRuntime {
    struct Failure: Error, CustomStringConvertible, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }
    struct Configuration: Codable {
        let serial: String
        let port: Int
        let token: String

        func validate() throws {
            guard serial.range(of: #"^emulator-[0-9]+$"#, options: .regularExpression) != nil,
                  (1024...65535).contains(port), token.count >= 32,
                  token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
                throw Failure(description: "Android 에뮬레이터 연결 설정이 올바르지 않습니다. scripts/android-bridge.py prepare를 실행하세요.")
            }
        }
    }

    static var configurationURL: URL { Phone.root.appendingPathComponent(".ppomi/android-bridge.json") }
    static func configuration() throws -> Configuration {
        guard let data = try? Data(contentsOf: configurationURL),
              let config = try? JSONDecoder().decode(Configuration.self, from: data) else {
            throw Failure(description: "Android 연결이 없습니다. Android 탭에서 실행하거나 scripts/android-bridge.py prepare를 실행하세요.")
        }
        try config.validate()
        return config
    }

    @MainActor static func launchMirror() async throws {
        let script = Phone.root.appendingPathComponent("scripts/android-bridge.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw Failure(description: "Android 개발 도구가 없습니다. 프로젝트의 scripts/android-bridge.py가 필요합니다.")
        }
        try await Task.detached(priority: .userInitiated) {
            _ = try process("/usr/bin/python3", [script.path, "start"], timeout: 600)
        }.value
    }

    static var adbURL: URL? {
        let env = ProcessInfo.processInfo.environment
        let roots = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"],
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path].compactMap { $0 }
        return (roots.map { URL(fileURLWithPath: $0).appendingPathComponent("platform-tools/adb") }
                + [URL(fileURLWithPath: "/opt/homebrew/bin/adb"), URL(fileURLWithPath: "/usr/local/bin/adb")])
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func ensureForward(_ config: Configuration) throws {
        try config.validate()
        guard let adb = adbURL else { throw Failure(description: "Android SDK의 adb를 찾을 수 없습니다.") }
        // -s is mandatory: no device-selection fallback and no input through adb.
        _ = try process(adb.path, ["-s", config.serial, "forward", "tcp:\(config.port)", "tcp:8765"])
    }

    static func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let config = try configuration()
        try ensureForward(config)
        let id = UUID().uuidString
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)/mcp")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
            "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let reply = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request) { data, response, error in
            reply.value = (data, response as? HTTPURLResponse, error)
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + 17) == .success else {
            task.cancel(); throw Failure(description: "Android 앱 응답 시간이 초과됐습니다. Android 탭에서 다시 실행하세요.")
        }
        let (data, response, error) = reply.value
        guard error == nil, let data, let response else {
            throw Failure(description: "Android MCP 앱에 연결할 수 없습니다. 에뮬레이터와 접근성 서비스가 켜져 있는지 확인하세요.")
        }
        guard response.statusCode == 200 else {
            throw Failure(description: "Android MCP 연결 실패 (HTTP \(response.statusCode)). Android 탭에서 다시 실행하세요.")
        }
        return try decodeReply(data, expectedID: id)
    }

    static func decodeReply(_ data: Data, expectedID: String) throws -> [String: Any] {
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["jsonrpc"] as? String == "2.0", reply["id"] as? String == expectedID else {
            throw Failure(description: "Android MCP 응답 형식이 올바르지 않습니다.")
        }
        if let error = reply["error"] as? [String: Any] {
            throw Failure(description: "Android: \(error["message"] as? String ?? "요청 실패")")
        }
        guard let result = reply["result"] as? [String: Any] else {
            throw Failure(description: "Android MCP 응답 결과가 없습니다.")
        }
        if result["isError"] as? Bool == true {
            let message = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            throw Failure(description: "Android: \(message ?? "제어 실패")")
        }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        guard let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String,
              let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Failure(description: "Android MCP 구조화 결과가 없습니다.")
        }
        return payload
    }

    static func capture() throws -> URL {
        let config = try configuration()
        guard let adb = adbURL else { throw Failure(description: "Android SDK의 adb를 찾을 수 없습니다.") }
        let bytes = try process(adb.path, ["-s", config.serial, "exec-out", "screencap", "-p"])
        guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw Failure(description: "Android 화면 캡처가 PNG가 아닙니다.")
        }
        let dir = Phone.shots.appendingPathComponent("android")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".png")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Temporary files avoid full-pipe deadlocks; timeout covers stalled emulator/SDK processes.
    static func process(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-android-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let output = temp.appendingPathComponent("out"), errors = temp.appendingPathComponent("err")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = out; process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 2) != .success { kill(process.processIdentifier, SIGKILL) }
            throw Failure(description: "Android 명령 응답 시간이 초과됐습니다.")
        }
        guard process.terminationStatus == 0 else {
            let detail = String(data: (try? Data(contentsOf: errors)) ?? Data(), encoding: .utf8) ?? ""
            throw Failure(description: "Android: " + String(detail.suffix(1500)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try Data(contentsOf: output)
    }

    private final class ReplyBox: @unchecked Sendable {
        var value: (Data?, HTTPURLResponse?, Error?) = (nil, nil, nil)
    }
}
