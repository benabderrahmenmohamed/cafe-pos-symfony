/**
 * The port contract against the REST adapter, with MSW answering contracts/openapi.yaml.
 *
 * `createFakeApi` stands in for the server here, so nothing has to be started: it serves the OpenAPI
 * shapes and statuses over the memory backend's ledger (src/adapters/rest/fakeApi.ts). What this
 * proves is therefore the adapter and the wire format — the paths, the bearer token, snake_case out
 * and camelCase in, the port schemas, 201 against 200, and every error code read back from the
 * envelope — against the same suite the memory backend passes unchanged. live.contract.test.ts
 * runs that suite against the real server.
 */
import { setupServer } from 'msw/node';
import { afterAll, afterEach, beforeAll, describe, vi } from 'vitest';
import { describeBackendContract, type ContractFixture } from '@/ports/__contracts__';
import { createFakeApi, demoFixture } from './fakeApi';

vi.setConfig({ testTimeout: 20_000, hookTimeout: 20_000 });

const server = setupServer();

beforeAll(() => {
  // A request this API does not serve is a mistake in the adapter, not something to let through.
  server.listen({ onUnhandledRequest: 'error' });
});
afterEach(() => {
  server.resetHandlers();
});
afterAll(() => {
  server.close();
});

/** A fresh API with data of its own for every test, and one device per role signed in on it. */
async function makeFixture(): Promise<ContractFixture> {
  const api = createFakeApi();
  server.use(...api.handlers);
  return demoFixture(api);
}

describe('REST backend', () => {
  describeBackendContract(makeFixture);
});
