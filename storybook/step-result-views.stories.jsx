// StepResult/Evidence 를 props로만 받는 기록 조각. 라이브 AX·Playwright·런타임 방출은 없다.
import React, {useState} from 'react';
import {createRoot} from 'react-dom/client';
import {fn} from 'storybook/test';
import {RecordsHeader, Workbench} from '../agent/src/ui/workbench';
import {HighlightOverlay} from '../agent/src/ui/highlight-overlay';
import {StepTimeline} from '../agent/src/ui/step-timeline';
import {StepResultPreview} from '../agent/src/ui/step-result-preview';
import {fixtureSteps, overlayFixture} from '../agent/src/ui/step-result-fixtures';
import * as f from '../agent/src/ui/fixtures';

const mount = (node) => {
  const el = document.createElement('div');
  createRoot(el).render(<>
    <style>{'body:has(.workbench){max-width:none;padding:0}.step-result-story{padding:1rem;max-width:36rem}'}</style>
    {node}
  </>);
  return el;
};

const withEvidence = fixtureSteps.find((step) => step.stepId === 'open-next');
const noEvidence = fixtureSteps.find((step) => step.stepId === 'wait-cert');
const openNextOverlay = overlayFixture('open-next');

export default {
  title: '스텝 기록',
  parameters: {skin: ['shell', 'workbench']},
};

export const Timeline = {
  name: '타임라인 · 상태 여섯',
  render: () => mount(<div className="step-result-story">
    <StepTimeline steps={fixtureSteps} selectedStepId="wait-cert" onSelect={fn()} />
  </div>),
};

export const Overlay = {
  name: '오버레이 · 증빙과 상자',
  render: () => mount(<div className="step-result-story">
    <HighlightOverlay evidence={withEvidence.evidence} boxes={openNextOverlay.boxes}
      selectedBoxId={openNextOverlay.selectedBoxId} imageSrc={openNextOverlay.imageSrc} />
  </div>),
};

export const OverlayHidden = {
  name: '오버레이 · 증빙 없음',
  render: () => mount(<div className="step-result-story">
    <p>증빙이 없으면 오버레이는 숨긴다.</p>
    <HighlightOverlay evidence={noEvidence.evidence} boxes={openNextOverlay.boxes} />
  </div>),
};

function SelectingPreview() {
  const [selectedStepId, setSelectedStepId] = useState('open-next');
  const step = fixtureSteps.find((row) => row.stepId === selectedStepId);
  const overlay = overlayFixture(selectedStepId);
  return <div className="step-result-story">
    <HighlightOverlay evidence={step?.evidence} boxes={overlay?.boxes}
      selectedBoxId={overlay?.selectedBoxId} imageSrc={overlay?.imageSrc} />
    <StepTimeline steps={fixtureSteps} selectedStepId={selectedStepId} onSelect={setSelectedStepId} />
  </div>;
}

export const SelectStep = {
  name: '선택 · 타임라인과 오버레이',
  render: () => mount(<SelectingPreview />),
};

export const FixturePage = {
  name: '픽스처 페이지',
  render: () => mount(<div className="step-result-story"><StepResultPreview /></div>),
};

export const InWorkbench = {
  name: '작업대 기록 칸 · 픽스처만',
  render: () => mount(<div style={{height: '100dvh'}}>
    <Workbench topBar={f.topBar} conversation={f.conversation} contentLabel="스텝 기록"
      contentPane={<>
        <RecordsHeader>
          <div role="tablist" aria-label="기록 종류">
            {f.recordTabs.map((tab, i) => <button key={tab} role="tab" aria-selected={i === 0}>{tab}</button>)}
          </div>
        </RecordsHeader>
        <div className="records-body"><StepResultPreview /></div>
      </>} />
  </div>),
};
