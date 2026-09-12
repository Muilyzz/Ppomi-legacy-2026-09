import { SignUp } from '@clerk/nextjs';
import { SetupPanel } from '@/components/setup-panel';
import { isClerkConfigured } from '@/lib/clerk-env';
import { clerkAfterAuthUrl } from '@/lib/clerk-handoff';

export default async function SignUpPage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string }>;
}) {
  if (!isClerkConfigured()) return <SetupPanel />;
  const { from } = await searchParams;
  const redirect = clerkAfterAuthUrl(from);
  return (
    <div className="center">
      <SignUp forceRedirectUrl={redirect} fallbackRedirectUrl={redirect} />
    </div>
  );
}
