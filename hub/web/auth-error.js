const MESSAGES = {
  authentication: '로그인을 다시 해 주세요.',
  connection: '로그인 서버에 연결하지 못했습니다. 다시 시도해 주세요.',
  storage: '브라우저의 로그인 저장소를 사용할 수 없습니다.',
  unavailable: '로그인은 ppomi.muilyzz.com에서 사용할 수 있습니다.',
  cancelled: '로그인 상태가 변경되었습니다. 다시 시도해 주세요.',
  cleanup: '이전 계정의 데이터를 정리하지 못했습니다. 다시 시도해 주세요.',
};

export class AuthError extends Error {
  constructor(code) { super(MESSAGES[code]); this.name = 'AuthError'; this.code = code; }
}
