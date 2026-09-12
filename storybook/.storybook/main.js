import {fileURLToPath} from 'node:url';
import tailwindcss from '../../agent/node_modules/@tailwindcss/vite/dist/index.mjs';
// React comes from agent/node_modules (one copy): the shell components under agent/src/ui import it, and the .jsx stories too.
const agentModule = (name) => fileURLToPath(new URL(`../../agent/node_modules/${name}`, import.meta.url));

export default {
  stories: ['../*.stories.{js,jsx}'],
  framework: '@storybook/html-vite',
  addons: ['@storybook/addon-docs'],
  viteFinal: (config) => ({
    ...config,
    // 대화 셸은 AI Elements(shadcn + Tailwind v4)로 그린다: agent/src/index.css 가 Tailwind 를 토큰에 매핑한다.
    plugins: [...(config.plugins ?? []), tailwindcss()],
    // 스토리는 저장소의 이웃 폴더(../Ppomi 원본 뷰·카탈로그, ../docs, ../agent, ../data 의 비공개 발자국·판정)를 그대로 읽는다. 허용 목록이 storybook/ 뿐이면
    // 모듈 그래프로 들어온 파일만 예외로 열리는데, 한글 이름 파일(여기어때.jsonl)은 그 예외의 경로 인코딩이 어긋나 403 이 난다 → 루트를 허용.
    server: {...config.server, fs: {...config.server?.fs, allow: [...(config.server?.fs?.allow ?? []), fileURLToPath(new URL('../../', import.meta.url))]}},
    resolve: {
      ...config.resolve,
      alias: [
        ...(Array.isArray(config.resolve?.alias) ? config.resolve.alias : []),
        {find: /^@\//, replacement: fileURLToPath(new URL('../../agent/src/', import.meta.url))},
        {find: /^react$/, replacement: agentModule('react')},
        {find: /^react\/(.*)$/, replacement: agentModule('react') + '/$1'},
        {find: /^react-dom$/, replacement: agentModule('react-dom')},
        {find: /^react-dom\/(.*)$/, replacement: agentModule('react-dom') + '/$1'},
      ],
    },
  }),
};
