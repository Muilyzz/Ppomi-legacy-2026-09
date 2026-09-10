// One model call for Tools' categorize / advise, through the agent server's /v1/responses (the key lives there, like the chat),
// and the ToolSpec the MCP server publishes. Nothing here holds an API key.
import Foundation

struct ToolSpec {
    let name, description: String
    var params: [String: (type: String, description: String?)] = [:]
    var required: [String] = []

    var json: [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
            "parameters": ["type": "object", "required": required,
                           "properties": params.mapValues { v -> [String: String] in var d = ["type": v.type]; if let s = v.description { d["description"] = s }; return d }]]]
    }
}

enum Chat {
    struct Failure: LocalizedError, CustomStringConvertible { let description: String; var errorDescription: String? { description } }

    /// 에이전트 서버 주소: 설정값이 있으면 그것, 없으면 상수(아이패드와 같음).
    static var endpoint: String { UserDefaults.standard.string(forKey: AgentNativePolicy.endpointPreference) ?? PpomiServer.agentEndpoint }

    private static func usageLine(_ model: String, _ tokens: (Int, Int)) -> String { "\(model) 입력 \(tokens.0) / 출력 \(tokens.1) 토큰" }

    /// system + user → (text, usage line). 모델은 서버가 고른다(`model` 인자는 호환용). Full reasoning (the weekly review wants it).
    static func complete(system: String, user: String, model: String? = nil, maxTokens: Int = 2000) throws -> (String, String) {
        let response: [String: Any]
        do {
            guard let value = try SharedServerClient.shared.agentRequest(endpoint: endpoint, path: "/v1/responses",
                                                                        body: ["instructions": system, "input": user, "max_output_tokens": maxTokens]) as? [String: Any]
            else { throw Failure(description: "bad response") }
            response = value
        } catch let failure as Failure { throw failure }
        catch { throw Failure(description: "에이전트 서버: " + SharedServerClient.safe(error).description) }
        let usage = response["usage"] as? [String: Any] ?? [:]
        return (outputText(response).trimmingCharacters(in: .whitespacesAndNewlines),
                usageLine(response["model"] as? String ?? "server", (usage["input_tokens"] as? Int ?? 0, usage["output_tokens"] as? Int ?? 0)))
    }
    /// Responses API: output[].content[] 의 output_text 를 잇는다.
    static func outputText(_ response: [String: Any]) -> String {
        ((response["output"] as? [[String: Any]]) ?? []).flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }.joined()
    }
}
