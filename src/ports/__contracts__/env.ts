import { AppError } from '@/lib/errors';

type TestEnv = Readonly<Record<string, string | undefined>>;

/** The environment of the test process. Vitest runs in Node; a browser has no `process`. */
function testEnv(): TestEnv {
  const runtime = globalThis as unknown as { readonly process?: { readonly env?: TestEnv } };
  return runtime.process?.env ?? {};
}

/** True when CONTRACT_BACKEND names `backend`: its runners then run next to the memory one. */
export function contractBackendIs(backend: 'rest'): boolean {
  return testEnv().CONTRACT_BACKEND === backend;
}

/** A variable an enabled runner can do without: its default is what a local run wants anyway. */
export function testEnvOr(name: string, fallback: string): string {
  return testEnv()[name] ?? fallback;
}

/** A variable an enabled runner needs; CONFIG_ERROR naming it when it is not set. */
export function requireTestEnv(name: string): string {
  const value = testEnv()[name];
  if (!value) {
    throw new AppError('CONFIG_ERROR', `${name} is not set, and the contract runner needs it.`);
  }
  return value;
}
