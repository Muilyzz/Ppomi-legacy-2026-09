package com.ppomi.androidbridge;

public final class ProtectedActionPolicyTest {
    public static void main(String[] args) {
        String publisherCard = "어카운트인포-계좌통합관리\n금융결제원(KFTC)\n금융\n별표 평점: 3.4\n500만회 이상 다운로드됨\n";
        allowed(publisherCard);
        allowed("금융결제원");
        allowed("다른결제회사");
        allowed("테스트 결제연구소");
        allowed("앱 자세히 보기");
        String[] paymentActions = {"결제", "결제하기", "결제하시겠습니까", "금액결제", "10,000원 결제", "₩10,000결제",
            "결제 10,000원", "간편결제", "정기결제", "결제수단변경", "결제수단추가", "결제정보확인", "결제할게요",
            "결제해 주세요", "결제합니다", "결제요청", "결제신청", "결제승인", "결제진행", "결제취소", "결제완료", "결제를 진행", "결제(10,000원)", "결제_확인",
            "결제예약", "결제처리", "결제실행",
            publisherCard + "결제하기", "금융결제원\n송금"};
        for (String action : paymentActions) protectedAction(action);
        // English and all other prior rules remain just as conservative as before.
        String[] unchanged = {"payment", "Payments Company", "send", "purchase", "checkout", "delete", "erase", "uninstall",
            "factory_reset", "factory\nreset", "password", "passwd", "api_key", "api\nkey", "secret", "otp", "permission", "grant", "allow_button",
            "보내기", "전송", "송금", "즉시송금하기", "구매", "주문", "삭제", "초기화", "제거", "비밀번호", "인증번호", "권한", "접근성", "허용"};
        for (String action : unchanged) protectedAction(action);
        System.out.println("Protected action boundary tests passed: " + (5 + paymentActions.length + unchanged.length));
    }
    private static void allowed(String label) { if (ProtectedActionPolicy.protectedLabel(label)) throw new AssertionError("Safe fixture label rejected"); }
    private static void protectedAction(String label) { if (!ProtectedActionPolicy.protectedLabel(label)) throw new AssertionError("Protected fixture label accepted"); }
}
