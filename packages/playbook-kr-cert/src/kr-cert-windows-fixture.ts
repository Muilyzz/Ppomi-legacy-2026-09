import type { FixtureWindowsWindow } from "../../adapter-windows/src/index.ts";

/** In-memory Windows window. 결제하기 / 제출 stay clickable so a missed stop would tap. */
export const krCertWindowsWindow: FixtureWindowsWindow = {
  appLabel: "인증서 발급",
  packageName: "win:kr-cert:1",
  nodes: [
    { text: "인증서 발급", clickable: false, editable: false },
    { text: "용도", clickable: false, editable: false },
    { text: "다음", clickable: true, editable: false },
    { text: "사업자 구분", clickable: false, editable: true },
    { text: "수수료", clickable: false, editable: false },
    { text: "결제하기", clickable: true, editable: false },
    { text: "제출", clickable: true, editable: false },
  ],
};
