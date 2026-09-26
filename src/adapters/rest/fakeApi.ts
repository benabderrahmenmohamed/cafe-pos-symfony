import { http, HttpResponse, type JsonBodyType, type PathParams, type RequestHandler } from 'msw';
import { z } from 'zod';
import { createMemoryBackend, type MemoryBackend } from '@/adapters/memory';
import { camelToSnake, keysToCamel, keysToSnake } from '@/lib/caseConversion';
import { AppError, toAppError, type ErrorCode } from '@/lib/errors';
import { parseOrInvalid } from '@/lib/validation';
import {
  categoryInputSchema,
  closeSessionRecordSchema,
  credentialsSchema,
  diningTableInputSchema,
  hasRole,
  listSalesQuerySchema,
  openSessionRecordSchema,
  orderCancelRecordSchema,
  orderItemAddRecordSchema,
  orderItemPrepareRecordSchema,
  orderItemRemoveRecordSchema,
  orderSendRecordSchema,
  productCreateInputSchema,
  productUpdateInputSchema,
  removedAfterSentQuerySchema,
  saleRecordSchema,
  shopSettingsSchema,
  stockAdjustmentSchema,
  voidReceiptInputSchema,
  type AuthUser,
  type Backend,
  type DemoAccount,
  type DiningTable,
  type RealtimeTopic,
  type Role,
} from '@/ports';
import { freshTerminalCode, type ContractFixture } from '@/ports/__contracts__';
import { createRestBackend } from './index';
import type { StorageLike } from './session';
import { HTTP_CREATED } from './writes';

/*
 * A fake of contracts/openapi.yaml for tests, as MSW handlers, so the REST adapter is tested with no
 * server running: it answers the shapes and statuses of the OpenAPI file over the memory
 * backend, which is the reference implementation of every port (its ledger, its order of checks and
 * its errors are the ones contracts/errors.md describes). The handlers only translate — bearer
 * token to a signed-in client, snake_case to camelCase and back, AppError to the error envelope and
 * its status — so a test that runs the port contract suite through them tests this adapter rather
 * than a second ledger written for the occasion.
 *
 * Nothing here ships: it is imported by tests only, never by src/lib/backend.ts.
 */

/** Where the fake API answers. Tests hand this to `createRestBackend`. */
export const FAKE_API_BASE_URL = 'http://rest.test';

const HTTP_OK = 200;
const HTTP_NO_CONTENT = 204;
const HTTP_SERVER_ERROR = 500;

/**
 * The status contracts/errors.md gives each code a server may send. The codes outside this table —
 * NETWORK_ERROR, CONFIG_ERROR, UNKNOWN — are the client's own and are not in the OpenAPI enum, so a
 * server that hits one has failed on its own: that is a 500 SERVER_ERROR on the wire.
 */
const WIRE_STATUS: Partial<Record<ErrorCode, number>> = {
  SERVER_ERROR: HTTP_SERVER_ERROR,
  RATE_LIMITED: 429,
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  VALIDATION_ERROR: 422,
  IDEMPOTENCY_CONFLICT: 409,
  SEQUENCE_GAP: 409,
  SESSION_CLOSED: 409,
  SESSION_ALREADY_OPEN: 409,
  TERMINAL_SUPERSEDED: 409,
  ORDER_CHANGED: 409,
  ORDER_CLOSED: 409,
  ITEM_NOT_FOUND: 404,
  TABLE_INACTIVE: 409,
};

/** The body of `PUT /products/{id}/availability`, which is the toggle and nothing else. */
const availabilitySchema = z.object({ isAvailable: z.boolean() });

/** A poll's cursor: how many changes this API had recorded when it handed the cursor out. */
const cursorSchema = z.string().regex(/^\d+$/, 'That is not a cursor this API handed out');

/**
 * A port value on the wire: snake_case keys at any depth, values untouched. The cast says what
 * renaming keys cannot prove — a port DTO is JSON data, and renaming its keys keeps it JSON.
 */
function wire(value: unknown): JsonBodyType {
  return keysToSnake(value) as JsonBodyType;
}

function json(value: unknown, status: number): Response {
  return HttpResponse.json(wire(value), { status });
}

/** The error envelope of contracts/errors.md, with the status the code maps to. */
function errorResponse(error: AppError): Response {
  const code: ErrorCode = WIRE_STATUS[error.code] === undefined ? 'SERVER_ERROR' : error.code;
  return HttpResponse.json(
    { error: { code, message: error.message, details: wire(error.details) } },
    { status: WIRE_STATUS[code] ?? HTTP_SERVER_ERROR },
  );
}

/** Runs one request; every failure leaves as the envelope, as a real service would answer. */
function serve(body: () => Promise<Response>): Promise<Response> {
  return body().catch((error: unknown) => errorResponse(toAppError(error)));
}

/** The JSON body of a request, read into the camelCase shape the ports use. */
async function jsonBody(request: Request): Promise<unknown> {
  const text = await request.text();
  if (!text) {
    throw new AppError('VALIDATION_ERROR', 'The request carries no body.');
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text) as unknown;
  } catch (error) {
    throw new AppError('VALIDATION_ERROR', 'The request body is not JSON.', { cause: error });
  }
  return keysToCamel(parsed);
}

/** One path parameter; MSW types a repeated segment as an array, and these routes have none. */
function param(params: PathParams, name: string): string {
  const value = params[name];
  if (typeof value !== 'string') {
    throw new AppError('UNKNOWN', `This route has no ${name} parameter.`);
  }
  return value;
}

/** A Member as the OpenAPI file defines it; `wire` renames the keys. */
function memberOf(user: AuthUser): object {
  return {
    userId: user.id,
    shopId: user.shopId,
    roles: user.roles,
    displayName: user.name,
    email: user.email,
  };
}

/**
 * A record write whose path repeats an id its body carries. The two must agree: a service routing
 * on the path and acting on the body would otherwise act on something the caller did not address.
 */
function requirePathMatches(params: PathParams, name: string, inBody: string): void {
  if (param(params, name) !== inBody) {
    throw new AppError('VALIDATION_ERROR', 'The record names another resource than the path.', {
      // The field as the error envelope of contracts/errors.md names it: snake_case, like the body.
      details: { field: camelToSnake(name) },
    });
  }
}

/** A record write's answer: 201 for the one this call stored, 200 for an outcome already stored. */
function written(result: { readonly status: string }, createdStatus: string): Response {
  return json(result, result.status === createdStatus ? HTTP_CREATED : HTTP_OK);
}

export interface FakeApiOptions {
  /** Where the API answers; default: FAKE_API_BASE_URL. */
  readonly baseUrl?: string;
  /** The data behind it; default: a new memory backend with the demo seed. */
  readonly backend?: MemoryBackend;
  /** What the token endpoint promises, in seconds; default: an hour. */
  readonly expiresIn?: number;
}

export interface FakeApi {
  readonly baseUrl: string;
  /** The shared data. Its `demoAccounts` are the sign-ins this API accepts. */
  readonly backend: MemoryBackend;
  /** For `setupServer(...)` or `server.use(...)`. */
  readonly handlers: readonly RequestHandler[];
  /** How many sign-ins this API has handed a token to. */
  tokenCount(): number;
}

/** One signed-in device: its own client of the shared data, like one browser. */
interface FakeClient {
  readonly backend: Backend;
  readonly user: AuthUser;
}

/** An API of its own, with data of its own. Every call builds a new one. */
export function createFakeApi(options: FakeApiOptions = {}): FakeApi {
  const baseUrl = (options.baseUrl ?? FAKE_API_BASE_URL).replace(/\/+$/, '');
  const backend = options.backend ?? createMemoryBackend();
  const expiresIn = options.expiresIn ?? 3600;
  const api = `${baseUrl}/api/v1`;
  const clients = new Map<string, FakeClient>();
  /** Every change a shop has seen since this API first answered a poll for it, in order. */
  const changes = new Map<string, RealtimeTopic[]>();

  /** The member the request's bearer token belongs to. */
  function clientOf(request: Request): FakeClient {
    const header = request.headers.get('Authorization') ?? '';
    const prefix = 'Bearer ';
    const client = header.startsWith(prefix) ? clients.get(header.slice(prefix.length)) : undefined;
    if (!client) {
      throw new AppError('UNAUTHENTICATED', 'This request carries no session.');
    }
    return client;
  }

  /**
   * The shop's change log, watched from the first poll on. A real service would keep this in the
   * database; here the memory backend's emitter is the publication, which is what a client polling
   * `?since=` reads instead of holding a connection open. Watching only from the first poll is the
   * behaviour the port asks for: a subscriber's first answer is a cursor, never a backlog.
   */
  function changesOf(shopId: string): RealtimeTopic[] {
    const watched = changes.get(shopId);
    if (watched) {
      return watched;
    }
    const log: RealtimeTopic[] = [];
    changes.set(shopId, log);
    // Never unsubscribed: the emitter belongs to this API's backend and dies with it.
    backend.realtime.subscribe(shopId, (topic) => {
      log.push(topic);
    });
    return log;
  }

  const handlers: RequestHandler[] = [
    http.post(`${api}/auth/token`, ({ request }) =>
      serve(async () => {
        const credentials = parseOrInvalid(
          credentialsSchema,
          await jsonBody(request),
          'the credentials',
        );
        // A client of its own per token: one device holds one session, as a browser does.
        const client = backend.connect();
        const user = await client.auth.signIn(credentials);
        const accessToken = crypto.randomUUID();
        clients.set(accessToken, { backend: client, user });
        return json(
          { accessToken, tokenType: 'bearer', expiresIn, member: memberOf(user) },
          HTTP_OK,
        );
      }),
    ),

    http.get(`${api}/me`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const state = await client.backend.auth.getState();
        if (state.status !== 'authenticated') {
          throw new AppError('UNAUTHENTICATED', 'This session has ended.');
        }
        return json(memberOf(state.user), HTTP_OK);
      }),
    ),

    http.get(`${api}/products`, ({ request }) =>
      serve(async () => json(await clientOf(request).backend.catalog.listProducts(), HTTP_OK)),
    ),

    http.post(`${api}/products`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const input = parseOrInvalid(
          productCreateInputSchema,
          await jsonBody(request),
          'the product',
        );
        return json(await client.backend.catalog.createProduct(input), HTTP_CREATED);
      }),
    ),

    http.put(`${api}/products/:productId`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        const input = parseOrInvalid(
          productUpdateInputSchema,
          await jsonBody(request),
          'the product',
        );
        const product = await client.backend.catalog.updateProduct(
          param(params, 'productId'),
          input,
        );
        return json(product, HTTP_OK);
      }),
    ),

    http.delete(`${api}/products/:productId`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        await client.backend.catalog.deleteProduct(param(params, 'productId'));
        return new HttpResponse(null, { status: HTTP_NO_CONTENT });
      }),
    ),

    http.put(`${api}/products/:productId/availability`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        const { isAvailable } = parseOrInvalid(
          availabilitySchema,
          await jsonBody(request),
          'the availability',
        );
        const product = await client.backend.catalog.setAvailability(
          param(params, 'productId'),
          isAvailable,
        );
        return json(product, HTTP_OK);
      }),
    ),

    http.post(`${api}/stock-adjustments`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const record = parseOrInvalid(
          stockAdjustmentSchema,
          await jsonBody(request),
          'the stock correction',
        );
        return written(await client.backend.catalog.adjustStock(record), 'created');
      }),
    ),

    http.get(`${api}/categories`, ({ request }) =>
      serve(async () => json(await clientOf(request).backend.catalog.listCategories(), HTTP_OK)),
    ),

    http.post(`${api}/categories`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const input = parseOrInvalid(categoryInputSchema, await jsonBody(request), 'the category');
        return json(await client.backend.catalog.createCategory(input), HTTP_CREATED);
      }),
    ),

    http.delete(`${api}/categories/:categoryId`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        await client.backend.catalog.deleteCategory(param(params, 'categoryId'));
        return new HttpResponse(null, { status: HTTP_NO_CONTENT });
      }),
    ),

    http.get(`${api}/dining-tables`, ({ request }) =>
      serve(async () => json(await clientOf(request).backend.orders.listTables(), HTTP_OK)),
    ),

    http.post(`${api}/dining-tables`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const input = parseOrInvalid(diningTableInputSchema, await jsonBody(request), 'the table');
        return json(await client.backend.orders.createTable(input), HTTP_CREATED);
      }),
    ),

    http.put(`${api}/dining-tables/:tableId`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        const input = parseOrInvalid(diningTableInputSchema, await jsonBody(request), 'the table');
        const table = await client.backend.orders.updateTable(param(params, 'tableId'), input);
        return json(table, HTTP_OK);
      }),
    ),

    http.get(`${api}/table-board`, ({ request }) =>
      serve(async () => json(await clientOf(request).backend.orders.board(), HTTP_OK)),
    ),

    http.get(`${api}/dining-tables/:tableId/open-order`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        // A free table answers null rather than 404: having nothing on it is not an error.
        const order = await client.backend.orders.openOrder(param(params, 'tableId'));
        return json(order, HTTP_OK);
      }),
    ),

    http.post(`${api}/order-items`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const record = parseOrInvalid(
          orderItemAddRecordSchema,
          await jsonBody(request),
          'the add record',
        );
        return written(await client.backend.orders.addItem(record), 'created');
      }),
    ),

    http.post(`${api}/order-items/:itemId/removals`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        const record = parseOrInvalid(
          orderItemRemoveRecordSchema,
          await jsonBody(request),
          'the removal record',
        );
        requirePathMatches(params, 'itemId', record.itemId);
        return written(await client.backend.orders.removeItem(record), 'created');
      }),
    ),

    http.post(`${api}/order-items/:itemId/preparations`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        const record = parseOrInvalid(
          orderItemPrepareRecordSchema,
          await jsonBody(request),
          'the prepare record',
        );
        requirePathMatches(params, 'itemId', record.itemId);
        return written(await client.backend.orders.prepareItem(record), 'created');
      }),
    ),

    http.post(`${api}/dining-tables/:tableId/sends`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        const record = parseOrInvalid(
          orderSendRecordSchema,
          await jsonBody(request),
          'the send record',
        );
        requirePathMatches(params, 'tableId', record.tableId);
        return written(await client.backend.orders.send(record), 'created');
      }),
    ),

    http.post(`${api}/dining-tables/:tableId/cancellations`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        const record = parseOrInvalid(
          orderCancelRecordSchema,
          await jsonBody(request),
          'the cancel record',
        );
        requirePathMatches(params, 'tableId', record.tableId);
        return written(await client.backend.orders.cancelOrder(record), 'created');
      }),
    ),

    http.get(`${api}/open-orders`, ({ request }) =>
      serve(() => {
        const client = clientOf(request);
        const log = changesOf(client.user.shopId);
        const since = new URL(request.url).searchParams.get('since');
        // Without a cursor the caller is starting: it gets today's cursor and no backlog.
        const read =
          since === null ? log.length : Number(parseOrInvalid(cursorSchema, since, 'the cursor'));
        // Each topic once, however many rows of it changed: the client re-reads, it does not apply.
        const topics = [...new Set(log.slice(read))];
        return Promise.resolve(json({ cursor: String(log.length), topics }, HTTP_OK));
      }),
    ),

    http.get(`${api}/kitchen-tickets`, ({ request }) =>
      serve(async () => json(await clientOf(request).backend.orders.kitchenTickets(), HTTP_OK)),
    ),

    http.get(`${api}/reports/removed-after-sent-items`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const search = new URL(request.url).searchParams;
        const query = parseOrInvalid(
          removedAfterSentQuerySchema,
          { from: search.get('from') ?? '', to: search.get('to') ?? '' },
          'the report period',
        );
        return json(await client.backend.orders.removedAfterSent(query), HTTP_OK);
      }),
    ),

    http.get(`${api}/shop-settings`, ({ request }) =>
      serve(async () => json(await clientOf(request).backend.settings.getSettings(), HTTP_OK)),
    ),

    http.put(`${api}/shop-settings`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const input = parseOrInvalid(shopSettingsSchema, await jsonBody(request), 'the settings');
        return json(await client.backend.settings.updateSettings(input), HTTP_OK);
      }),
    ),

    http.post(`${api}/terminals/:terminalCode/registrations`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        const registration = await client.backend.terminals.register(param(params, 'terminalCode'));
        return json(registration, HTTP_CREATED);
      }),
    ),

    http.get(`${api}/cash-sessions`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const query = new URL(request.url).searchParams;
        const terminalId = query.get('terminal_id');
        if (terminalId === null) {
          throw new AppError('VALIDATION_ERROR', 'terminal_id is required.', {
            details: { field: 'terminal_id' },
          });
        }
        if (query.get('status') !== 'open') {
          // The ports ask for the open session only; this fake serves nothing it cannot answer.
          throw new AppError('VALIDATION_ERROR', 'This API lists sessions with status=open only.', {
            details: { field: 'status' },
          });
        }
        const session = await client.backend.sessions.current(terminalId);
        return json(session === null ? [] : [session], HTTP_OK);
      }),
    ),

    http.post(`${api}/cash-sessions`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const record = parseOrInvalid(
          openSessionRecordSchema,
          await jsonBody(request),
          'the session record',
        );
        return written(await client.backend.sessions.open(record), 'created');
      }),
    ),

    http.post(`${api}/cash-sessions/:sessionId/closures`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        const record = parseOrInvalid(
          closeSessionRecordSchema,
          await jsonBody(request),
          'the close record',
        );
        if (record.sessionId !== param(params, 'sessionId')) {
          throw new AppError(
            'VALIDATION_ERROR',
            'The record names another session than the path.',
            {
              details: { field: 'session_id' },
            },
          );
        }
        return written(await client.backend.sessions.close(record), 'created');
      }),
    ),

    http.get(`${api}/cash-sessions/:sessionId/z-report`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        const report = await client.backend.sessions.zReport(param(params, 'sessionId'));
        return json(report, HTTP_OK);
      }),
    ),

    http.get(`${api}/sales`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const search = new URL(request.url).searchParams;
        const limit = search.get('limit');
        const query = parseOrInvalid(
          listSalesQuerySchema,
          {
            terminalId: search.get('terminal_id') ?? undefined,
            sessionId: search.get('session_id') ?? undefined,
            tableId: search.get('table_id') ?? undefined,
            limit: limit === null ? undefined : Number(limit),
          },
          'the sales query',
        );
        return json(await client.backend.sales.listSales(query), HTTP_OK);
      }),
    ),

    http.post(`${api}/sales`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const record = parseOrInvalid(saleRecordSchema, await jsonBody(request), 'the sale record');
        return written(await client.backend.sales.recordSale(record), 'created');
      }),
    ),

    http.get(`${api}/sales/:saleId`, ({ request, params }) =>
      serve(async () => {
        const client = clientOf(request);
        return json(await client.backend.sales.getSale(param(params, 'saleId')), HTTP_OK);
      }),
    ),

    http.post(`${api}/receipt-voids`, ({ request }) =>
      serve(async () => {
        const client = clientOf(request);
        const input = parseOrInvalid(voidReceiptInputSchema, await jsonBody(request), 'the void');
        return written(await client.backend.sales.voidReceipt(input), 'voided');
      }),
    ),
  ];

  return { baseUrl, backend, handlers, tokenCount: () => clients.size };
}

/** A session store of one device, in this process only. */
export function memoryStorage(): StorageLike {
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

/** A REST backend of its own — one device — signed in as `account` against `api`. */
export async function signInDemo(api: FakeApi, account: DemoAccount): Promise<FakeMember> {
  const storage = memoryStorage();
  const backend = createRestBackend({
    baseUrl: api.baseUrl,
    storage: () => storage,
    storageKey: `rest-${account.email}`,
  });
  const user = await backend.auth.signIn({ email: account.email, password: account.password });
  return { backend, user, account };
}

/** One device, signed in, as the contract fixture and the adapter's own tests see it. */
export interface FakeMember {
  readonly backend: Backend;
  readonly user: AuthUser;
  readonly account: DemoAccount;
}

/** Where the tables this fixture adds sit in the room: after every table the shop was seeded with. */
const CONTRACT_TABLE_SORT_ORDER = 100;

/**
 * Hands out a table of its own every time, added through the API as the admin, so no two tests of a
 * run share a board. A retired one is created and then retired, which is what an admin does — a
 * table is retired, never deleted, because old sales keep its name.
 */
function tableSource(admin: Backend): (isActive: boolean) => Promise<DiningTable> {
  let added = 0;
  return async function next(isActive: boolean): Promise<DiningTable> {
    added += 1;
    const input = {
      name: `Contract table ${added}`,
      sortOrder: CONTRACT_TABLE_SORT_ORDER + added,
      isActive: true,
    };
    const table = await admin.orders.createTable(input);
    return isActive ? table : admin.orders.updateTable(table.id, { ...input, isActive: false });
  };
}

/**
 * The fixture the port contract suite runs on: one shop, seen through one REST backend per role —
 * one device each, with its own token, as four people on four phones. The API's handlers must
 * already be installed.
 */
export async function demoFixture(api: FakeApi): Promise<ContractFixture> {
  const members: FakeMember[] = [];
  for (const account of api.backend.demoAccounts) {
    members.push(await signInDemo(api, account));
  }
  const admin = members.find((member) => hasRole(member.user, ['admin']));
  if (!admin) {
    throw new AppError('CONFIG_ERROR', 'This API offers no demo admin to run the contract as.');
  }
  const shopId = admin.user.shopId;
  /** The member of that shop who holds `role` and nothing else, so a refusal is unambiguous. */
  function only(role: Role): FakeMember {
    const member = members.find(
      (candidate) =>
        candidate.user.shopId === shopId &&
        candidate.user.roles.length === 1 &&
        hasRole(candidate.user, [role]),
    );
    if (!member) {
      throw new AppError(
        'CONFIG_ERROR',
        `This API offers no demo member of one shop whose only role is ${role}.`,
      );
    }
    return member;
  }
  const cashier = only('cashier');
  const waiter = only('waiter');
  const kitchen = only('kitchen');
  const nextTable = tableSource(admin.backend);

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
    newTable: () => nextTable(true),
    retiredTable: () => nextTable(false),
  };
}
