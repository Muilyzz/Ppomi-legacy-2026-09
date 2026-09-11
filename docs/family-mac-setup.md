# 부모님 공용 Mac 설정

한 Mac에 관리용 관리자 계정 하나, 부모님용 표준 계정 두 개를 만든다. Apple 계정을 한 macOS 사용자에서 반복해서 로그아웃·로그인하지 않고, 부모님은 빠른 사용자 전환으로 자기 환경을 선택한다.

| 계정 | 권한 | 로그인과 용도 |
| --- | --- | --- |
| 관리 | 관리자 | 앱 설치·업데이트·초기 권한 설정. Apple 계정 로그인은 필수가 아니다. |
| 어머니 | 표준 사용자 | 어머니 iPhone과 같은 Apple 계정, 어머니의 뽀미 Google 로그인. |
| 아버지 | 표준 사용자 | 아버지 iPhone과 같은 Apple 계정, 아버지의 뽀미 Google 로그인. |

## 처음 설정

1. 새 Mac에 세 macOS 사용자를 만든다. 관리용 암호를 별도로 보관하고 부모님 계정에 관리자 권한을 줄 필요는 없다.
2. 관리자가 다운로드한 Ppomi.app을 `/Applications`에 설치한다. 현재 제공하는 Mac 0.2.0은 Apple Silicon·macOS 26 이상용 개발 서명 테스트 버전이며 공증 전이다. 앱 설치 후 첫 실행은 설치 담당자가 함께 확인한다. 보안 경고가 있으면 [Apple의 앱 열기 안내](https://support.apple.com/en-ca/102445)를 따른다.
3. 부모님 각 계정으로 로그인해서 해당 iPhone과 같은 Apple 계정 및 2단계 인증을 설정한다. iPhone은 잠겨 있고 Mac 가까이에 있어야 하며 두 기기의 Wi-Fi·Bluetooth를 켠다. 뽀미를 붙이기 전에 Apple의 iPhone 미러링 앱이 각 사용자에서 정상 연결되는지 확인한다.
4. 빠른 사용자 전환을 켠다. Touch ID를 지원하는 Mac·키보드라면 각 사용자의 지문을 설정한다. 재시작·로그아웃 후 첫 로그인에는 암호가 필요하다.
5. FileVault를 켰다면 두 부모님 계정 모두 재부팅 화면에서 디스크를 잠금 해제할 수 있는지 확인한다. 사용자 활성화가 필요하면 관리자가 설정한다.
6. 각 계정에서 뽀미를 열어 본인의 앱 로그인과 저장소를 새로 설정한다. 손쉬운 사용·화면 기록·필요할 때 마이크 권한을 확인한다. 권한 종류에 따라 관리자 확인이 필요할 수 있다.
7. 사용자 전환 전에는 진행 중인 뽀미 작업과 iPhone 미러링을 마친다. 한 번에 현재 사용 중인 사람의 화면과 iPhone을 사용한다. 전환 후 미러링이 곧바로 이어지는지는 실제 기기에서 확인한다.

공식 미러링 요구사항에는 표준 사용자를 금지하는 조건이 없다. 그러나 여러 macOS 사용자가 로그인한 상태에서 전환할 때 미러링의 유지·재연결을 항상 보장한다는 문서도 확인하지 못했다. 두 사람의 동시 미러링 운용을 전제로 하지 않는다.

## 앱의 키와 계정

이 설명은 현재 코드 기준이며 운영 서버의 마이그레이션 적용 상태를 확인한 결과는 아니다.

- macOS 사용자는 키체인·설정·홈 디렉터리를 분리한다. Apple 계정은 iPhone 미러링에 사용한다. 뽀미의 Google 로그인은 서버 사용자·workspace에 연결된다. 세 계정 개념은 서로 다르다.
- 개인정보 프로필 금고는 지원 기기에서 Secure Enclave P-256 키를 사용한다. 기록 암호화용 AES-256 키와 다른 기기로 전달할 때 쓰는 X25519 키는 일반 키체인에 보관한다. 모든 키가 Secure Enclave 안에 있는 것은 아니다.
- 로컬 원본 장부는 현재 일반 SQLite 파일이다. 동기화 사본의 암호화와 로컬 DB 파일 자체의 암호화는 다르다. Mac의 저장장치 보호에는 FileVault와 사용자별 파일 접근권한도 필요하다.
- Mac의 Google 로그아웃은 세션만 지우며 모든 기록 키·기기 설정을 지우는 계정 전환 기능이 아니다. 한 macOS 사용자에서 부모님 Google 로그인을 번갈아 쓰는 방식은 피한다.
- 설치 담당자의 키체인·앱 설정·기록 폴더를 부모님 계정에 복사하지 않는다. 기존 기기 자격이 남으면 새 Google 사용자가 기존 workspace에 연결되는 경로가 있다.
- 앱 바이너리는 공유해도 기록은 각 사용자 홈의 `Library/Application Support/Ppomi/data/ledger.db`를 쓰는지 확인한다. 현재 개발용 기본 경로 선택은 실행파일 주변과 빌드 소스 경로의 DB를 우선할 수 있으므로, 개발 체크아웃이나 공용 DB를 새 Mac에 함께 복사하지 않는다.
- macOS 관리자가 된다고 부모님의 뽀미 기록 공유 권한이 자동으로 생기는 구조는 아니다. 가족 기록 공유는 별도로 설계·설정해야 한다.

관련 구현: `Ppomi/Sources/Ppomi/IdentityVault.swift`, `Shared/SharedRecordVault.swift`, `Shared/SharedRecordCrypto.swift`, `Shared/GoogleAccount.swift`, `Ledger/AppSettings.swift`.

## Apple 안내

- [iPhone 미러링 조건과 제한](https://support.apple.com/en-us/120421)
- [Mac 사용자 추가와 표준 사용자](https://support.apple.com/en-au/guide/mac-help/-mchl3e281fc9/mac)
- [빠른 사용자 전환](https://support.apple.com/en-gb/guide/mac-help/mchlp2439/mac)
- [Touch ID 로그인 조건](https://support.apple.com/guide/mac-help/use-touch-id-mchl16fbf90a/mac)
- [FileVault 사용자 활성화](https://support.apple.com/en-gb/guide/mac-help/mh11785/mac)

2026-09-11 확인. 실제 새 Mac의 계정 생성·권한 변경·미러링 시험은 아직 수행하지 않았다.
