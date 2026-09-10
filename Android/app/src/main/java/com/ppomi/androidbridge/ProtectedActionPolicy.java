package com.ppomi.androidbridge;

import java.util.Locale;
import java.util.regex.Pattern;

/** Deterministic label checks; no app, publisher, or merchant-specific exceptions. */
final class ProtectedActionPolicy {
    // Preserve the existing guards unchanged, except for the Korean payment stem below.
    private static final Pattern OTHER = Pattern.compile(
        "send|payment|purchase|checkout|delete|erase|uninstall|factory.?reset|password|passwd|api.?key|secret|otp|permission|grant|allow_button|보내기|전송|송금|구매|주문|삭제|초기화|제거|비밀번호|인증번호|권한|접근성|허용", Pattern.DOTALL);
    // A terminal payment label (including an amount + 결제), conjugated action, or
    // payment-setting compound remains protected. An internal noun stem alone does not.
    private static final Pattern KOREAN_PAYMENT = Pattern.compile(
        "결제(?=$|[^\\p{L}]|하|해|할|했|합|되|돼|된|될|됨|진행|확인|승인|요청|신청|완료|취소|수단|정보|내역|금액|방식|방법|설정|등록|변경|추가|삭제|시작|예약|처리|실행|버튼|창|일|예정|이체|를|는|가|에|로|만|도|요|후|전|중)");

    static boolean protectedLabel(String raw) {
        if (raw == null) return false;
        String label = raw.toLowerCase(Locale.ROOT);
        return OTHER.matcher(label).find() || KOREAN_PAYMENT.matcher(label).find();
    }
}
