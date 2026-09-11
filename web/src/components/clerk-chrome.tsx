'use client';

import { SignedIn, SignedOut, SignInButton, SignUpButton, UserButton } from '@clerk/nextjs';
import { CLERK_ACCOUNT_REDIRECT } from '@/lib/clerk-env';

export function ClerkChrome() {
  return (
    <div className="chrome">
      <SignedOut>
        <SignInButton mode="redirect" forceRedirectUrl={CLERK_ACCOUNT_REDIRECT}>
          <button type="button" className="ghost">로그인</button>
        </SignInButton>
        <SignUpButton mode="redirect" forceRedirectUrl={CLERK_ACCOUNT_REDIRECT}>
          <button type="button" className="cta">가입</button>
        </SignUpButton>
      </SignedOut>
      <SignedIn>
        <UserButton />
      </SignedIn>
    </div>
  );
}
