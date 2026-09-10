import React, { useLayoutEffect, useRef, useState } from "react";
import { QuestionRequests, type InputCard, type BankField, type BankValues } from "./questions";

type Props = { card: InputCard; requests: QuestionRequests; onError: (message: string) => void };
export function QuestionCard(props: Props) {
  return props.card.kind === "bank" ? <BankCard {...props} card={props.card} /> : <ChoiceCard {...props} card={props.card} />;
}
function ChoiceCard({ card, requests }: Props & { card: Extract<InputCard, { kind: "questions" }> }) {
  const [selected, setSelected] = useState<Record<string, number>>({});
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  return <form className="input-card" aria-label="질문에 답하기" onSubmit={event => {
    event.preventDefault();
    const values = card.questions.map(q => ({ id: q.id,
      answer: selected[q.id] !== undefined && selected[q.id] >= 0 ? q.options[selected[q.id]].label : answers[q.id] || "" }));
    try {
      if (!requests.submitAnswers(card.id, values)) setError("모든 질문 답 필요");
    } catch { setError("종료된 질문"); }
  }}>
    <div className="input-card-heading"><span aria-hidden="true">✧</span><strong>확인</strong></div>
    {card.questions.map((q, index) => <fieldset key={q.id}>
      <legend>{card.questions.length > 1 && <span className="question-number">{index + 1}</span>}{q.prompt}</legend>
      {q.options.map((option, optionIndex) => <label className="question-option" key={optionIndex}>
        <input type="radio" name={`${card.id}-${q.id}`} value={optionIndex} required
          checked={selected[q.id] === optionIndex} onChange={() => setSelected(old => ({ ...old, [q.id]: optionIndex }))} />
        <span><strong>{option.label}</strong>{option.description && <small>{option.description}</small>}</span>
      </label>)}
      {q.allow_text && q.options.length > 0 && <label className="question-option">
        <input type="radio" name={`${card.id}-${q.id}`} value="text" required checked={selected[q.id] === -1}
          onChange={() => setSelected(old => ({ ...old, [q.id]: -1 }))} /><span>직접 입력</span>
      </label>}
      {q.allow_text && (q.options.length === 0 || selected[q.id] === -1) && <textarea
        aria-label={`${q.prompt} 답변`} rows={2} required maxLength={2000} value={answers[q.id] || ""}
        autoComplete="off" placeholder="답변"
        onChange={event => setAnswers(old => ({ ...old, [q.id]: event.target.value }))} />}
    </fieldset>)}
    <p className="input-card-note">대화에 전달 · 비밀번호·금융정보 금지</p>
    {error && <p className="input-card-error" role="alert">{error}</p>}
    <div className="input-card-actions"><button type="button" className="text" onClick={() => requests.cancel(card.id)}>취소</button>
      <button className="send" type="submit">제출</button></div>
  </form>;
}

const fields: { key: BankField; label: string }[] = [
  { key: "customer_name", label: "은행 등록 고객명" }, { key: "account_number", label: "계좌번호" },
];
function clearBankForm(form: HTMLFormElement | null) {
  if (!form) return;
  for (const input of form.querySelectorAll("input")) input.value = "";
  form.reset();
}
function BankCard({ card, requests, onError }: Props & { card: Extract<InputCard, { kind: "bank" }> }) {
  const formRef = useRef<HTMLFormElement>(null);
  const [error, setError] = useState("");
  useLayoutEffect(() => {
    const form = formRef.current;
    return () => clearBankForm(form);
  }, []);
  return <form ref={formRef} className="input-card bank-input-card" aria-label="KB 은행정보 저장" autoComplete="off"
    onSubmit={event => {
      event.preventDefault();
      const form = event.currentTarget;
      const values: BankValues = {};
      for (const field of fields) {
        const input = form.elements.namedItem(field.key) as HTMLInputElement | null;
        if (input?.value.trim()) values[field.key] = input.value.trim();
      }
      clearBankForm(form);
      setError("");
      void requests.submitBank(card.id, values).then(submitted => {
        if (!submitted) setError("저장 실패 · 입력값 지움");
      }).catch(() => onError("저장 결과 확인 실패 · 재시도 안 함"));
    }}>
    <div className="input-card-heading"><span aria-hidden="true">▣</span><strong>KB 은행정보</strong><small>기기 내 보관</small></div>
    {card.label_hint && <p className="input-card-context">{card.label_hint}</p>}
    <p className="bank-privacy">이 Mac에만 저장 · AI에 전달 안 함</p>
    <fieldset disabled={card.submitting}>
      <legend className="visually-hidden">KB 프로필 입력</legend>
      {fields.map(field => card.registered[field.key]
        ? <div className="bank-registered" key={field.key}><span>{field.label}</span><small>✓ 등록됨</small></div>
        : <label className="bank-field" key={field.key}>{field.label}
          <input name={field.key} type="text" autoComplete="off" spellCheck={false} autoCorrect="off" autoCapitalize="off"
            inputMode={field.key === "account_number" ? "numeric" : "text"}
            maxLength={field.key === "account_number" ? 40 : 100} required={!card.registered[field.key]}
            pattern={field.key === "account_number" ? "[0-9 \\-]+" : undefined}
            placeholder={field.key === "account_number" ? "숫자·하이픈" : "등록 이름"} />
        </label>)}
    </fieldset>
    <p className="input-card-note">등록 정보 유지 · 변경은 프로필 설정 · 비밀번호·주민번호·OTP 안 받음</p>
    {error && <p className="input-card-error" role="alert">{error}</p>}
    <div className="input-card-actions"><button type="button" className="text" disabled={card.submitting}
      onClick={() => { clearBankForm(formRef.current); requests.cancel(card.id); }}>취소</button>
      <button className="send" type="submit" disabled={card.submitting}>{card.submitting ? "저장 중…" : "저장"}</button></div>
  </form>;
}
