import { isClerkConfigured } from '@/lib/clerk-env';
import { SetupPanel } from '@/components/setup-panel';

export default function HomePage() {
  if (!isClerkConfigured()) return <SetupPanel />;
  return (
    <section className="hero">
      <h1>Clerk가 본인증입니다</h1>
      <p className="meta">
        Google · Apple · Microsoft는 Clerk Dashboard에서 켭니다.
        Supabase는 Postgres / RLS / Realtime / Vault만 담당합니다.
        기록 암호는 서버 키(MZZ-27)를 유지합니다.
      </p>
      <p><a href="/account">보호된 계정 화면</a>에서 UserButton을 확인하세요.</p>
    </section>
  );
}
