(() => {
  'use strict';

  const dialog = document.getElementById('install-guide');
  const prompt = document.getElementById('ipad-prompt');
  const context = document.getElementById('install-guide-context');
  const isHome = document.documentElement.dataset.installTarget === 'home';
  const userAgent = navigator.userAgent;
  // iPadOS can request desktop pages and identify itself as a Mac.
  const isIPad = /iPad/.test(userAgent)
    || (/Macintosh/.test(userAgent) && navigator.maxTouchPoints > 1);
  const isIOS = isIPad || /iPhone|iPod/.test(userAgent);
  const isSafari = /Version\/[\d.]+.*Safari/.test(userAgent)
    && !/CriOS|FxiOS|EdgiOS|OPiOS|DuckDuckGo/.test(userAgent);
  const standalone = window.matchMedia('(display-mode: standalone)');
  let opener = null;

  function updateContext() {
    // This indicates how this page is running, not whether another app is installed.
    const runsStandalone = standalone.matches || navigator.standalone === true;
    if (prompt) prompt.hidden = !isIPad || runsStandalone;
    if (!context) return;
    if (runsStandalone) {
      context.textContent = '지금은 이미 홈 화면에서 연 웹 앱 창이에요. 다시 추가하지 않아도 됩니다.';
    } else if (isIOS && !isSafari) {
      context.textContent = '아래 안내는 Safari 기준이에요. 다른 브라우저나 앱 안에서 열었다면 ppomi.muilyzz.com을 Safari에서 열어 주세요.';
    } else {
      context.textContent = 'iPad의 Safari에서 사용하는 방법입니다. iPadOS 버전에 따라 메뉴 모양과 위치가 조금 다를 수 있어요.';
    }
  }

  const buttons = document.querySelectorAll('[data-open-install-guide]');
  buttons.forEach((button) => {
    if (!dialog || typeof dialog.showModal !== 'function') return;
    button.hidden = false;
    button.addEventListener('click', () => {
      opener = button;
      updateContext();
      dialog.showModal();
    });
  });
  document.querySelectorAll('[data-close-install-guide]').forEach((button) => {
    button.addEventListener('click', () => dialog.close());
  });
  dialog?.addEventListener('close', () => opener?.focus());
  standalone.addEventListener('change', updateContext);
  window.addEventListener('pageshow', updateContext);
  updateContext();
  const url = new URL(window.location.href);
  if (isHome && url.searchParams.get('install') === '1') {
    url.searchParams.delete('install');
    history.replaceState(null, '', url.pathname + url.search + url.hash);
    if (dialog && typeof dialog.showModal === 'function') {
      opener = [...buttons].find((button) => !button.hidden) ?? null;
      dialog.showModal();
    }
  }
})();
