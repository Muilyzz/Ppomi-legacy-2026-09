import Foundation

/// 구두 결재의 판정(비서 교본: 복창 → "승인" → 기록). 사람의 전사 한 토막이 차례의 선택지 하나를 고른다.
/// "승인"과 "취소"가 같이 나오면 고르지 않는다(되묻는 쪽이 안전하다). "네"·"응"만으로는 고르지 않는다: 복창 뒤의 "승인"이 암호다.
enum VoiceApproval {
    static func option(for text: String, among options: [String]) -> String? {
        let yes = text.contains("승인"), no = text.contains("취소") || text.contains("거절")
        guard yes != no else { return nil }
        let marks = yes ? ["승인", "확인", "진행", "예"] : ["취소", "거절", "아니"]
        return options.first { option in marks.contains { option.contains($0) } }
    }
}
