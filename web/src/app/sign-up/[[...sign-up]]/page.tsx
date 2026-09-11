import { SignUp } from '@clerk/nextjs';
import { isClerkConfigured } from '@/lib/clerk-env';
import { SetupPanel } from '@/components/setup-panel';

export default function SignUpPage() {
  if (!isClerkConfigured()) return <SetupPanel />;
  return (
    <div className="center">
      <SignUp />
    </div>
  );
}
