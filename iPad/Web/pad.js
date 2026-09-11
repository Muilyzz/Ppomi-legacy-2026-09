// 탭이 페이지(타임라인·증빙·분개)를 iframe 으로 연다. 페이지는 네이티브(PadFiles)가 서버의 암호화 기록을 읽어 그 자리에서 만든다.
(() => {
  const frame = document.querySelector('.records-body'), tabs = [...document.querySelectorAll('[role=tab]')];
  let page = 'timeline';
  const show = () => {
    tabs.forEach((t) => t.setAttribute('aria-selected', String(t.dataset.page === page)));
    if (frame.getAttribute('src') !== './' + page) frame.setAttribute('src', './' + page);
  };
  tabs.forEach((t) => t.addEventListener('click', () => { page = t.dataset.page; show(); }));
  show();
})();
