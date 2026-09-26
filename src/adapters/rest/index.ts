import { restEnv } from '@/lib/env';
import type { Backend } from '@/ports';
import { createRestAuth } from './auth';
import { createRestCatalog } from './catalog';
import { createRestClient } from './http';
import { createRestOrders } from './orders';
import { createRestRealtime, type RestRealtimeOptions } from './realtime';
import { createRestSales } from './sales';
import { createSessionStore, type StorageLike } from './session';
import { createRestSessions } from './sessions';
import { createRestSettings } from './settings';
import { createRestTerminals } from './terminals';

export { pollRetryDelayMs } from './realtime';
export type { RestRealtimeOptions } from './realtime';
export { REST_SESSION_STORAGE_KEY } from './session';
export type { RestSession, RestSessionStore, StorageLike } from './session';

/** Every path of this adapter hangs off the API's version prefix (contracts/openapi.yaml). */
const API_PREFIX = '/api/v1';

export interface RestBackendOptions {
  /** Where the API is, without the /api/v1 prefix. Default: VITE_API_BASE_URL. */
  readonly baseUrl?: string;
  /** Default: the global fetch. Tests pass their own, or let MSW answer this one. */
  readonly fetch?: typeof fetch;
  /** Where this device keeps its session. Default: localStorage, as for the app. */
  readonly storage?: () => StorageLike;
  /** The key the session is kept under. Default: REST_SESSION_STORAGE_KEY. */
  readonly storageKey?: string;
  /** How often live updates are polled for. Default: the values in realtime.ts. */
  readonly realtime?: RestRealtimeOptions;
}

/**
 * The REST backend: the HTTP API of contracts/openapi.yaml behind every port, which the Symfony
 * server in api/ serves. The wire is snake_case and the ports are camelCase, so every request goes out
 * through `keysToSnake` and every answer comes back through `keysToCamel` and a port schema; the
 * bearer token of the signed-in member goes with each request, and the server decides everything
 * else.
 */
export function createRestBackend(options: RestBackendOptions = {}): Backend {
  const baseUrl = (options.baseUrl ?? restEnv().baseUrl).replace(/\/+$/, '');
  const session = createSessionStore(options.storage ?? (() => localStorage), options.storageKey);
  const client = createRestClient({
    baseUrl: `${baseUrl}${API_PREFIX}`,
    fetch: options.fetch,
    getToken: () => session.read()?.accessToken ?? null,
  });

  return {
    kind: 'rest',
    auth: createRestAuth({ client, session }),
    catalog: createRestCatalog(client),
    orders: createRestOrders(client),
    // No socket: this service is asked what changed, so live updates are a poll (realtime.ts).
    realtime: createRestRealtime(client, options.realtime),
    sales: createRestSales(client),
    sessions: createRestSessions(client),
    settings: createRestSettings(client),
    terminals: createRestTerminals(client),
  };
}
