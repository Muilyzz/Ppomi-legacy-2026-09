import { SignIn } from '@clerk/nextjs';
import { CLERK_ACCOUNT_REDIRECT, isClerkConfigured } from '@/lib/clerk-env';
import { SetupPanel } from '@/components/setup-panel';

export default function SignInPage() {
  if (!isClerkConfigured()) return <SetupPanel />;
  return (
    <div className="center">
      <SignIn forceRedirectUrl={CLERK_ACCOUNT_REDIRECT} fallbackRedirectUrl={CLERK_ACCOUNT_REDIRECT} />
    </div>
  );
}
