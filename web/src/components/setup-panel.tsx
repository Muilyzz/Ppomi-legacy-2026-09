import { SECRETS_THE_OPERATOR_MUST_ADD } from '@/lib/clerk-env';
import { IDENTITY_PROVIDERS } from '@/lib/providers';

export function SetupPanel() {
  return (
    <section className="panel">
      <h1>Clerk 키가 아직 없습니다</h1>
      <p>
        이 스파이크는 브리지만 증명합니다. 실제 키를 저장소에 넣지 않습니다.
        Clerk Dashboard에서 앱을 만든 뒤 <code>web/.env.local</code>에만 붙이세요.
      </p>
      <ol>
        {SECRETS_THE_OPERATOR_MUST_ADD.map(item => (
          <li key={item.name}>
            <code>{item.name}</code>
            <span> — {item.where}</span>
          </li>
        ))}
      </ol>
      <p className="meta">
        경로 변수는 예시 값을 그대로 써도 됩니다:
        <code> /sign-in </code>
        <code> /sign-up </code>
        <code> /account </code>
      </p>
      <h2>대시보드에서 켤 IdP</h2>
      <ul>
        {IDENTITY_PROVIDERS.filter(provider => provider.slice === 1).map(provider => (
          <li key={provider.id}>{provider.label}: {provider.dashboard}</li>
        ))}
      </ul>
      <p className="meta">자세히: <code>docs/clerk-migration.md</code></p>
    </section>
  );
}
