import Foundation

/// An observed tool transition. Only fixed vocabulary and opaque identifiers cross this boundary.
struct RuntimeEvent: Equatable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case started, reading, read, readFailed, acting, acted, verifying, verified, mismatch
        case observing, observed, cached, waitingForUser, userResponded, handedOff, returned, blocked, failed

        /// This tool span has ended; an external handoff does not establish that the user's task is complete.
        var isTerminal: Bool { self == .returned || self == .handedOff || self == .blocked || self == .failed }
    }

    enum Method: String, CaseIterable, Sendable {
        case tool, ocr, vlm, replay, control, storage, human, agent

        var title: String {
            switch self {
            case .tool: return "도구"
            case .ocr: return "OCR"
            case .vlm: return "VLM"
            case .replay: return "재생"
            case .control: return "화면 제어"
            case .storage: return "저장소"
            case .human: return "사람"
            case .agent: return "에이전트"
            }
        }
    }

    /// Keep explicit so an untrusted tool name can never become runtime history.
    static let allowedTools: Set<String> = Set(toolTitles.keys)
    private static let toolTitles: [String: String] = [
        "note_later": "대화 메모 저장", "list_later": "대화 메모 조회", "mark_done": "대화 메모 정리",
        "today_spending": "오늘 지출 조회", "balances": "잔액 조회", "weekly_review": "지출 돌아보기",
        "collect_now": "기록 수집", "draft_reply": "답장 초안", "remind": "알림 설정", "ask_choice": "선택 요청",
        "note_playbook": "절차 기록", "remember": "기억 저장", "forget_fact": "기억 삭제", "web_text": "웹 읽기",
        "phone_screen": "아이폰 화면 읽기", "phone_tap": "아이폰 탭", "phone_key": "아이폰 키 입력",
        "phone_type": "아이폰 입력", "phone_open": "아이폰 앱 열기", "phone_scroll": "아이폰 스크롤",
        "phone_installed": "아이폰 앱 확인", "browser_open": "브라우저 열기",
        "windows_screen": "Windows 화면 읽기", "windows_click": "Windows 클릭",
        "windows_type": "Windows 입력", "windows_key": "Windows 키 입력",
        "windows_scroll": "Windows 스크롤", "windows_open": "Windows 열기",
        "android_status": "Android 연결 확인", "android_screen": "Android 화면 읽기",
        "android_click": "Android 노드 클릭", "android_tap": "Android 탭",
        "android_type": "Android 입력", "android_key": "Android 탐색",
        "android_swipe": "Android 스와이프", "android_open": "Android 앱 열기",
        "shared_status": "공유 서버 확인", "shared_tasks": "공유 작업 읽기",
        "shared_task_create": "공유 작업 요청", "shared_documents": "공유 문서 읽기",
        "shared_document_put": "공유 문서 저장",
        "profile_save": "기본정보 저장", "profile_status": "기본정보 등록 확인",
        "profile_delete": "기본정보 삭제", "profile_fill": "기본정보 입력",
        "screen_inspect": "화면 관찰", "run_combo": "알려진 동작 재생", "pay_preference": "결제 수단 조회",
        "confirm_payment": "결제 승인 요청", "record_spend": "지출 기록",
        "health_records": "건강 기록 조회", "record_health": "건강 기록 저장", "inbody_capture": "인바디 기록 수집", "bank_profile_capture": "은행정보 수집",
        "transactions": "거래 조회", "sql": "장부 조회", "list_playbooks": "절차 목록 조회",
        "read_playbook": "절차 읽기", "note_footprint": "동작 기록", "verify_step": "단계 판정",
        "accounting_records": "분개장 조회", "accounting_import": "분개장 저장",
        "accounting_reclassify": "분개 평가 기록", "accounting_template": "분개장 규격 조회"
    ]

    let id: UUID
    let callID: UUID
    let timestamp: Date
    let tool: String
    let kind: Kind
    let method: Method
    let step: Int?

    init(id: UUID = UUID(), callID: UUID, timestamp: Date = Date(), tool: String,
         kind: Kind, method: Method, step: Int? = nil) {
        self.id = id
        self.callID = callID
        self.timestamp = timestamp
        // Invalid names have no raw-text representation in an event and are rejected by the store.
        self.tool = Self.allowedTools.contains(tool) ? tool : ""
        self.kind = kind
        self.method = method
        self.step = step
    }

    var toolTitle: String { Self.toolTitles[tool] ?? "도구" }

    var title: String {
        switch kind {
        case .started: return "호출 시작"
        case .reading: return "읽는 중"
        case .read: return "읽음"
        case .readFailed: return "추가 화면 읽기 실패"
        case .acting: return "조작 중"
        case .acted: return method == .replay ? "재생 동작 반환" : "조작 요청 전달"
        case .verifying: return "예상 화면 확인 중"
        case .verified: return "예상 화면 일치"
        case .mismatch: return "예상과 다른 화면"
        case .observing: return "화면 관찰 중"
        case .observed: return "화면 관찰 수신"
        case .cached: return "최근 관찰 사용"
        case .waitingForUser: return "사용자 응답 대기"
        case .userResponded: return "사용자 응답 수신"
        case .handedOff: return method == .human ? "사용자에게 넘김" : "에이전트에 반환"
        case .returned: return "호출 반환"
        case .blocked: return "실행 중단"
        case .failed: return "호출 실패"
        }
    }

    var detail: String {
        switch kind {
        case .readFailed: return "조작 후 추가 화면을 읽지 못했습니다."
        case .acted: return method == .replay ? "재생 동작을 마치고 예상 화면을 확인합니다." : "조작 이후의 결과는 별도 확인이 필요합니다."
        case .verified: return "재생 후 예상했던 화면을 확인했습니다."
        case .mismatch: return "기대했던 화면 변화와 일치하지 않았습니다."
        case .observed, .cached: return "화면 관찰은 실행이나 작업 완료를 뜻하지 않습니다."
        case .waitingForUser: return "사용자가 응답할 때까지 기다립니다."
        case .handedOff:
            return method == .human ? "이 단계는 사용자가 직접 이어갑니다." : "이후 외부 에이전트의 작업 상태는 확인되지 않습니다."
        case .returned: return "도구 응답이 반환되었습니다. 전체 작업 완료를 뜻하지 않습니다."
        case .blocked: return "실행 조건을 충족하지 못해 멈췄습니다."
        case .failed: return "이 도구 호출을 정상적으로 마치지 못했습니다."
        default: return method.title
        }
    }
}
