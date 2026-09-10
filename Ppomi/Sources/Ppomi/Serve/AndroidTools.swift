import Foundation
import CoreFoundation

enum AndroidTools {
    static let specs: [ToolSpec] = [
        Tools.T("android_status", "Android 에뮬레이터 MCP 앱·접근성 서비스 연결 상태. 실기기는 아직 지원하지 않는다."),
        Tools.T("android_screen", "Android 화면과 접근성 UI 트리를 읽는다. 노드 ID·실제 화면 픽셀 bounds를 반환한다. iPhone의 0~1 좌표와 다르다. ID는 이 스냅샷에만 유효하다."),
        Tools.T("android_click", "최신 android_screen의 nodeId로 다른 Android 앱의 UI를 클릭한다. 에뮬레이터의 설정·테스트 앱만 지원한다.", ["nodeId": ("string", "최신 UI 트리의 id")], ["nodeId"]),
        Tools.T("android_tap", "Android 화면의 실제 픽셀 좌표를 접근성 제스처로 탭한다. 설정·테스트 앱에서만 가능.", ["x": ("number", "화면 픽셀"), "y": ("number", "화면 픽셀")], ["x", "y"]),
        Tools.T("android_type", "최신 nodeId의 Android 입력칸을 접근성 ACTION_SET_TEXT로 채운다. 한글 지원. 비밀번호 입력은 지원하지 않는다.", ["nodeId": ("string", nil), "text": ("string", nil)], ["nodeId", "text"]),
        Tools.T("android_key", "Android 시스템 탐색: back, home, recents.", ["name": ("string", "back, home, recents")], ["name"]),
        Tools.T("android_swipe", "실제 픽셀 좌표의 두 지점 사이를 접근성 제스처로 스와이프한다.", ["x1": ("number", nil), "y1": ("number", nil), "x2": ("number", nil), "y2": ("number", nil), "durationMs": ("integer", "기본 350")], ["x1", "y1", "x2", "y2"]),
        Tools.T("android_open", "Android 에뮬레이터의 허용된 앱을 패키지 ID로 연다: com.android.settings, com.ppomi.androidtarget, com.ppomi.androidbridge.", ["packageName": ("string", nil)], ["packageName"])
    ]
    static let names = Set(specs.map(\.name))

    static func request(_ name: String, _ arguments: [String: Any]) throws -> (String, [String: Any]) {
        switch name {
        case "android_status": return ("status", [:])
        case "android_screen": return ("ui_tree", [:])
        case "android_click": return ("click", try strings(arguments, ["nodeId"]))
        case "android_type": return ("type_text", try strings(arguments, ["nodeId", "text"], allowEmpty: ["text"]))
        case "android_open":
            let params = try strings(arguments, ["packageName"])
            guard ["com.android.settings", "com.ppomi.androidtarget", "com.ppomi.androidbridge"].contains(params["packageName"] as? String ?? "") else {
                throw AndroidRuntime.Failure(description: "현재 Android 테스트는 설정·뽀미 테스트 앱에서만 가능합니다.")
            }
            return ("open_app", params)
        case "android_key":
            guard let key = arguments["name"] as? String, ["home", "back", "recents"].contains(key) else {
                throw AndroidRuntime.Failure(description: "Android 키는 back, home, recents 중 하나여야 합니다.")
            }
            return (key, [:])
        case "android_tap": return ("tap", try coordinates(arguments, ["x", "y"]))
        case "android_swipe":
            var params = try coordinates(arguments, ["x1", "y1", "x2", "y2"])
            if let value = arguments["durationMs"] {
                guard let duration = value as? Int, !(value is Bool), (50...2000).contains(duration) else {
                    throw AndroidRuntime.Failure(description: "durationMs는 50~2000 정수여야 합니다.")
                }
                params["durationMs"] = duration
            }
            return ("swipe", params)
        default: throw AndroidRuntime.Failure(description: "알 수 없는 Android 도구입니다.")
        }
    }

    private static func strings(_ a: [String: Any], _ keys: [String], allowEmpty: Set<String> = []) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in keys {
            guard let value = a[key] as? String, value.count <= 4000, allowEmpty.contains(key) || !value.isEmpty else {
                throw AndroidRuntime.Failure(description: "\(key) 문자열이 필요합니다 (최대 4000자).")
            }
            result[key] = value
        }
        return result
    }

    private static func coordinates(_ a: [String: Any], _ keys: [String]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in keys {
            guard let n = a[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, (0...16384).contains(n.doubleValue) else {
                throw AndroidRuntime.Failure(description: "\(key)는 유효한 화면 픽셀 좌표여야 합니다.")
            }
            result[key] = n.doubleValue
        }
        return result
    }
}

extension Tools {
    func executeAndroid(_ name: String, _ arguments: [String: Any]) throws -> String {
        if name == "android_screen" { lastAndroidPNG = nil }
        guard name == "android_status" || Self.consented(currentText) else {
            return "실행 안 함: 사용자의 Android 앱 제어 요청이 필요합니다."
        }
        let (method, params) = try AndroidTools.request(name, arguments)
        let read = name == "android_status" || name == "android_screen"
        runtimeRecorder.emit(read ? .reading : .acting, method: .control)
        let response = try androidCall(method, params)
        runtimeRecorder.emit(read ? .read : .acted, method: .control)
        var result = response
        if name == "android_screen" {
            do { lastAndroidPNG = try androidCapture() }
            catch { result["screenshotError"] = "화면 이미지는 캡처하지 못했습니다. 접근성 트리만 반환합니다." }
        }
        return String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
    }
}
