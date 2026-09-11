import { SignIn } from '@clerk/nextjs';
import { isClerkConfigured } from '@/lib/clerk-env';
import { SetupPanel } from '@/components/setup-panel';

export default function SignInPage() {
  if (!isClerkConfigured()) return <SetupPanel />;
  return (
    <div className="center">
      <SignIn />
    </div>
  );
}
