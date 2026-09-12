'use client';

import { useAuth } from '@clerk/nextjs';
import { useEffect, useRef, useState } from 'react';
import { CLERK_HANDOFF_ORIGIN, postClerkHandoff, wantsShellHandoff } from '@/lib/clerk-handoff';

export function ShellHandoff() {
  const { getToken, isSignedIn } = useAuth();
  const [state, setState] = useState<'idle' | 'sent' | 'error'>('idle');
  const sent = useRef(false);

  const handoff = async () => {
    if (sent.current) return;
    const token = await getToken();
    if (!token) {
      setState('error');
      return;
    }
    const ok = await postClerkHandoff(CLERK_HANDOFF_ORIGIN, token);
    if (ok) {
      sent.current = true;
      setState('sent');
      return;
    }
    if (!sent.current) setState('error');
  };

  useEffect(() => {
    if (!isSignedIn || typeof window === 'undefined') return;
    if (!wantsShellHandoff(window.location.search)) return;
    void handoff();
  }, [isSignedIn]);

  return (
    <section className="panel">
      <h2>맥 뽀미 대화 셸</h2>
      <p className="meta">로그인 후 세션 JWT만 앱으로 넘깁니다. Gateway 키는 웹에 없습니다.</p>
      <button type="button" className="cta" onClick={() => void handoff()}>뽀미 앱에서 계속</button>
      {state === 'sent' && <p className="meta">세션을 앱에 전달했습니다. 뽀미로 돌아가면 됩니다.</p>}
      {state === 'error' && <p className="meta">앱에서 로그인을 누른 뒤 다시 시도하세요.</p>}
    </section>
  );
}
