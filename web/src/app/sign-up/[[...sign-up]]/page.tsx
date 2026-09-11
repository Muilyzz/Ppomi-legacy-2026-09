import { SignUp } from '@clerk/nextjs';
import { CLERK_ACCOUNT_REDIRECT, isClerkConfigured } from '@/lib/clerk-env';
import { SetupPanel } from '@/components/setup-panel';

export default function SignUpPage() {
  if (!isClerkConfigured()) return <SetupPanel />;
  return (
    <div className="center">
      <SignUp forceRedirectUrl={CLERK_ACCOUNT_REDIRECT} fallbackRedirectUrl={CLERK_ACCOUNT_REDIRECT} />
    </div>
  );
}
