// 픽스처 실행. ppomi-body 런타임(PlaybookRuntime)이 작은 픽스처 ppomi-path 를 인메모리 드라이버로 실행해
// RunResult.stepResults 를 낸다. 패널은 그 결과를 그대로 그린다(emit → 뷰). 라이브 드라이버·화면 캡처·OCR·Computer Use 없음.
import {
  AdapterTimeoutError,
  DummyAdapter,
  FixedPermissionGate,
  PlaybookRuntime,
  type OsAdapter,
  type OsAdapterKind,
  type Playbook,
  type RunResult,
  type ScreenSnapshot,
  type StepResult,
} from "../../../packages/playbook-runtime/src/index";

/** 공동인증서 선택 창의 픽스처 화면. 실제 기관 캡처가 아니다. */
export const fixtureScreen: ScreenSnapshot = {
  title: "공동인증서 선택",
  texts: ["공동인증서 선택", "인증서 목록", "홍길동 (업무용)", "확인", "취소"],
  focused: null,
};

/** 인증서를 고르고 확인을 누른 뒤 결과 화면을 읽는다. 비밀번호 입력은 사람이 하므로 스텝에 없다. */
export const fixturePlaybook: Playbook = {
  id: "fixture-cert-select",
  steps: [
    { id: "read-list", kind: "read", require: { screen: ["인증서 목록"] } },
    { id: "pick-cert", kind: "click", target: "홍길동 (업무용)" },
    { id: "confirm", kind: "click", target: "확인" },
    { id: "read-result", kind: "read", require: { screen: ["서명 완료"] } },
  ],
};

/** 확인 버튼이 응답하지 않는 상황을 낸다. */
export const fixtureTimeoutTarget = "확인";

/** In-memory driver for the fixture run: the dummy driver, except one target times out once. */
export class TimeoutOnceDriver implements OsAdapter {
  readonly kind: OsAdapterKind;
  private readonly inner: DummyAdapter;
  private pending: string | undefined;

  constructor(inner: DummyAdapter, timeoutTarget: string) {
    this.kind = inner.kind;
    this.inner = inner;
    this.pending = timeoutTarget;
  }

  readScreen(): ScreenSnapshot {
    return this.inner.readScreen();
  }

  focus(target: string): void {
    this.inner.focus(target);
  }

  click(target: string): void {
    if (target === this.pending) {
      this.pending = undefined;
      throw new AdapterTimeoutError(`${target} did not respond in time`);
    }
    this.inner.click(target);
  }

  type(target: string, text: string): void {
    this.inner.type(target, text);
  }
}

/** The whole run, for tests that compare the runner log with the emitted rows. */
export function runFixture(): RunResult {
  const driver = new TimeoutOnceDriver(new DummyAdapter(fixtureScreen), fixtureTimeoutTarget);
  const runtime = new PlaybookRuntime(driver, new FixedPermissionGate(["ui.read", "ui.control"]));
  return runtime.run(fixturePlaybook);
}

/** What the panel renders: one StepResult per declared step, exactly as the runtime emitted them. */
export function runFixturePlaybook(): readonly StepResult[] {
  return runFixture().stepResults;
}
