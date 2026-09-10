// 컴포넌트는 CSS를 안 갖는다. 툴바 '스타일'이 스킨 하나를 <style>로 넣는다: 뽀미 테마(두 색 토큰 + 페이지·셸·작업대 스타일, 기본) ·
// 심플(밝은 최소본) · 없음(기본 DOM). 툴바 '테마'는 라이트/다크, '글자 크기'는 --ui-scale(글자·여백·컨트롤이 함께 커진다).
import colors from '../../agent/src/generated/theme-colors.css?raw';
import tokensSource from '../../agent/src/tokens.css?raw';
import fontUrl from '../../agent/public/fonts/PretendardVariable.woff2?url';
import shell from '../../agent/src/style.css?raw';
import workbench from '../../agent/src/ui/workbench.css?raw';
import theme from '../../Ppomi/Sources/Ppomi/Web/theme.css?raw';
import simple from '../../Ppomi/Sources/Ppomi/Web/simple.css?raw';

const tokens = colors + tokensSource.replace(/^@import[^\n]*\n/m, '').replace('./fonts/PretendardVariable.woff2', fontUrl);
// 뽀미 테마 = 토큰 + 스토리가 고른 부분(parameters.skin). 페이지(분개·증거·값 종류)는 theme, 셸·작업대는 shell·workbench.
const PARTS = {theme, shell, workbench};
const skin = (style, parts = ['theme']) =>
  style === 'ppomi' ? tokens + parts.map((part) => PARTS[part] || '').join('') : style === 'simple' ? simple : '';

export default {
  globalTypes: {
    style: {description: '주입 스타일', toolbar: {title: '스타일', items: [{value: 'ppomi', title: '뽀미 테마'}, {value: 'simple', title: '심플'}, {value: 'none', title: '기본 DOM'}], dynamicTitle: true}},
    theme: {description: '테마', toolbar: {icon: 'mirror', items: [{value: 'system', title: '시스템'}, {value: 'light', title: '라이트'}, {value: 'dark', title: '다크'}], dynamicTitle: true}},
    scale: {description: '글자 크기', toolbar: {icon: 'zoom', items: ['1', '1.5', '2', '3'], dynamicTitle: true}},
  },
  initialGlobals: {style: 'ppomi', theme: 'system', scale: '1'},
  decorators: [(story, ctx) => {
    const root = document.documentElement;
    if (ctx.globals.theme === 'system') delete root.dataset.theme; else root.dataset.theme = ctx.globals.theme;
    root.style.setProperty('--ui-scale', ctx.globals.scale);
    const wrap = document.createElement('div'), css = skin(ctx.globals.style, ctx.parameters.skin);
    if (css) { const s = document.createElement('style'); s.textContent = css; wrap.appendChild(s); }
    wrap.appendChild(story());
    return wrap;
  }],
  parameters: {backgrounds: {disable: true}, layout: 'fullscreen'},
};
