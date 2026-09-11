// 픽스처 실행. ppomi-body 런타임 코어(Runtime)가 OS 표면(OsSurface)·페이지 표면(PageSurface)으로 작은 픽스처 ppomi-path 를
// 인메모리 드라이버로 실행해 RunResult.stepResults 를 낸다. 패널은 그 결과를 그대로 그린다(emit → 뷰).
// 라이브 드라이버·화면 캡처·OCR·Computer Use 없음. 런타임이 남기지 않은 증빙은 붙이지 않는다.
import {
  DriverTimeoutError,
  DummyAdapter,
  DummyPageAdapter,
  FixedPermissionGate,
  OsSurface,
  PageSurface,
  Runtime,
  type OsUiDriver,
  type OsUiDriverKind,
  type PagePlaybook,
  type PageSnapshot,
  type Playbook,
  type RunResult,
  type RuntimeOptions,
  type ScreenSnapshot,
  type StepResult,
} from "../../../packages/ppomi-body/src/index";

/** Which runtime surface the fixture goes through. Both return `RunResult.stepResults` as emitted. */
export type FixtureSurface = "os" | "page";

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
    { id: "pick-cert", kind: "click", target: "홍길동 (업무용)", effect: "input" },
    { id: "confirm", kind: "click", target: "확인", effect: "navigate" },
    { id: "read-result", kind: "read", require: { screen: ["서명 완료"] } },
  ],
};

/** 확인 버튼이 응답하지 않는 상황을 낸다. 코어는 시간 초과한 클릭을 재시도하지 않고 사람에게 넘긴다. */
export const fixtureTimeoutTarget = "확인";

/** 수수료 결제 직전 페이지의 픽스처 스냅샷. */
export const fixturePage: PageSnapshot = {
  url: "https://example.test/start",
  title: "발급 신청",
  texts: ["발급 신청", "신청인", "결제 금액", "다음"],
  locators: ["#name", "#next", "#pay"],
};

/** 신청서를 열고 이름을 채운 뒤 결제 금액을 확인한다. 결제 클릭은 `commit` 이라 코어가 사람에게 넘긴다. */
export const fixturePagePlaybook: PagePlaybook = {
  id: "fixture-fee-payment",
  allowedOrigins: ["https://example.test"],
  steps: [
    { id: "open-form", kind: "goto", url: "https://example.test/form", effect: "navigate" },
    { id: "fill-name", kind: "fill", locator: "#name", text: "홍길동", effect: "input" },
    { id: "open-next", kind: "click", locator: "#next", effect: "navigate" },
    { id: "confirm-amount", kind: "read", require: { texts: ["결제 금액"] } },
    { id: "pay", kind: "click", locator: "#pay", effect: "commit" },
    { id: "read-receipt", kind: "read", require: { texts: ["영수증"] } },
  ],
};

/** In-memory OS driver for the fixture run: the dummy driver, except one target times out once. */
export class TimeoutOnceDriver implements OsUiDriver {
  readonly kind: OsUiDriverKind;
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
      throw new DriverTimeoutError(`${target} did not respond in time`);
    }
    this.inner.click(target);
  }

  type(target: string, text: string): void {
    this.inner.type(target, text);
  }
}

/** Virtual clock for the core's `now`/`sleep` so fixture rows carry stable, non-zero timings and never sleep. */
function fixtureClock(): RuntimeOptions {
  let tick = 0;
  return {
    now: () => { tick += 8; return tick; },
    sleep: () => Promise.resolve(),
  };
}

/** The whole run, for tests that compare the runner log with the emitted rows. */
export function runFixture(surface: FixtureSurface = "os"): Promise<RunResult> {
  const permissions = new FixedPermissionGate(["ui.read", "ui.control"]);
  switch (surface) {
    case "os": {
      const driver = new TimeoutOnceDriver(new DummyAdapter(fixtureScreen), fixtureTimeoutTarget);
      return new Runtime(new OsSurface(driver), permissions, fixtureClock()).run(fixturePlaybook);
    }
    case "page": {
      const surfaceForPage = new PageSurface(new DummyPageAdapter(fixturePage), fixturePagePlaybook.allowedOrigins);
      return new Runtime(surfaceForPage, permissions, fixtureClock()).run(fixturePagePlaybook);
    }
    default: {
      const _never: never = surface;
      return _never;
    }
  }
}

/** What the panel renders: one StepResult per declared step, exactly as the runtime emitted them. */
export async function runFixturePlaybook(surface: FixtureSurface = "os"): Promise<readonly StepResult[]> {
  return (await runFixture(surface)).stepResults;
}
