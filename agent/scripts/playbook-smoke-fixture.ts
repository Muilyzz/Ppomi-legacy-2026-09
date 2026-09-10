// Test-only procedure data: it must never imply that AccountInfo supports Android automation.
import { PlaybookLibrary, type BundledPlaybooks, type executePlaybook } from "../src/playbooks";

export const fixtureName = "합성 계좌조회";
export const fixturePackage = "com.example.ppomi.syntheticaccounts";
export const fixtureCatalog: BundledPlaybooks = {
  schemaVersion: 1, source: "synthetic-test-fixture", sourceSha256: "synthetic-auth-resume-v1",
  commonGuide: "합성 화면에서 현재 연결된 도구로만 진행한다. 실제 인증은 사람이 하며 금융 정보는 저장하지 않는다.",
  playbooks: [{
    id: "synthetic-accounts", name: fixtureName, aliases: ["Synthetic Accounts"], version: "1.0.0",
    launch: { search: fixtureName },
    humanSteps: ["생체인증만 당사자가 처리한다. 완료 보고 후 최신 화면을 확인한다."],
    capabilities: [{
      id: "read-accounts", title: "합성 계좌 목록 조회", description: "안내를 열고 생체인증 이후 합성 계좌 목록을 읽는다.",
      inputs: [], steps: [
        { id: "open", title: "앱 열기와 일반 안내 준비", kind: "open" },
        { id: "auth", title: "생체인증은 당사자가 수행", kind: "human" },
        { id: "read", title: "최신 상태 확인 후 계좌 목록 조회", kind: "read" },
      ],
    }],
    guide: `# ${fixtureName}: 합성 Android 인증 재개 검증
app_list로 설치와 제어 허용을 확인하고 app_open으로 연 뒤 screen_read로 현재 화면을 읽는다.
일반 시작 안내와 조회 메뉴는 에이전트가 ui_tap으로 처리한다. 생체인증 화면에서는 당사자에게 인증만 짧게 안내하고 세션을 끝내지 않는다.
완료 보고 뒤 device_status로 전면을 확인하고 필요하면 같은 앱을 app_open한 뒤 screen_read한다. 완료 발언만으로 성공을 판단하지 않는다.
실제 인증 완료 화면이면 현재 계좌 목록 메뉴를 열어 금융기관별 계좌 수를 보고한다. 인증을 도구로 수행하거나 금융 정보·대화를 저장하지 않는다.
이 패키지와 화면은 테스트 전용이며 실제 금융 앱의 실행 가능성이나 검증 증거가 아니다.`,
  }],
};

/** Inject only procedure data; production tool schemas, guards, progress and errors remain in use. */
export function createFixturePlaybookExecutor(): typeof executePlaybook {
  const library = new PlaybookLibrary(fixtureCatalog);
  return (name, query, context) => name === "list_playbooks" ? library.list(query, context) : library.read(query, context);
}
