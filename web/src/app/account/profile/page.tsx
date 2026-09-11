import { UserProfile } from '@clerk/nextjs';
import { auth } from '@clerk/nextjs/server';
import { SetupPanel } from '@/components/setup-panel';
import { isClerkConfigured } from '@/lib/clerk-env';

export default async function AccountProfilePage() {
  if (!isClerkConfigured()) return <SetupPanel />;
  await auth.protect();
  return (
    <div className="center">
      <UserProfile />
    </div>
  );
}
