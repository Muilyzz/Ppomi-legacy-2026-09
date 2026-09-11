'use client';

import { SignedIn, SignedOut, SignInButton, SignUpButton, UserButton } from '@clerk/nextjs';

export function ClerkChrome() {
  return (
    <div className="chrome">
      <SignedOut>
        <SignInButton mode="redirect">
          <button type="button" className="ghost">로그인</button>
        </SignInButton>
        <SignUpButton mode="redirect">
          <button type="button" className="cta">가입</button>
        </SignUpButton>
      </SignedOut>
      <SignedIn>
        <UserButton afterSignOutUrl="/" />
      </SignedIn>
    </div>
  );
}
