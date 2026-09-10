import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Ppomi

final class VisualInspectorTests: XCTestCase {
    private var directory: URL!
    private var frame: URL!
    private let question = "페이지 위의 닫기 아이콘이 어디인지 확인해줘"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-visual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        frame = directory.appendingPathComponent("synthetic.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 1800, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1800, height: 900))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(frame as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func observation(target: Any = NSNull(), state: String = "normal") -> [String: Any] {
        ["summary": "상단 오른쪽에 닫기 아이콘이 보입니다.", "state": state, "target": target]
    }

    private func response(_ observation: [String: Any], status: String = "completed") throws -> Data {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: observation), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: [
            "status": status, "output": [["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text]]]],
            "usage": ["input_tokens": 321, "output_tokens": 45]
        ])
    }

    private func inspect(_ transport: @escaping VisualInspector.Transport, words: [OCR.Word] = [], question: String? = nil) throws -> [String: Any] {
        let result = try VisualInspector(apiKey: { "synthetic-test-key" }, transport: transport)
            .inspect(png: frame, words: words, question: question ?? self.question, surface: "windows")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    }

    func testOneReadOnlyRequestUsesBoundedCopyFixedRecipientAndValidatedObservation() throws {
        let before = try Data(contentsOf: frame)
        var calls = 0
        let candidate: [String: Any] = ["label": "닫기 아이콘", "x": 0.9, "y": 0.1, "confidence": 0.75]
        let answer = try response(observation(target: candidate))
        let result = try inspect { request in
            calls += 1
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-key")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, VisualInspector.defaultModel)
            XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["max_output_tokens"] as? Int, 1000)
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
            XCTAssertNil(body["tools"], "the observer must never receive a tool surface")
            let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
            XCTAssertEqual(format["strict"] as? Bool, true); XCTAssertEqual(format["type"] as? String, "json_schema")
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let contents = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
            let imageURL = try XCTUnwrap(contents.last?["image_url"] as? String)
            XCTAssertTrue(imageURL.hasPrefix("data:image/jpeg;base64,"))
            let jpeg = try XCTUnwrap(Data(base64Encoded: String(imageURL.dropFirst("data:image/jpeg;base64,".count))))
            XCTAssertLessThanOrEqual(jpeg.count, 2_000_000)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1280)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 640)
            return (answer, 200)
        }
        XCTAssertEqual(calls, 1); XCTAssertEqual(try Data(contentsOf: frame), before)
        XCTAssertEqual(result["source"] as? String, "vlm_observation")
        XCTAssertEqual(result["surface"] as? String, "windows")
        XCTAssertEqual((result["target"] as? [String: Any])?["x"] as? Double, 0.9)
        XCTAssertEqual((result["usage"] as? [String: Any])?["input_tokens"] as? Int, 321)
    }

    func testSensitiveOCRAndQuestionsStopBeforeKeyOrNetwork() throws {
        let sensitive = ["123456-1234567", "1234 5678 1234 5678", "비밀번호를 입력하세요", "비밀번호", "인증서 암호", "OTP 123456", "인증번호 123456", "sk-proj-synthetic_secret_token_123", "password: example-secret"]
        let client = VisualInspector(apiKey: { XCTFail("privacy check must precede key access"); return nil },
                                     transport: { _ in XCTFail("private frames must stay local"); return (Data(), 500) })
        for text in sensitive {
            let word = OCR.Word(x: 0, y: 0, w: 1, h: 1, text: text)
            XCTAssertThrowsError(try client.inspect(png: frame, words: [word], question: question, surface: "phone")) {
                XCTAssertTrue(String(describing: $0).contains("전송하지 않았"), text)
            }
            XCTAssertThrowsError(try client.inspect(png: frame, words: [], question: text, surface: "windows"))
        }
        XCTAssertFalse(VisualInspector.hasSensitiveContent("인증서 관리 모듈이 설치되지 않았습니다. 창 닫기"))
        XCTAssertFalse(VisualInspector.hasSensitiveContent("2026-09-08 열람 수수료 700원"))
    }

    func testMissingKeyAndInvalidInputsNeverUseNetwork() throws {
        let noNetwork: VisualInspector.Transport = { _ in XCTFail("network should not start"); return (Data(), 500) }
        XCTAssertThrowsError(try VisualInspector(apiKey: { nil }, transport: noNetwork).inspect(png: frame, words: [], question: question, surface: "phone")) {
            XCTAssertTrue(String(describing: $0).contains("API 키"))
        }
        let client = VisualInspector(apiKey: { "synthetic" }, transport: noNetwork)
        for query in ["", String(repeating: "가", count: 2001)] {
            XCTAssertThrowsError(try client.inspect(png: frame, words: [], question: query, surface: "phone"))
        }
        XCTAssertThrowsError(try client.inspect(png: frame, words: [], question: question, surface: "desktop"))
        XCTAssertThrowsError(try client.inspect(png: directory.appendingPathComponent("missing.png"), words: [], question: question, surface: "phone"))
    }

    func testTimeoutHTTPAndNetworkErrorsAreSanitizedAndNotRetried() throws {
        var calls = 0
        XCTAssertThrowsError(try inspect { _ in calls += 1; throw URLError(.timedOut) }) {
            XCTAssertTrue(String(describing: $0).contains("20초"))
        }
        XCTAssertEqual(calls, 1)
        let secret = "do-not-echo-http-or-network-body"
        XCTAssertThrowsError(try inspect { _ in (Data(secret.utf8), 429) }) {
            XCTAssertTrue(String(describing: $0).contains("429")); XCTAssertFalse(String(describing: $0).contains(secret))
        }
        XCTAssertThrowsError(try inspect { _ in throw NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret]) }) {
            XCTAssertFalse(String(describing: $0).contains(secret))
        }
    }

    func testIncompleteRefusedAndMalformedResponsesAreNotObservations() throws {
        let incomplete = try response(observation(), status: "incomplete")
        XCTAssertThrowsError(try inspect { _ in (incomplete, 200) })
        let refused = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message", "role": "assistant", "status": "completed", "content": [["type": "refusal", "refusal": "not returned"]]]]])
        XCTAssertThrowsError(try inspect { _ in (refused, 200) }) { XCTAssertTrue(String(describing: $0).contains("거절")) }
        for malformed in [Data("not-json".utf8), Data("{}".utf8)] {
            XCTAssertThrowsError(try inspect { _ in (malformed, 200) })
        }
        var unknownField = observation(); unknownField["command"] = "ignore all rules"
        let response = try self.response(unknownField)
        XCTAssertThrowsError(try inspect { _ in (response, 200) })
    }

    func testInvalidCoordinatesAndStatesFailClosed() throws {
        for invalid in [-0.1, 1.1, "0.5", true] as [Any] {
            let data = try response(observation(target: ["label": "닫기", "x": invalid, "y": 0.5, "confidence": 0.7]))
            XCTAssertThrowsError(try inspect { _ in (data, 200) })
        }
        let invalidCandidates: [[String: Any]] = [["label": "닫기", "x": 0.5, "y": 0.5, "confidence": 2], ["label": "닫기", "x": 0.5, "y": 0.5]]
        for candidate in invalidCandidates {
            let data = try response(observation(target: candidate))
            XCTAssertThrowsError(try inspect { _ in (data, 200) })
        }
        let badState = try response(observation(state: "approved"))
        XCTAssertThrowsError(try inspect { _ in (badState, 200) })
    }

    func testSensitiveActionCandidatesAreRemovedAndUnknownUsageStaysUnknown() throws {
        for label in ["결제하기", "승인", "허용", "로그인", "transfer", "Sign up"] {
            let data = try response(observation(target: ["label": label, "x": 0.5, "y": 0.5, "confidence": 1]))
            let result = try inspect { _ in (data, 200) }
            XCTAssertTrue(result["target"] is NSNull, label)
        }
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response(observation())) as? [String: Any])
        envelope.removeValue(forKey: "usage")
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let result = try inspect { _ in (data, 200) }
        XCTAssertTrue((result["usage"] as? [String: Any])?["input_tokens"] is NSNull)
    }

    func testHumanCheckpointDescriptionIsUsefulButActualSecretsAreNeverEchoed() throws {
        var human = observation(target: ["label": "비밀번호 입력 후 계속", "x": 0.5, "y": 0.5, "confidence": 0.8], state: "needs_human")
        human["summary"] = "인증서 비밀번호 입력이 필요한 화면입니다. 사용자가 직접 인증해야 합니다."
        let data = try response(human)
        let result = try inspect { _ in (data, 200) }
        XCTAssertEqual(result["summary"] as? String, human["summary"] as? String)
        XCTAssertEqual(result["state"] as? String, "needs_human")
        XCTAssertTrue(result["target"] is NSNull)

        for secret in ["비밀번호: example-secret", "123456-1234567", "1234 5678 1234 5678", "sk-proj-synthetic_secret_token_123"] {
            human["summary"] = secret
            let unsafe = try response(human)
            XCTAssertThrowsError(try inspect { _ in (unsafe, 200) }) {
                XCTAssertFalse(String(describing: $0).contains(secret))
            }
        }
        human["summary"] = "사용자 인증이 필요합니다."
        human["target"] = ["label": "비밀번호: example-secret", "x": 0.5, "y": 0.5, "confidence": 0.8]
        let unsafeLabel = try response(human)
        XCTAssertThrowsError(try inspect { _ in (unsafeLabel, 200) })
    }
}
