/** Clerk Dashboard IdPs for this spike. Email backup is later. */

export type IdentityProvider = 'google' | 'apple' | 'microsoft' | 'email';

export type ProviderPlan = {
  id: IdentityProvider;
  label: string;
  slice: 1 | 'later';
  dashboard: string;
};

export const IDENTITY_PROVIDERS: readonly ProviderPlan[] = [
  {
    id: 'google',
    label: 'Google',
    slice: 1,
    dashboard: 'Clerk Dashboard → SSO connections → Google. Redirect URI from Clerk.',
  },
  {
    id: 'apple',
    label: 'Apple',
    slice: 1,
    dashboard: 'Clerk Dashboard → SSO connections → Apple. Services ID, Team ID, Key ID, .p8.',
  },
  {
    id: 'microsoft',
    label: 'Microsoft',
    slice: 1,
    dashboard: 'Clerk Dashboard → SSO connections → Microsoft. Azure app client ID/secret.',
  },
  {
    id: 'email',
    label: 'Email (backup)',
    slice: 'later',
    dashboard: 'Enable after Google/Apple/Microsoft work. Not required for this spike.',
  },
];

export function providerStatus(id: IdentityProvider): ProviderPlan {
  switch (id) {
    case 'google':
    case 'apple':
    case 'microsoft':
    case 'email':
      return IDENTITY_PROVIDERS.find(provider => provider.id === id)!;
    default: {
      const exhaustive: never = id;
      return exhaustive;
    }
  }
}
