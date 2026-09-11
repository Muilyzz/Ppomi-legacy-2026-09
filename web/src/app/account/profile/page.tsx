import { redirect } from 'next/navigation';
import { UserProfile } from '@clerk/nextjs';
import { auth } from '@clerk/nextjs/server';
import { SetupPanel } from '@/components/setup-panel';
import { isClerkConfigured } from '@/lib/clerk-env';

export default async function AccountProfilePage() {
  if (!isClerkConfigured()) return <SetupPanel />;
  const session = await auth();
  if (!session.userId) redirect('/sign-in');
  return (
    <div className="center">
      <UserProfile />
    </div>
  );
}
