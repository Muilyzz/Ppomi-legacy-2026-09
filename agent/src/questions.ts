import { z } from "zod";
import { NativeBridge, NativeBridgeError } from "./bridge";

export const userInputSchema = z.object({
  questions: z.array(z.object({
    id: z.string().min(1).max(64).regex(/^[a-zA-Z0-9_-]+$/),
    prompt: z.string().trim().min(1).max(500),
    options: z.array(z.object({ label: z.string().trim().min(1).max(120), description: z.string().max(240) })).max(3),
    allow_text: z.boolean().describe("선택지 외의 직접 입력 허용 여부. 선택지가 없으면 true."),
  })).min(1).max(3),
});
export const bankProfileSchema = z.object({
  profile_id: z.string().min(1).max(80).regex(/^[a-zA-Z0-9_-]+$/).default("self"),
  bank_id: z.literal("kb").default("kb"),
});
export type UserInputRequest = z.infer<typeof userInputSchema>;
export type BankProfileRequest = z.infer<typeof bankProfileSchema>;
export type BankField = "customer_name" | "account_number";
export type BankValues = Partial<Record<BankField, string>>;
export type BankRegistered = Record<BankField, boolean>;
export type UserAnswer = { id: string; answer: string };
export type InputCard = {
  id: string; kind: "questions"; questions: UserInputRequest["questions"];
} | {
  id: string; kind: "bank"; profile_id: string; bank_id: "kb"; label_hint: string;
  registered: BankRegistered; submitting: boolean;
};
type CancelReason = "user_cancelled" | "session_ended" | "timeout";
type CancelResult = { status: "cancelled"; reason: CancelReason };
type InputResult = CancelResult | { status: "submitted"; answers: UserAnswer[] };
type BankResult = CancelResult | { status: "failed"; reason: "save_unconfirmed" } | {
  status: "saved" | "already_registered"; saved?: true; profile_id: string; bank_id: "kb"; registered: BankRegistered;
};
type Pending = { card: InputCard; resolve: (value: any) => void; timer: ReturnType<typeof setTimeout>; nativeId?: string };
const bankFields: BankField[] = ["customer_name", "account_number"];
const registeredSchema = z.object({ customer_name: z.boolean(), account_number: z.boolean() });
const nativeBankRequestSchema = z.object({ request_id: z.string().min(1).max(160), profile_id: z.string(), bank_id: z.literal("kb"),
  label_hint: z.string().max(160), registered: registeredSchema });
const nativeBankSavedSchema = z.object({ saved: z.literal(true), profile_id: z.string(), bank_id: z.literal("kb"), registered: registeredSchema });

/** Per-session waits. Bank values are never retained here or returned to the model. */
export class QuestionRequests {
  private pending = new Map<string, Pending>();
  private active = true;
  constructor(private bridge: NativeBridge, private onChange: (cards: InputCard[]) => void = () => {},
    private check: () => void = () => {}, private timeoutMs = 5 * 60_000) {}

  private assertActive() {
    if (!this.active) throw new NativeBridgeError("session_ended");
    this.check();
  }
  private publish() { this.onChange([...this.pending.values()].map(({ card }) => structuredClone(card))); }
  private enqueue<T>(card: InputCard, nativeId?: string): Promise<T> {
    this.assertActive();
    return new Promise(resolve => {
      const timer = setTimeout(() => this.cancel(card.id, "timeout"), this.timeoutMs);
      this.pending.set(card.id, { card, resolve, timer, nativeId });
      this.publish();
    });
  }
  private finish(id: string, value: InputResult | BankResult) {
    const item = this.pending.get(id);
    if (!item) return false;
    clearTimeout(item.timer);
    this.pending.delete(id);
    this.publish();
    item.resolve(value);
    return true;
  }
  private release(nativeId?: string) {
    if (nativeId) void this.bridge.call("bankProfileCancel", { request_id: nativeId }).catch(() => {});
  }
  requestUserInput(input: UserInputRequest): Promise<InputResult> {
    this.assertActive();
    const { questions } = userInputSchema.parse(input);
    if (new Set(questions.map(q => q.id)).size !== questions.length || questions.some(q => !q.options.length && !q.allow_text
      || new Set(q.options.map(o => o.label)).size !== q.options.length)) throw new NativeBridgeError("tool_failed");
    return this.enqueue({ id: crypto.randomUUID(), kind: "questions", questions });
  }
  submitAnswers(id: string, answers: UserAnswer[]): boolean {
    this.assertActive();
    const item = this.pending.get(id);
    if (!item || item.card.kind !== "questions") return false;
    const questions = item.card.questions;
    if (answers.length !== questions.length || new Set(answers.map(a => a.id)).size !== answers.length) return false;
    const clean: UserAnswer[] = [];
    for (const question of questions) {
      const answer = answers.find(a => a.id === question.id)?.answer?.trim();
      if (!answer || answer.length > 2000 || !question.allow_text && !question.options.some(o => o.label === answer)) return false;
      clean.push({ id: question.id, answer });
    }
    return this.finish(id, { status: "submitted", answers: clean });
  }
  async requestBankProfile(input: BankProfileRequest): Promise<BankResult> {
    this.assertActive();
    const args = bankProfileSchema.parse(input);
    const metadata = nativeBankRequestSchema.parse(await this.bridge.call("bankProfileRequest", args));
    try {
      this.assertActive();
      if (metadata.profile_id !== args.profile_id || metadata.bank_id !== args.bank_id) throw new NativeBridgeError("tool_failed");
      if (bankFields.every(key => metadata.registered[key])) {
        this.release(metadata.request_id);
        return { status: "already_registered", profile_id: args.profile_id, bank_id: args.bank_id, registered: metadata.registered };
      }
      return await this.enqueue({ id: crypto.randomUUID(), kind: "bank", profile_id: metadata.profile_id,
        bank_id: metadata.bank_id, label_hint: metadata.label_hint, registered: metadata.registered, submitting: false }, metadata.request_id);
    } catch (error) { this.release(metadata.request_id); throw error; }
  }
  async submitBank(id: string, input: BankValues): Promise<boolean> {
    this.assertActive();
    const item = this.pending.get(id);
    if (!item || item.card.kind !== "bank" || item.card.submitting) return false;
    const card = item.card;
    const values: BankValues = {};
    if (Object.keys(input).some(key => !bankFields.includes(key as BankField) || card.registered[key as BankField])) return false;
    for (const key of bankFields) {
      if (input[key] !== undefined && typeof input[key] !== "string") return false;
      const value = input[key]?.trim();
      if (value) values[key] = value;
      if (!card.registered[key] && !value) return false;
    }
    if (values.customer_name && (values.customer_name.length > 100 || /[\u0000-\u001f\u007f]/.test(values.customer_name))) return false;
    if (values.account_number && !/^[0-9 -]{1,40}$/.test(values.account_number)) return false;
    card.submitting = true;
    this.publish();
    try {
      // Explicitly project the response: never forward native extras (including values) into tool results.
      const raw = await this.bridge.call("bankProfileSubmit", { request_id: item.nativeId, values });
      this.assertActive();
      if (this.pending.get(id) !== item) return false;
      const result = nativeBankSavedSchema.parse(raw);
      if (result.profile_id !== card.profile_id || result.bank_id !== card.bank_id) throw new NativeBridgeError("tool_failed");
      return this.finish(id, { status: "saved", saved: true, profile_id: card.profile_id, bank_id: card.bank_id, registered: result.registered });
    } catch {
      // Save may have reached native storage. Close rather than silently retrying a write.
      if (this.pending.get(id) === item) {
        this.release(item.nativeId);
        this.finish(id, { status: "failed", reason: "save_unconfirmed" });
        throw new NativeBridgeError("tool_failed");
      }
      return false;
    } finally {
      for (const key of bankFields) delete values[key];
    }
  }
  cancel(id: string, reason: CancelReason = "user_cancelled"): boolean {
    const item = this.pending.get(id);
    if (!item) return false;
    this.release(item.nativeId);
    return this.finish(id, { status: "cancelled", reason });
  }
  close() {
    this.active = false;
    for (const id of [...this.pending.keys()]) this.cancel(id, "session_ended");
  }
}
