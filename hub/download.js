(() => {
  'use strict';

  const platforms = ['macos', 'android'];
  const titles = {macos: 'Mac용 다운로드', android: 'Android QA 다운로드'};
  const status = document.getElementById('download-status');
  const retry = document.getElementById('retry-downloads');
  const section = document.getElementById('platforms');
  const defaults = Object.fromEntries(platforms.map((platform) => [platform, Object.fromEntries(
    ['label', 'requirements', 'notice'].map((field) => [field, document.getElementById(platform + '-' + field).textContent])
  )]));
  let loading = false;

  const text = (value, limit) => typeof value === 'string' && value.trim().length > 0 && value.length <= limit;
  function validateRelease(release) {
    if (!release || !platforms.includes(release.platform)
      || !text(release.version, 64) || !text(release.label, 120)
      || !text(release.filename, 180) || !/^[A-Za-z0-9][A-Za-z0-9._-]+$/.test(release.filename)
      || !text(release.url, 2048) || !Number.isSafeInteger(release.bytes) || release.bytes <= 0
      || typeof release.sha256 !== 'string' || !/^[a-f0-9]{64}$/i.test(release.sha256)
      || !text(release.notice, 600)) return null;
    if (release.platform === 'android' ? !release.filename.endsWith('.apk') : !/\.(zip|dmg)$/.test(release.filename)) return null;
    const requirements = Array.isArray(release.requirements)
      ? (release.requirements.length > 0 && release.requirements.every((item) => text(item, 200)) ? release.requirements.join(' · ') : null)
      : release.requirements;
    if (!text(requirements, 600)) return null;
    const url = new URL(release.url, window.location.href);
    if (url.username || url.password || url.hash
      || !(url.protocol === 'https:' || (url.protocol === window.location.protocol && url.origin === window.location.origin && url.protocol === 'http:'))
      || !url.pathname.endsWith('/' + release.filename)) return null;
    return {...release, requirements, url: url.href};
  }

  function unavailable(platform, message) {
    const link = document.getElementById(platform + '-download');
    link.removeAttribute('href');
    link.removeAttribute('download');
    link.setAttribute('aria-disabled', 'true');
    link.setAttribute('tabindex', '-1');
    link.querySelector('[data-button-label]').textContent = message;
    document.getElementById(platform + '-meta').textContent = '';
    document.getElementById(platform + '-details').hidden = true;
    for (const [field, value] of Object.entries(defaults[platform])) document.getElementById(platform + '-' + field).textContent = value;
  }

  function showRelease(release) {
    const platform = release.platform;
    const link = document.getElementById(platform + '-download');
    link.href = release.url;
    link.setAttribute('download', release.filename);
    link.removeAttribute('aria-disabled');
    link.removeAttribute('tabindex');
    link.querySelector('[data-button-label]').textContent = titles[platform];
    document.getElementById(platform + '-label').textContent = release.label;
    document.getElementById(platform + '-requirements').textContent = release.requirements;
    document.getElementById(platform + '-notice').textContent = release.notice;
    const size = new Intl.NumberFormat('ko-KR', {maximumFractionDigits: 1}).format(release.bytes / 1024 / 1024);
    document.getElementById(platform + '-meta').textContent = '버전 ' + release.version + ' · ' + size + ' MiB';
    document.getElementById(platform + '-filename').textContent = release.filename;
    document.getElementById(platform + '-hash').textContent = release.sha256.toLowerCase();
    document.getElementById(platform + '-details').hidden = false;
  }

  async function loadDownloads() {
    if (loading) return;
    loading = true;
    retry.disabled = true;
    section.setAttribute('aria-busy', 'true');
    status.textContent = '설치 파일 정보를 확인하고 있습니다.';
    platforms.forEach((platform) => unavailable(platform, '다운로드 확인 중'));
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 12000);
    try {
      const response = await fetch('/downloads.json', {cache: 'no-store', credentials: 'omit', signal: controller.signal});
      if (!response.ok) throw new Error('metadata unavailable');
      const metadata = await response.json();
      if (metadata?.schemaVersion !== 1 || !Array.isArray(metadata.releases) || metadata.releases.length > 20) throw new Error('invalid metadata');
      let available = 0;
      let invalid = false;
      for (const platform of platforms) {
        const entries = metadata.releases.filter((release) => release?.platform === platform);
        let release = null;
        if (entries.length === 1) {
          try { release = validateRelease(entries[0]); } catch { /* malformed URL remains unavailable */ }
        }
        if (release) {
          showRelease(release);
          available += 1;
        } else {
          invalid ||= entries.length > 0;
          unavailable(platform, entries.length > 0 ? '파일 정보를 확인할 수 없음' : '설치 파일 준비 중');
        }
      }
      status.textContent = invalid
        ? '일부 설치 파일 정보를 확인하지 못했습니다. 잠시 후 다시 확인해 주세요.'
        : available > 0 ? '아래에서 설치 파일을 받을 수 있습니다.' : '설치 파일을 준비하고 있습니다. 잠시 후 다시 확인해 주세요.';
      retry.hidden = !invalid && available === platforms.length;
    } catch {
      platforms.forEach((platform) => unavailable(platform, '다운로드 정보 확인 필요'));
      status.textContent = '설치 파일 정보를 불러오지 못했습니다. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.';
      retry.hidden = false;
    } finally {
      clearTimeout(timeout);
      loading = false;
      retry.disabled = false;
      section.setAttribute('aria-busy', 'false');
    }
  }

  retry.addEventListener('click', loadDownloads);
  loadDownloads();
})();
