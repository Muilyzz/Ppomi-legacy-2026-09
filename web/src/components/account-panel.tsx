'use client';

import { UserButton } from '@clerk/nextjs';
import { RLS_CLERK_SUB_SQL } from '@/lib/clerk-supabase';
import { ShellHandoff } from './shell-handoff';

export function AccountPanel({ userId }: { userId: string }) {
  return (
    <section className="stack">
      <div className="panel">
        <h1>보호된 계정</h1>
        <p className="meta">Clerk <code>sub</code> — RLS는 이 값을 {RLS_CLERK_SUB_SQL} 와 비교합니다.</p>
        <p><code>{userId}</code></p>
        <div className="chrome">
          <UserButton />
          <a href="/account/profile">프로필 · 연결 계정</a>
        </div>
      </div>
      <ShellHandoff />
    </section>
  );
}
