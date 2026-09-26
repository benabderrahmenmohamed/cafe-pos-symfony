/**
 * The port contract against a REST service that is actually running — the Symfony server in `api/`,
 * or any other that serves contracts/openapi.yaml.
 *
 * Runs only with CONTRACT_BACKEND=rest and is skipped otherwise. It reads API_BASE_URL, which is
 * http://127.0.0.1:8000 unless it is set, and signs in the demo accounts that `php bin/console
 * app:seed-demo` creates.
 *
 * `contract.test.ts` next to this file runs the same suite against `createFakeApi`, which serves the
 * OpenAPI shapes over the memory backend. That one proves the adapter; this one proves a server. The
 * suite is the same, unchanged, so the two answer the same question about two different things.
 *
 * Every test takes a table and a terminal code of its own, so runs never share receipt numbering and
 * nothing has to be reset between them: the sales, sessions and products a run leaves behind are the
 * ledger doing its job.
 */
import { describe, vi } from 'vitest';
import type { AuthUser, Backend } from '@/ports';
import {
  contractBackendIs,
  describeBackendContract,
  freshTerminalCode,
  testEnvOr,
  type ContractFixture,
} from '@/ports/__contracts__';
import { createRestBackend, type StorageLike } from './index';

vi.setConfig({ testTimeout: 30_000, hookTimeout: 30_000 });

/** Where the tables this fixture adds sit in the room: after every table the café was seeded with. */
const CONTRACT_TABLE_SORT_ORDER = 100;

/** Storage for one device's session, in this process only. */
function memoryStorage(): StorageLike {
  const items = new Map<string, string>();
  return {
    getItem: (key) => items.get(key) ?? null,
    setItem: (key, value) => {
      items.set(key, value);
    },
    removeItem: (key) => {
      items.delete(key);
    },
  };
}

/** A backend of its own — one device — signed in as `email`. */
async function device(
  email: string,
  password: string,
): Promise<{ readonly backend: Backend; readonly user: AuthUser }> {
  const storage = memoryStorage();
  const backend = createRestBackend({
    baseUrl: testEnvOr('API_BASE_URL', 'http://127.0.0.1:8000'),
    storage: () => storage,
    storageKey: `contract-${email}`,
  });
  const user = await backend.auth.signIn({ email, password });
  return { backend, user };
}

/** A name of the room no other run has used: the database keeps what earlier runs added. */
function freshTableName(): string {
  return `Contract ${crypto.randomUUID().slice(0, 8)}`;
}

async function makeFixture(): Promise<ContractFixture> {
  const admin = await device('admin@demo.local', 'demo-admin-2026');
  const cashier = await device('cashier@demo.local', 'demo-cashier-2026');
  const waiter = await device('waiter@demo.local', 'demo-waiter-2026');
  const kitchen = await device('kitchen@demo.local', 'demo-kitchen-2026');

  /**
   * A table of its own every time, added through the API as the admin. A retired one is created and
   * then retired, which is what an admin does — a table is retired, never deleted, because old sales
   * keep its name.
   */
  let added = 0;
  async function table(isActive: boolean) {
    added += 1;
    const created = await admin.backend.orders.createTable({
      name: freshTableName(),
      sortOrder: CONTRACT_TABLE_SORT_ORDER + added,
      isActive: true,
    });
    return isActive
      ? created
      : admin.backend.orders.updateTable(created.id, {
          name: created.name,
          sortOrder: created.sortOrder,
          isActive: false,
        });
  }

  return {
    admin: admin.backend,
    cashier: cashier.backend,
    waiter: waiter.backend,
    kitchen: kitchen.backend,
    adminUser: admin.user,
    cashierUser: cashier.user,
    waiterUser: waiter.user,
    kitchenUser: kitchen.user,
    newTerminalCode: freshTerminalCode,
    newTable: () => table(true),
    retiredTable: () => table(false),
  };
}

describe.runIf(contractBackendIs('rest'))('REST backend, live', () => {
  describeBackendContract(makeFixture);
});
