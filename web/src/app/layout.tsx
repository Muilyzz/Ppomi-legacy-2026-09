import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { ClerkProvider } from '@clerk/nextjs';
import { AppShell } from '@/components/app-shell';
import { isClerkConfigured } from '@/lib/clerk-env';
import './globals.css';

export const metadata: Metadata = {
  title: '뽀미 · Clerk 스파이크',
  description: 'MZZ-39 slice 1 — Clerk as primary auth. Supabase stays the data plane.',
};

const appearance = {
  variables: {
    colorBackground: '#131313',
    colorPrimary: '#c7a300',
    colorText: '#e6e6e3',
    colorInputBackground: '#000000',
    colorInputText: '#e6e6e3',
    borderRadius: '6px',
  },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  const body = <AppShell>{children}</AppShell>;
  return (
    <html lang="ko">
      <body>
        {isClerkConfigured()
          ? <ClerkProvider appearance={appearance}>{body}</ClerkProvider>
          : body}
      </body>
    </html>
  );
}
