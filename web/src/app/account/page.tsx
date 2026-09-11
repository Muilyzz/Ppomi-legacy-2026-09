import { redirect } from 'next/navigation';
import { auth } from '@clerk/nextjs/server';
import { AccountPanel } from '@/components/account-panel';
import { SetupPanel } from '@/components/setup-panel';
import { isClerkConfigured } from '@/lib/clerk-env';

export default async function AccountPage() {
  if (!isClerkConfigured()) return <SetupPanel />;
  const { userId } = await auth.protect();
  if (!userId) redirect('/sign-in');
  return <AccountPanel userId={userId} />;
}
