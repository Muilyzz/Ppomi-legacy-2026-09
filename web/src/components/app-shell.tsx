import type { ReactNode } from 'react';
import { isClerkConfigured } from '@/lib/clerk-env';
import { ClerkChrome } from './clerk-chrome';

export function AppShell({ children }: { children: ReactNode }) {
  const configured = isClerkConfigured();
  return (
    <>
      <header className="bar">
        <a className="brand" href="/">뽀미 · Clerk 스파이크</a>
        <nav>
          <a href="/account">계정</a>
          {configured ? <ClerkChrome /> : <span className="meta">키 없음</span>}
        </nav>
      </header>
      <main className="wrap">{children}</main>
    </>
  );
}
