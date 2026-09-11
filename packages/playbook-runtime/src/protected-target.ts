/** Submit / payment-like labels. Not merchant-specific. Not a device-approval gate. */
const PROTECTED_TARGET =
  /결제하기|발급신청|발급하기|신청하기|결제|구매|송금|이체|전송|제출|\bpay\b|purchase|checkout|\bsubmit\b|\btransfer\b/i;

export function protectedTargetReason(target: string): string | null {
  return PROTECTED_TARGET.test(target) ? `protected target: ${target}` : null;
}
