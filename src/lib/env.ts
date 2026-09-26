import { AppError } from './errors';

/**
 * `rest` is the café: the Symfony server in api/. `memory` is a backend that lives in the browser tab,
 * for the credential-free demo and the tests; it stores nothing anywhere else.
 */
export type BackendKind = 'memory' | 'rest';

const BACKEND_KINDS: readonly string[] = ['memory', 'rest'];

function isBackendKind(value: string): value is BackendKind {
  return BACKEND_KINDS.includes(value);
}

/** The adapter the composition root builds, from VITE_BACKEND (default: rest). */
export function backendKind(): BackendKind {
  const value = import.meta.env.VITE_BACKEND ?? 'rest';
  if (!isBackendKind(value)) {
    throw new AppError('CONFIG_ERROR', `VITE_BACKEND must be rest or memory; got "${value}".`);
  }
  return value;
}

function required(name: string, value: string | undefined): string {
  if (!value) {
    throw new AppError(
      'CONFIG_ERROR',
      `Missing ${name}: copy .env.example to .env and fill it in.`,
    );
  }
  return value;
}

/**
 * Where the REST API lives, without the `/api/v1` prefix the adapter adds: an absolute origin, e.g.
 * `http://127.0.0.1:8000`, since the app has no page to resolve a relative one against.
 */
export function restEnv(): { baseUrl: string } {
  return {
    baseUrl: required('VITE_API_BASE_URL', import.meta.env.VITE_API_BASE_URL).replace(/\/+$/, ''),
  };
}
