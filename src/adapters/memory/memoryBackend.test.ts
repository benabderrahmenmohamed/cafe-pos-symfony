import { describe, expect, it, vi } from 'vitest';
import { addItem, emptyCart } from '@/features/caisse/cart';
import { buildSaleRecord } from '@/features/sales/records';
import { buildCloseSessionRecord, buildOpenSessionRecord } from '@/features/sessions/records';
import { AppError, isAppError, type ErrorCode } from '@/lib/errors';
import { mm } from '@/lib/money';
import { withPayloadHash } from '@/lib/payloadHash';
import type {
  AuthState,
  AuthUser,
  Category,
  CloseSessionRecord,
  Credentials,
  OpenSessionRecord,
  OrderCancelRecord,
  OrderItemAddRecord,
  OrderItemPrepareRecord,
  OrderItemRemoveRecord,
  OrderSendRecord,
  Product,
  ProductCreateInput,
  ProductUpdateInput,
  RealtimeTopic,
  Role,
  SaleRecord,
  StockAdjustment,
} from '@/ports';
import {
  createFaultInjector,
  createMemoryBackend,
  DEMO_SHOP_ID,
  defaultSeed,
  MEMORY_OPERATIONS,
  OTHER_SHOP_ID,
  type MemoryBackend,
  type MemoryOperation,
  type MemorySeed,
  type MemorySeedProduct,
} from './index';
import { defaultConnectivity, randomId } from './support';

const START = Date.UTC(2026, 8, 11, 9, 0, 0);
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

const ADMIN_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
const TABLE_1 = '77777777-7777-4777-8777-777777777701';
const TABLE_2 = '77777777-7777-4777-8777-777777777702';
const RETIRED_TABLE = '77777777-7777-4777-8777-777777777708';
const WATER = '55555555-5555-4555-8555-555555555501';
const CREME = '55555555-5555-4555-8555-555555555504';
const MAKROUDS = '55555555-5555-4555-8555-555555555507';
const OTHER_PRODUCT = '66666666-6666-4666-8666-666666666601';
const FRAICHES = '44444444-4444-4444-8444-444444444401';
const CHAUDES = '44444444-4444-4444-8444-444444444402';
const SNACKS = '44444444-4444-4444-8444-444444444403';
const PATISSERIE = '44444444-4444-4444-8444-444444444404';
const GENERAL = '44444444-4444-4444-8444-444444444411';

const CREDENTIALS = {
  // The owner: an admin who also works the counter, which is how the demo signs in as an admin.
  admin: { email: 'admin@demo.local', password: 'demo-admin-2026' },
  cashier: { email: 'cashier@demo.local', password: 'demo-cashier-2026' },
  waiter: { email: 'waiter@demo.local', password: 'demo-waiter-2026' },
  kitchen: { email: 'kitchen@demo.local', password: 'demo-kitchen-2026' },
  otherAdmin: { email: 'other-admin@demo.local', password: 'other-admin-2026' },
  otherCashier: { email: 'other-cashier@demo.local', password: 'other-cashier-2026' },
} satisfies Record<string, Credentials>;

/** The n-th id the test id source hands out. */
function idNo(n: number): string {
  return `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

/** A record id chosen by a test device. */
function recordId(n: number): string {
  return `dddddddd-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

const DEVICE_ID = 'device-memory-test';

/** The n-th order record this device writes: the fields of its kind, in the envelope every kind has. */
function orderRecord<Fields extends object>(
  n: number,
  fields: Fields,
): Promise<Fields & { id: string; deviceId: string; createdAt: string; payloadHash: string }> {
  return withPayloadHash({
    id: recordId(n),
    deviceId: DEVICE_ID,
    createdAt: isoAt(0),
    ...fields,
  });
}

/** A hand count as the admin writes it: a record like any other, so a retry cannot count twice. */
function stockCorrection(productId: string, qtyDelta: number): Promise<StockAdjustment> {
  return withPayloadHash({
    id: recordId(90),
    productId,
    qtyDelta,
    reason: 'Counted on the shelf',
  });
}

/** A seeded product as listProducts shows it. */
function listed(product: MemorySeedProduct): Product {
  return {
    id: product.id,
    name: product.name,
    priceMillimes: product.priceMillimes,
    categoryId: product.categoryId,
    categoryName:
      defaultSeed.categories.find((category) => category.id === product.categoryId)?.name ?? null,
    barcode: product.barcode,
    description: product.description,
    imageUrl: product.imageUrl,
    isAvailable: product.isAvailable,
    trackStock: product.trackStock,
    stockQty: product.stockQty,
    createdAt: product.createdAt,
    updatedAt: product.createdAt,
  };
}

function categoriesOf(shopId: string): Category[] {
  return defaultSeed.categories
    .filter((category) => category.shopId === shopId)
    .map(({ id, name, color, createdAt }) => ({ id, name, color, createdAt }));
}

const DEMO_PRODUCTS = defaultSeed.products
  .filter((product) => product.shopId === DEMO_SHOP_ID)
  .map(listed);
const OTHER_PRODUCTS = defaultSeed.products
  .filter((product) => product.shopId === OTHER_SHOP_ID)
  .map(listed);
const DEMO_CATEGORIES = categoriesOf(DEMO_SHOP_ID);
const OTHER_CATEGORIES = categoriesOf(OTHER_SHOP_ID);

/** A backend with a clock that ticks one second per read and ids idNo(1), idNo(2), … */
function setup(seed?: MemorySeed) {
  let ticks = 0;
  let ids = 0;
  const faults = createFaultInjector();
  /** The device's network, which a test takes down between calls. */
  const network = { online: true };
  const backend = createMemoryBackend({
    seed,
    faults,
    connectivity: () => network.online,
    now: () => {
      ticks += 1;
      return new Date(START + ticks * 1000);
    },
    newId: () => {
      ids += 1;
      return idNo(ids);
    },
  });
  return { backend, faults, network };
}

/** Who makes a call: nobody signed in, or the demo shop's account with that role. */
type Caller = 'signed out' | Role;

/** Signs in the demo shop's account with `role`, as the demo buttons of the login page do. */
function signInAs(backend: MemoryBackend, role: Role): Promise<AuthUser> {
  return backend.auth.signIn(CREDENTIALS[role]);
}

/** `setup()`, then signs `caller` in. */
async function setupAs(caller: Caller) {
  const result = setup();
  if (caller !== 'signed out') {
    await signInAs(result.backend, caller);
  }
  return result;
}

/** Another client of `backend`, signed in with `credentials`. */
async function clientAs(backend: MemoryBackend, credentials: Credentials): Promise<MemoryBackend> {
  const client = backend.connect();
  await client.auth.signIn(credentials);
  return client;
}

function isoAt(seconds: number): string {
  return new Date(START + seconds * 1000).toISOString();
}

/** 'resolved', or whatever the promise rejected with. */
function settle(promise: Promise<unknown>): Promise<unknown> {
  return promise.then(
    () => 'resolved',
    (error: unknown) => error,
  );
}

async function failure(promise: Promise<unknown>, code: ErrorCode): Promise<AppError> {
  const outcome = await settle(promise);
  if (!isAppError(outcome)) {
    return expect.unreachable(`Expected an AppError ${code}, got ${String(outcome)}`);
  }
  expect(outcome.code, outcome.message).toBe(code);
  return outcome;
}

/** 'resolved', or the code of the AppError the promise rejected with. */
async function outcomeOf(promise: Promise<unknown>): Promise<'resolved' | ErrorCode> {
  const outcome = await settle(promise);
  if (outcome === 'resolved') {
    return 'resolved';
  }
  if (!isAppError(outcome)) {
    return expect.unreachable(`Expected an AppError, got ${String(outcome)}`);
  }
  return outcome.code;
}

function signedInUser(state: AuthState): AuthUser {
  if (state.status === 'anonymous') {
    return expect.unreachable('Expected a signed-in state');
  }
  return state.user;
}

const makrouds: ProductCreateInput = {
  name: 'Makrouds maison',
  priceMillimes: mm(14_500),
  categoryId: SNACKS,
  barcode: '6194000300071',
  description: 'Kairouan',
  imageUrl: '',
  isAvailable: true,
  trackStock: true,
  openingStock: 30,
};

const cremeEdit: ProductUpdateInput = {
  name: 'Café crème',
  priceMillimes: mm(2_600),
  categoryId: SNACKS,
  barcode: '6194000300019',
  description: '',
  imageUrl: '',
  isAvailable: true,
  trackStock: true,
  stockDelta: 5,
};

/**
 * What the calls of `callFor` need, prepared by the admin on a client of its own: terminal T1 with
 * an open session and sale T1-1, terminal T2 without a session, table 1 with an item nobody has
 * sent yet, table 2 with an item the kitchen has, and records not yet sent.
 */
interface Prepared {
  readonly terminalId: string;
  readonly otherTerminalId: string;
  readonly sessionId: string;
  readonly saleId: string;
  readonly openOnT2: OpenSessionRecord;
  readonly closeT1: CloseSessionRecord;
  readonly nextSale: SaleRecord;
  readonly addOnTable1: OrderItemAddRecord;
  readonly removeOnTable1: OrderItemRemoveRecord;
  readonly sendTable1: OrderSendRecord;
  readonly prepareOnTable2: OrderItemPrepareRecord;
  readonly cancelTable1: OrderCancelRecord;
}

async function prepare(backend: MemoryBackend): Promise<Prepared> {
  const admin = await clientAs(backend, CREDENTIALS.admin);
  const t1 = await admin.terminals.register('T1');
  const t2 = await admin.terminals.register('T2');
  const terminal = { terminalCode: 'T1', epoch: 0 };
  const open = await buildOpenSessionRecord({
    id: recordId(1),
    terminal,
    actorUserId: ADMIN_ID,
    openedAt: isoAt(0),
    openingFloatMillimes: mm(10_000),
  });
  await admin.sessions.open(open);
  const cart = addItem(
    emptyCart,
    { id: WATER, name: 'Eau minérale 50 cl', priceMillimes: mm(850) },
    2,
  );
  const envelope = { sessionId: open.id, createdAt: isoAt(0), terminal, tableId: null };
  const first = await buildSaleRecord({ ...envelope, id: recordId(2), seq: 1 }, cart, {
    method: 'cash',
  });
  await admin.sales.recordSale(first);
  const onTable1 = await admin.orders.addItem(
    await orderRecord(6, { tableId: TABLE_1, productId: WATER, qty: 2, note: '' }),
  );
  const onTable2 = await admin.orders.addItem(
    await orderRecord(7, { tableId: TABLE_2, productId: CREME, qty: 1, note: 'Sans sucre' }),
  );
  await admin.orders.send(await orderRecord(8, { tableId: TABLE_2 }));
  return {
    terminalId: t1.terminalId,
    otherTerminalId: t2.terminalId,
    sessionId: open.id,
    saleId: first.id,
    addOnTable1: await orderRecord(9, {
      tableId: TABLE_1,
      productId: WATER,
      qty: 1,
      note: '',
    }),
    removeOnTable1: await orderRecord(10, {
      itemId: onTable1.itemId,
      reason: 'The guest changed their mind',
    }),
    sendTable1: await orderRecord(11, { tableId: TABLE_1 }),
    prepareOnTable2: await orderRecord(12, { itemId: onTable2.itemId }),
    cancelTable1: await orderRecord(13, { tableId: TABLE_1, reason: 'The guests left' }),
    openOnT2: await buildOpenSessionRecord({
      id: recordId(3),
      terminal: { terminalCode: 'T2', epoch: 0 },
      actorUserId: ADMIN_ID,
      openedAt: isoAt(0),
      openingFloatMillimes: mm(0),
    }),
    closeT1: await buildCloseSessionRecord({
      id: recordId(4),
      sessionId: open.id,
      terminal,
      actorUserId: ADMIN_ID,
      closedAt: isoAt(0),
      closingCountedMillimes: mm(11_700),
      clientZReport: null,
    }),
    nextSale: await buildSaleRecord({ ...envelope, id: recordId(5), seq: 2 }, cart, {
      method: 'card',
    }),
  };
}

/** `setup()` prepared by the admin, then `caller` signed in on the backend's first client. */
async function preparedAs(caller: Caller) {
  const result = setup();
  const prepared = await prepare(result.backend);
  if (caller !== 'signed out') {
    await signInAs(result.backend, caller);
  }
  return { ...result, prepared };
}

/** Everything the members of both shops see through the ports, and the state no port reads. */
async function observable(backend: MemoryBackend, prepared: Prepared) {
  const viewer = await clientAs(backend, CREDENTIALS.admin);
  const other = await clientAs(backend, CREDENTIALS.otherAdmin);
  return {
    products: await viewer.catalog.listProducts(),
    categories: await viewer.catalog.listCategories(),
    settings: await viewer.settings.getSettings(),
    sessionOnT1: await viewer.sessions.current(prepared.terminalId),
    sessionOnT2: await viewer.sessions.current(prepared.otherTerminalId),
    report: await viewer.sessions.zReport(prepared.sessionId),
    sales: await viewer.sales.listSales({}),
    tables: await viewer.orders.listTables(),
    board: await viewer.orders.board(),
    tickets: await viewer.orders.kitchenTickets(),
    otherProducts: await other.catalog.listProducts(),
    otherCategories: await other.catalog.listCategories(),
    otherSettings: await other.settings.getSettings(),
    otherBoard: await other.orders.board(),
    movements: backend.inspect.stockMovements(),
    terminals: backend.inspect.terminals(),
    voids: backend.inspect.receiptVoids(),
    orders: backend.inspect.orders(),
    orderItems: backend.inspect.orderItems(),
    orderRecords: backend.inspect.orderRecords(),
  };
}

/** One valid call per port method. On a backend prepared by `prepare`, as the admin, each succeeds. */
const callFor: Record<
  MemoryOperation,
  (backend: MemoryBackend, prepared: Prepared) => Promise<unknown>
> = {
  'auth.getState': (backend) => backend.auth.getState(),
  'auth.signIn': (backend) => backend.auth.signIn(CREDENTIALS.admin),
  'auth.signOut': (backend) => backend.auth.signOut(),
  'catalog.listProducts': (backend) => backend.catalog.listProducts(),
  'catalog.createProduct': (backend) => backend.catalog.createProduct(makrouds),
  'catalog.updateProduct': (backend) => backend.catalog.updateProduct(CREME, cremeEdit),
  'catalog.deleteProduct': (backend) => backend.catalog.deleteProduct(MAKROUDS),
  'catalog.setAvailability': (backend) => backend.catalog.setAvailability(CREME, false),
  'catalog.adjustStock': async (backend) =>
    backend.catalog.adjustStock(await stockCorrection(WATER, -3)),
  'catalog.listCategories': (backend) => backend.catalog.listCategories(),
  'catalog.createCategory': (backend) =>
    backend.catalog.createCategory({ name: 'Surgelés', color: '#6366f1' }),
  'catalog.deleteCategory': (backend) => backend.catalog.deleteCategory(PATISSERIE),
  'orders.listTables': (backend) => backend.orders.listTables(),
  'orders.createTable': (backend) =>
    backend.orders.createTable({ name: 'Terrasse 9', sortOrder: 9, isActive: true }),
  'orders.updateTable': (backend) =>
    backend.orders.updateTable(TABLE_1, { name: 'Salle 1', sortOrder: 1, isActive: true }),
  'orders.board': (backend) => backend.orders.board(),
  'orders.openOrder': (backend) => backend.orders.openOrder(TABLE_1),
  'orders.kitchenTickets': (backend) => backend.orders.kitchenTickets(),
  'orders.removedAfterSent': (backend) =>
    backend.orders.removedAfterSent({ from: isoAt(0), to: isoAt(60) }),
  'orders.addItem': (backend, prepared) => backend.orders.addItem(prepared.addOnTable1),
  'orders.removeItem': (backend, prepared) => backend.orders.removeItem(prepared.removeOnTable1),
  'orders.send': (backend, prepared) => backend.orders.send(prepared.sendTable1),
  'orders.prepareItem': (backend, prepared) => backend.orders.prepareItem(prepared.prepareOnTable2),
  'orders.cancelOrder': (backend, prepared) => backend.orders.cancelOrder(prepared.cancelTable1),
  'settings.getSettings': (backend) => backend.settings.getSettings(),
  'settings.updateSettings': (backend) =>
    backend.settings.updateSettings({ receiptFooter: 'À bientôt' }),
  'terminals.register': (backend) => backend.terminals.register('T3'),
  'sessions.open': (backend, prepared) => backend.sessions.open(prepared.openOnT2),
  'sessions.close': (backend, prepared) => backend.sessions.close(prepared.closeT1),
  'sessions.current': (backend, prepared) => backend.sessions.current(prepared.terminalId),
  'sessions.zReport': (backend, prepared) => backend.sessions.zReport(prepared.sessionId),
  'sales.recordSale': (backend, prepared) => backend.sales.recordSale(prepared.nextSale),
  'sales.listSales': (backend) => backend.sales.listSales({}),
  'sales.getSale': (backend, prepared) => backend.sales.getSale(prepared.saleId),
  'sales.voidReceipt': (backend, prepared) =>
    backend.sales.voidReceipt({
      record: prepared.nextSale,
      errorCode: 'VALIDATION_ERROR',
      reason: 'Refused while offline',
    }),
};

/**
 * Who a call is open to: anyone, any member of the shop, whoever works the tables (a waiter, the
 * counter, the admin), whoever takes money (the counter and the admin), the kitchen, or the admin.
 */
type Access = 'anyone' | 'member' | 'table' | 'register' | 'kitchen' | 'admin';

/** Who may call each port method: the check made by the database behind it. */
const accessFor: Record<MemoryOperation, Access> = {
  // Signing in, and asking who is signed in: anyone may.
  'auth.getState': 'anyone',
  'auth.signIn': 'anyone',
  'auth.signOut': 'anyone',
  'catalog.listProducts': 'member', // products, row-level security by shop
  'catalog.createProduct': 'admin', // save_product
  'catalog.updateProduct': 'admin', // save_product
  'catalog.deleteProduct': 'admin', // archive_product
  'catalog.setAvailability': 'table', // set_product_availability: the floor takes a dish off the menu
  'catalog.adjustStock': 'admin', // adjust_stock
  'catalog.listCategories': 'member', // categories
  'catalog.createCategory': 'admin', // categories insert policy
  'catalog.deleteCategory': 'admin', // categories delete policy
  'orders.listTables': 'member', // dining_tables
  'orders.createTable': 'admin', // save_dining_table: the room is the admin's
  'orders.updateTable': 'admin', // save_dining_table
  'orders.board': 'member', // dining_tables and open_orders
  'orders.openOrder': 'member', // open_orders and open_order_items
  'orders.kitchenTickets': 'member', // open_order_items
  'orders.removedAfterSent': 'admin', // the report of what was removed after being sent
  'orders.addItem': 'table', // order_item_add
  'orders.removeItem': 'table', // order_item_remove
  'orders.send': 'table', // order_send
  'orders.prepareItem': 'kitchen', // order_item_prepare
  'orders.cancelOrder': 'register', // order_cancel
  'settings.getSettings': 'member', // shop_settings
  'settings.updateSettings': 'admin', // shop_settings update policy
  'terminals.register': 'admin', // register_terminal
  'sessions.open': 'member', // open_session
  'sessions.close': 'member', // close_session
  'sessions.current': 'member', // cash_sessions
  'sessions.zReport': 'member', // z_report
  'sales.recordSale': 'register', // record_sale
  'sales.listSales': 'member', // sales and sale_lines
  'sales.getSale': 'member', // sales and sale_lines
  'sales.voidReceipt': 'admin', // void_receipt
};

const CALLERS: readonly Caller[] = ['signed out', 'cashier', 'waiter', 'kitchen', 'admin'];

const SIGNED_OUT = { 'signed out': 'UNAUTHENTICATED' } as const;

/** How a call settles for each caller under each access rule. */
const outcomeUnder: Record<Access, Record<Caller, 'resolved' | ErrorCode>> = {
  anyone: {
    'signed out': 'resolved',
    cashier: 'resolved',
    waiter: 'resolved',
    kitchen: 'resolved',
    admin: 'resolved',
  },
  member: {
    ...SIGNED_OUT,
    cashier: 'resolved',
    waiter: 'resolved',
    kitchen: 'resolved',
    admin: 'resolved',
  },
  table: {
    ...SIGNED_OUT,
    cashier: 'resolved',
    waiter: 'resolved',
    kitchen: 'FORBIDDEN',
    admin: 'resolved',
  },
  register: {
    ...SIGNED_OUT,
    cashier: 'resolved',
    waiter: 'FORBIDDEN',
    kitchen: 'FORBIDDEN',
    admin: 'resolved',
  },
  kitchen: {
    ...SIGNED_OUT,
    cashier: 'FORBIDDEN',
    waiter: 'FORBIDDEN',
    kitchen: 'resolved',
    admin: 'resolved',
  },
  admin: {
    ...SIGNED_OUT,
    cashier: 'FORBIDDEN',
    waiter: 'FORBIDDEN',
    kitchen: 'FORBIDDEN',
    admin: 'resolved',
  },
};

describe('default seed', () => {
  it('mirrors the demo café the server seeds: two shops with their members, tables, categories and menu, and no terminal', () => {
    const { shops, accounts, profiles, tables, categories, products } = defaultSeed;
    expect(shops.map((shop) => [shop.id, shop.name, shop.settings.receiptFooter])).toEqual([
      [DEMO_SHOP_ID, 'Café des Nattes', 'Merci pour votre visite !'],
      [OTHER_SHOP_ID, 'Other Shop', 'Thank you for your purchase!'],
    ]);
    expect(accounts.map((account) => [account.email, account.demoLabel])).toEqual([
      ['admin@demo.local', 'Owner'],
      ['cashier@demo.local', 'Cashier'],
      ['waiter@demo.local', 'Waiter'],
      ['kitchen@demo.local', 'Kitchen'],
      ['other-admin@demo.local', null],
      ['other-cashier@demo.local', null],
    ]);
    expect(
      profiles.map((profile) => [
        profile.userId,
        profile.shopId,
        profile.roles,
        profile.displayName,
      ]),
    ).toEqual([
      // The owner holds two roles, which is the ordinary case and not an edge one.
      [ADMIN_ID, DEMO_SHOP_ID, ['admin', 'cashier'], 'Demo Owner'],
      ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', DEMO_SHOP_ID, ['cashier'], 'Demo Cashier'],
      ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3', DEMO_SHOP_ID, ['waiter'], 'Demo Waiter'],
      ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4', DEMO_SHOP_ID, ['kitchen'], 'Demo Kitchen'],
      ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', OTHER_SHOP_ID, ['admin'], 'Other Admin'],
      ['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2', OTHER_SHOP_ID, ['cashier'], 'Other Cashier'],
    ]);

    const demoTables = tables.filter((table) => table.shopId === DEMO_SHOP_ID);
    expect(demoTables.map((table) => table.sortOrder)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(demoTables.filter((table) => !table.isActive)).toHaveLength(1);
    expect(tables.filter((table) => table.shopId === OTHER_SHOP_ID)).toHaveLength(1);

    const demoProducts = products.filter((product) => product.shopId === DEMO_SHOP_ID);
    expect(DEMO_CATEGORIES).toHaveLength(4);
    expect(demoProducts).toHaveLength(12);
    expect(OTHER_PRODUCTS).toHaveLength(2);
    expect(demoProducts.some((product) => product.priceMillimes % 1000 !== 0)).toBe(true);
    expect(demoProducts.some((product) => product.stockQty === 0)).toBe(true);
    expect(demoProducts.some((product) => product.stockQty > 0 && product.stockQty <= 10)).toBe(
      true,
    );
    // One item is sold out today, so the menu shows what is_available is for.
    expect(demoProducts.filter((product) => !product.isAvailable)).toHaveLength(1);
    const withBarcode = demoProducts.filter((product) => product.barcode !== '');
    expect(withBarcode.length).toBeGreaterThan(demoProducts.length / 2);
    expect(new Set(withBarcode.map((product) => product.barcode)).size).toBe(withBarcode.length);
    for (const product of products) {
      const shelf = categories.find((category) => category.id === product.categoryId);
      expect(shelf?.shopId, product.name).toBe(product.shopId);
    }
    expect(createMemoryBackend().inspect.terminals()).toEqual([]);
  });

  it('writes seeded stock as opening movements, so stock is the sum of its movements', () => {
    const { backend } = setup();
    const movements = backend.inspect.stockMovements();

    expect(movements).toHaveLength(
      defaultSeed.products.filter((product) => product.stockQty !== 0).length,
    );
    expect(movements[0]).toEqual({
      id: 1,
      shopId: DEMO_SHOP_ID,
      productId: WATER,
      delta: 120,
      reason: 'opening',
      saleId: null,
      note: 'Seed data',
      createdBy: null,
      createdAt: '2026-01-05T08:00:00.000Z',
    });
    for (const product of defaultSeed.products) {
      const sum = movements
        .filter((movement) => movement.productId === product.id)
        .reduce((total, movement) => total + movement.delta, 0);
      expect(sum, product.name).toBe(product.stockQty);
    }
  });

  it('is copied, so backends never share state', async () => {
    const first = createMemoryBackend();
    const second = createMemoryBackend();
    await signInAs(first, 'admin');
    await signInAs(second, 'admin');

    const created = await first.catalog.createProduct(makrouds);

    expect(created.id).toMatch(UUID_V4);
    await expect(second.catalog.listProducts()).resolves.toEqual(DEMO_PRODUCTS);
    expect(defaultSeed.products).toHaveLength(14);
  });

  it('rejects a seed with a repeated id, a broken reference or an id that is not a lowercase UUID', () => {
    const [water, milk] = defaultSeed.products;
    const [admin] = defaultSeed.accounts;
    const invalid: MemorySeed[] = [
      { ...defaultSeed, products: [water, water] },
      { ...defaultSeed, products: [water, { ...milk, barcode: water.barcode }] },
      { ...defaultSeed, products: [{ ...water, categoryId: GENERAL }] },
      {
        ...defaultSeed,
        accounts: defaultSeed.accounts.map((account) => ({
          ...account,
          id: account.id.toUpperCase(),
        })),
        profiles: defaultSeed.profiles.map((profile) => ({
          ...profile,
          userId: profile.userId.toUpperCase(),
        })),
      },
      { ...defaultSeed, accounts: [...defaultSeed.accounts, { ...admin, id: idNo(1) }] },
      {
        ...defaultSeed,
        profiles: [
          ...defaultSeed.profiles,
          { userId: idNo(1), shopId: DEMO_SHOP_ID, roles: ['cashier'], displayName: 'Ghost' },
        ],
      },
    ];
    for (const seed of invalid) {
      expect(() => createMemoryBackend({ seed })).toThrow(
        expect.objectContaining({ code: 'CONFIG_ERROR' }),
      );
    }
  });
});

describe('auth', () => {
  it('starts anonymous and signs a member in with the name, roles and shop of their profile', async () => {
    const { backend } = setup();
    const events: AuthState[] = [];
    backend.auth.onStateChange((state) => {
      events.push(state);
    });
    await expect(backend.auth.getState()).resolves.toEqual({ status: 'anonymous' });

    const user = await backend.auth.signIn({
      email: '  ADMIN@Demo.Local ',
      password: 'demo-admin-2026',
    });

    expect(user).toEqual({
      id: ADMIN_ID,
      email: 'admin@demo.local',
      name: 'Demo Owner',
      roles: ['admin', 'cashier'],
      shopId: DEMO_SHOP_ID,
    });
    await expect(backend.auth.getState()).resolves.toEqual({ status: 'authenticated', user });
    expect(events).toEqual([{ status: 'authenticated', user }]);
    await expect(backend.auth.signIn(CREDENTIALS.otherCashier)).resolves.toEqual({
      id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',
      email: 'other-cashier@demo.local',
      name: 'Other Cashier',
      roles: ['cashier'],
      shopId: OTHER_SHOP_ID,
    });
  });

  it('rejects wrong credentials without changing the state', async () => {
    const { backend } = setup();
    const events: AuthState[] = [];
    backend.auth.onStateChange((state) => {
      events.push(state);
    });

    for (const credentials of [
      { email: 'admin@demo.local', password: 'wrong' },
      { email: 'admin@demo.local', password: 'DEMO-ADMIN-2026' },
      { email: 'admin@demo.local', password: 'demo-cashier-2026' },
      { email: 'nobody@demo.local', password: 'demo-admin-2026' },
    ]) {
      const error = await failure(backend.auth.signIn(credentials), 'UNAUTHENTICATED');
      expect(error.message).toBe('Invalid login credentials');
    }

    await expect(backend.auth.getState()).resolves.toEqual({ status: 'anonymous' });
    expect(events).toEqual([]);
  });

  it('refuses an account without a shop membership with FORBIDDEN, ending the session it replaced', async () => {
    const drifter = {
      id: idNo(900),
      email: 'drifter@demo.local',
      password: 'drifter-2026',
      demoLabel: null,
    };
    const { backend } = setup({ ...defaultSeed, accounts: [...defaultSeed.accounts, drifter] });
    const events: AuthState[] = [];
    backend.auth.onStateChange((state) => {
      events.push(state);
    });
    const credentials = { email: drifter.email, password: drifter.password };

    const error = await failure(backend.auth.signIn(credentials), 'FORBIDDEN');
    expect(error.message).toBe('This account is not a member of any shop.');
    expect(events).toEqual([]);

    const admin = await signInAs(backend, 'admin');
    await failure(backend.auth.signIn(credentials), 'FORBIDDEN');
    await expect(backend.auth.getState()).resolves.toEqual({ status: 'anonymous' });
    expect(events).toEqual([{ status: 'authenticated', user: admin }, { status: 'anonymous' }]);
    expect(backend.demoAccounts.map((account) => account.email)).not.toContain(drifter.email);
  });

  it('signs the cashier in and out, and stops notifying after unsubscribe', async () => {
    const { backend } = setup();
    const events: AuthState[] = [];
    const unsubscribe = backend.auth.onStateChange((state) => {
      events.push(state);
    });

    const cashier = await signInAs(backend, 'cashier');
    expect(cashier).toMatchObject({ roles: ['cashier'], shopId: DEMO_SHOP_ID });
    await backend.auth.signOut();
    await expect(backend.auth.getState()).resolves.toEqual({ status: 'anonymous' });

    unsubscribe();
    await signInAs(backend, 'admin');

    expect(events).toEqual([{ status: 'authenticated', user: cashier }, { status: 'anonymous' }]);
  });

  it('hands out copies of the user and the state, to callers and to each listener', async () => {
    const { backend } = setup();
    backend.auth.onStateChange((state) => {
      if (state.status !== 'anonymous') {
        state.user.roles = ['admin'];
      }
    });
    const seen: AuthState[] = [];
    backend.auth.onStateChange((state) => {
      seen.push(state);
    });

    const user = await signInAs(backend, 'cashier');
    const cashier = structuredClone(user);
    expect(cashier.roles).toEqual(['cashier']);
    user.roles = ['admin'];

    const state = await backend.auth.getState();
    expect(state).toEqual({ status: 'authenticated', user: cashier });
    expect(seen).toEqual([{ status: 'authenticated', user: cashier }]);
    signedInUser(state).roles = ['admin'];

    await expect(backend.auth.getState()).resolves.toEqual({
      status: 'authenticated',
      user: cashier,
    });
    // The roles the ports check are the profile's, not the ones on a cached user.
    await failure(backend.settings.updateSettings({ receiptFooter: 'À bientôt' }), 'FORBIDDEN');
  });

  it('offers one demo account per role of the demo shop', () => {
    const { backend } = setup();
    expect(backend.kind).toBe('memory');
    expect(backend.demoAccounts).toEqual([
      { label: 'Owner', email: 'admin@demo.local', password: 'demo-admin-2026' },
      { label: 'Cashier', email: 'cashier@demo.local', password: 'demo-cashier-2026' },
      { label: 'Waiter', email: 'waiter@demo.local', password: 'demo-waiter-2026' },
      { label: 'Kitchen', email: 'kitchen@demo.local', password: 'demo-kitchen-2026' },
    ]);
  });
});

describe('clients', () => {
  it('connects clients that share the data but not the sign-in or the faults', async () => {
    const { backend, faults } = await setupAs('admin');
    const cashier = backend.connect();
    await expect(cashier.auth.getState()).resolves.toEqual({ status: 'anonymous' });
    await signInAs(cashier, 'cashier');

    const created = await backend.catalog.createCategory({ name: 'Surgelés', color: '#6366f1' });
    await expect(cashier.catalog.listCategories()).resolves.toContainEqual(created);
    await expect(backend.auth.getState()).resolves.toMatchObject({
      user: { roles: ['admin', 'cashier'] },
    });

    faults.failNext('*', new AppError('NETWORK_ERROR', 'Offline'));
    await expect(cashier.catalog.listProducts()).resolves.toHaveLength(12);
    const ownFaults = createFaultInjector();
    const third = backend.connect({ faults: ownFaults });
    ownFaults.failNext('auth.getState', new AppError('SERVER_ERROR', 'Busy'));
    await failure(third.auth.getState(), 'SERVER_ERROR');
    await failure(backend.catalog.listProducts(), 'NETWORK_ERROR');

    await cashier.auth.signOut();
    await expect(backend.catalog.listCategories()).resolves.toContainEqual(created);
  });
});

describe('catalog', () => {
  it("lists the products and categories of the caller's shop, in insertion order, as copies", async () => {
    const { backend } = await setupAs('cashier');
    const products = await backend.catalog.listProducts();
    expect(products).toEqual(DEMO_PRODUCTS);

    products[0].name = 'Changed';
    products[0].stockQty = 999;

    await expect(backend.catalog.listProducts()).resolves.toEqual(DEMO_PRODUCTS);
    await expect(backend.catalog.listCategories()).resolves.toEqual(DEMO_CATEGORIES);
    await backend.auth.signIn(CREDENTIALS.otherCashier);
    await expect(backend.catalog.listProducts()).resolves.toEqual(OTHER_PRODUCTS);
    await expect(backend.catalog.listCategories()).resolves.toEqual(OTHER_CATEGORIES);
  });

  it('creates a product with an id, timestamps, availability, the category name and an opening movement', async () => {
    const { backend } = await setupAs('admin');
    const created = await backend.catalog.createProduct(makrouds);

    expect(created).toEqual({
      id: idNo(1),
      name: makrouds.name,
      priceMillimes: makrouds.priceMillimes,
      categoryId: SNACKS,
      categoryName: 'Snacks',
      barcode: makrouds.barcode,
      description: 'Kairouan',
      imageUrl: '',
      isAvailable: true,
      trackStock: true,
      stockQty: 30,
      createdAt: isoAt(1),
      updatedAt: isoAt(1),
    });
    const products = await backend.catalog.listProducts();
    expect(products.at(-1)).toEqual(created);
    expect(products).toHaveLength(DEMO_PRODUCTS.length + 1);
    expect(backend.inspect.stockMovements().at(-1)).toEqual({
      id: 14,
      shopId: DEMO_SHOP_ID,
      productId: idNo(1),
      delta: 30,
      reason: 'opening',
      saleId: null,
      note: '',
      createdBy: ADMIN_ID,
      createdAt: isoAt(1),
    });

    const loose = await backend.catalog.createProduct({
      ...makrouds,
      categoryId: null,
      barcode: '',
      openingStock: 0,
    });
    expect(loose).toMatchObject({
      categoryId: null,
      categoryName: null,
      stockQty: 0,
      isAvailable: true,
    });
    expect(backend.inspect.stockMovements()).toHaveLength(14);
  });

  it('updates the fields and moves stock by the delta only, keeping availability, createdAt and position', async () => {
    const { backend } = await setupAs('admin');
    const before = await backend.catalog.listProducts();
    const index = before.findIndex((product) => product.id === MAKROUDS);
    // Sold out in the seed, and an edit of its other fields leaves it sold out.
    expect(before[index]).toMatchObject({ stockQty: 0, isAvailable: false });

    const input: ProductUpdateInput = {
      name: 'Makrouds maison',
      priceMillimes: mm(14_500),
      categoryId: CHAUDES,
      barcode: '',
      description: 'Grand format',
      imageUrl: 'https://example.com/makrouds.jpg',
      // The edit leaves it sold out: the menu toggle is its own write, not part of the form.
      isAvailable: false,
      trackStock: true,
      stockDelta: -2,
    };
    const updated = await backend.catalog.updateProduct(MAKROUDS, input);

    expect(updated).toEqual({
      id: MAKROUDS,
      name: input.name,
      priceMillimes: input.priceMillimes,
      categoryId: CHAUDES,
      categoryName: 'Boissons chaudes',
      barcode: '',
      description: 'Grand format',
      imageUrl: input.imageUrl,
      isAvailable: false,
      trackStock: true,
      stockQty: -2,
      createdAt: before[index].createdAt,
      updatedAt: isoAt(1),
    });
    const after = await backend.catalog.listProducts();
    expect(after[index]).toEqual(updated);
    expect(after).toHaveLength(before.length);
    expect(backend.inspect.stockMovements().at(-1)).toMatchObject({
      productId: MAKROUDS,
      delta: -2,
      reason: 'adjustment',
      createdBy: ADMIN_ID,
    });

    const unchanged = await backend.catalog.updateProduct(MAKROUDS, { ...input, stockDelta: 0 });
    expect(unchanged).toEqual({ ...updated, updatedAt: isoAt(2) });
    expect(backend.inspect.stockMovements()).toHaveLength(14);
  });

  it('rejects invalid input with the Zod issues and stores nothing', async () => {
    const { backend } = await setupAs('admin');
    const error = await failure(
      backend.catalog.createProduct({
        ...makrouds,
        name: '   ',
        priceMillimes: mm(-1),
        openingStock: -1,
      }),
      'VALIDATION_ERROR',
    );
    expect(error.details?.issues).toHaveLength(3);
    expect(error.message).toBe('Product name is required');

    await failure(
      backend.catalog.updateProduct(CREME, { ...cremeEdit, imageUrl: 'not a url' }),
      'VALIDATION_ERROR',
    );
    await expect(backend.catalog.listProducts()).resolves.toEqual(DEMO_PRODUCTS);
  });

  it("checks ids, categories and products against the caller's shop", async () => {
    const { backend } = await setupAs('admin');

    const badId = await failure(
      backend.catalog.updateProduct('prod-harissa', cremeEdit),
      'VALIDATION_ERROR',
    );
    expect(badId.details).toEqual({ field: 'id' });
    const badProductId = await failure(
      backend.catalog.deleteProduct('prod-harissa'),
      'VALIDATION_ERROR',
    );
    expect(badProductId.details).toEqual({ field: 'product_id' });
    const badCategoryId = await failure(
      backend.catalog.deleteCategory('cat-epicerie'),
      'VALIDATION_ERROR',
    );
    expect(badCategoryId.details).toEqual({ field: 'id' });

    for (const categoryId of [idNo(99), GENERAL, 'cat-epicerie']) {
      const error = await failure(
        backend.catalog.createProduct({ ...makrouds, categoryId }),
        'VALIDATION_ERROR',
      );
      expect(error.details, categoryId).toEqual({ field: 'category_id' });
    }
    // The category is checked before the product.
    await failure(
      backend.catalog.updateProduct(idNo(99), { ...cremeEdit, categoryId: GENERAL }),
      'VALIDATION_ERROR',
    );
    for (const id of [idNo(99), OTHER_PRODUCT]) {
      const edit = await failure(backend.catalog.updateProduct(id, cremeEdit), 'NOT_FOUND');
      expect(edit.details).toEqual({ productId: id });
      const removal = await failure(backend.catalog.deleteProduct(id), 'NOT_FOUND');
      expect(removal.details).toEqual({ productId: id });
    }
    const category = await failure(backend.catalog.deleteCategory(GENERAL), 'NOT_FOUND');
    expect(category.details).toEqual({ categoryId: GENERAL });

    await expect(backend.catalog.listProducts()).resolves.toEqual(DEMO_PRODUCTS);
    const other = await clientAs(backend, CREDENTIALS.otherAdmin);
    await expect(other.catalog.listProducts()).resolves.toEqual(OTHER_PRODUCTS);
    await expect(other.catalog.listCategories()).resolves.toEqual(OTHER_CATEGORIES);
  });

  it("refuses a barcode another live product of the shop uses, but not an archived product's or another shop's", async () => {
    const { backend } = await setupAs('admin');
    const waterBarcode = '6194000100015';

    const created = await failure(
      backend.catalog.createProduct({ ...makrouds, barcode: waterBarcode }),
      'VALIDATION_ERROR',
    );
    expect(created.details).toEqual({ field: 'barcode' });
    const updated = await failure(
      backend.catalog.updateProduct(CREME, { ...cremeEdit, barcode: waterBarcode }),
      'VALIDATION_ERROR',
    );
    expect(updated.details).toEqual({ field: 'barcode' });

    await expect(backend.catalog.updateProduct(CREME, cremeEdit)).resolves.toMatchObject({
      barcode: cremeEdit.barcode,
    });
    await expect(
      backend.catalog.createProduct({ ...makrouds, barcode: '9990000000011' }),
    ).resolves.toMatchObject({ barcode: '9990000000011' });
    await backend.catalog.deleteProduct(WATER);
    await expect(
      backend.catalog.createProduct({ ...makrouds, barcode: waterBarcode }),
    ).resolves.toMatchObject({ barcode: waterBarcode });
  });

  it('archives a deleted product: it leaves the list, its movements stay, and it is not archived twice', async () => {
    const { backend } = await setupAs('admin');
    await backend.catalog.deleteProduct(CREME);

    const products = await backend.catalog.listProducts();
    expect(products.map((product) => product.id)).not.toContain(CREME);
    expect(products).toHaveLength(DEMO_PRODUCTS.length - 1);
    expect(
      backend.inspect.stockMovements().filter((movement) => movement.productId === CREME),
    ).toHaveLength(1);
    const again = await failure(backend.catalog.deleteProduct(CREME), 'NOT_FOUND');
    expect(again.details).toEqual({ productId: CREME });
    await failure(backend.catalog.updateProduct(CREME, cremeEdit), 'NOT_FOUND');
  });

  it("creates categories in the caller's shop with a trimmed name and allows duplicate names", async () => {
    const { backend } = await setupAs('admin');
    const first = await backend.catalog.createCategory({ name: '  Surgelés ', color: '#6366f1' });
    const second = await backend.catalog.createCategory({ name: 'Surgelés', color: '#8b5cf6' });

    expect(first).toEqual({ id: idNo(1), name: 'Surgelés', color: '#6366f1', createdAt: isoAt(1) });
    expect(second).toMatchObject({ id: idNo(2), name: 'Surgelés' });
    const categories = await backend.catalog.listCategories();
    expect(categories.map((category) => category.id)).toEqual([
      FRAICHES,
      CHAUDES,
      SNACKS,
      PATISSERIE,
      idNo(1),
      idNo(2),
    ]);

    await failure(
      backend.catalog.createCategory({ name: ' ', color: '#6366f1' }),
      'VALIDATION_ERROR',
    );
    await failure(
      backend.catalog.createCategory({ name: 'Épices', color: 'blue' }),
      'VALIDATION_ERROR',
    );
    const other = await clientAs(backend, CREDENTIALS.otherAdmin);
    await expect(other.catalog.listCategories()).resolves.toEqual(OTHER_CATEGORIES);
  });

  it('hands out copies of the categories it lists and creates', async () => {
    const { backend } = await setupAs('admin');
    const created = await backend.catalog.createCategory({ name: 'Surgelés', color: '#6366f1' });
    const categories = await backend.catalog.listCategories();
    const expected = structuredClone(categories);
    expect(expected.at(-1)).toEqual(created);

    created.name = 'Changed';
    categories[0].name = 'x';
    categories[0].color = '#000000';

    await expect(backend.catalog.listCategories()).resolves.toEqual(expected);
  });

  it('deletes a category and clears it on its products only', async () => {
    const { backend } = await setupAs('admin');
    await backend.catalog.deleteCategory(FRAICHES);

    const categories = await backend.catalog.listCategories();
    expect(categories.map((category) => category.id)).not.toContain(FRAICHES);
    const products = await backend.catalog.listProducts();
    expect(DEMO_PRODUCTS.filter((product) => product.categoryId === FRAICHES)).toHaveLength(3);
    for (const seeded of DEMO_PRODUCTS) {
      const product = products.find((candidate) => candidate.id === seeded.id);
      if (seeded.categoryId === FRAICHES) {
        expect(product).toEqual({ ...seeded, categoryId: null, categoryName: null });
      } else {
        expect(product).toEqual(seeded);
      }
    }

    const again = await failure(backend.catalog.deleteCategory(FRAICHES), 'NOT_FOUND');
    expect(again.details).toEqual({ categoryId: FRAICHES });
  });
});

describe('settings', () => {
  it("reads and updates the receipt footer of the caller's shop only, handing out copies", async () => {
    const { backend } = await setupAs('admin');
    await expect(backend.settings.getSettings()).resolves.toEqual({
      receiptFooter: 'Merci pour votre visite !',
    });

    const saved = await backend.settings.updateSettings({ receiptFooter: 'À bientôt' });
    expect(saved).toEqual({ receiptFooter: 'À bientôt' });
    saved.receiptFooter = 'Changed';
    const read = await backend.settings.getSettings();
    expect(read).toEqual({ receiptFooter: 'À bientôt' });
    read.receiptFooter = 'Changed again';
    await expect(backend.settings.getSettings()).resolves.toEqual({ receiptFooter: 'À bientôt' });

    const other = await clientAs(backend, CREDENTIALS.otherCashier);
    await expect(other.settings.getSettings()).resolves.toEqual({
      receiptFooter: 'Thank you for your purchase!',
    });
  });

  it('rejects a footer that is too long', async () => {
    const { backend } = await setupAs('admin');
    await failure(
      backend.settings.updateSettings({ receiptFooter: 'x'.repeat(501) }),
      'VALIDATION_ERROR',
    );
    await expect(backend.settings.getSettings()).resolves.toEqual({
      receiptFooter: 'Merci pour votre visite !',
    });
  });
});

describe('access', () => {
  it.each(MEMORY_OPERATIONS)(
    '%s lets in the callers the database lets in, and a refusal changes nothing',
    async (operation) => {
      for (const caller of CALLERS) {
        const { backend, prepared } = await preparedAs(caller);
        const outcome = await outcomeOf(callFor[operation](backend, prepared));
        expect(outcome, `${operation} as ${caller}`).toBe(
          outcomeUnder[accessFor[operation]][caller],
        );
        if (outcome !== 'resolved') {
          const control = await preparedAs(caller);
          expect(await observable(backend, prepared)).toEqual(
            await observable(control.backend, control.prepared),
          );
        }
      }
    },
  );

  it('refuses calls again once the user has signed out', async () => {
    const { backend } = await setupAs('admin');
    await backend.catalog.createCategory({ name: 'Surgelés', color: '#6366f1' });

    await backend.auth.signOut();

    await failure(
      backend.catalog.createCategory({ name: 'Épices', color: '#8b5cf6' }),
      'UNAUTHENTICATED',
    );
    await failure(backend.catalog.listCategories(), 'UNAUTHENTICATED');
    await signInAs(backend, 'cashier');
    const categories = await backend.catalog.listCategories();
    expect(categories.map((category) => category.name)).toEqual([
      ...DEMO_CATEGORIES.map((category) => category.name),
      'Surgelés',
    ]);
  });

  it('checks the caller first, then the id, then the input, then the rows', async () => {
    const nameless: ProductUpdateInput = { ...cremeEdit, name: '' };
    const { backend } = setup();
    await failure(backend.catalog.updateProduct('missing', nameless), 'UNAUTHENTICATED');

    await signInAs(backend, 'cashier');
    await failure(backend.catalog.updateProduct('missing', nameless), 'FORBIDDEN');

    await signInAs(backend, 'admin');
    const id = await failure(
      backend.catalog.updateProduct('missing', nameless),
      'VALIDATION_ERROR',
    );
    expect(id.details).toEqual({ field: 'id' });
    const input = await failure(
      backend.catalog.updateProduct(idNo(99), nameless),
      'VALIDATION_ERROR',
    );
    expect(input.details).toHaveProperty('issues');
    await failure(backend.catalog.updateProduct(idNo(99), cremeEdit), 'NOT_FOUND');
  });

  it('fails with a pending fault before it checks the caller', async () => {
    const { backend, faults } = setup();
    const offline = new AppError('NETWORK_ERROR', 'Offline');
    faults.failNext('catalog.createProduct', offline);

    await expect(backend.catalog.createProduct(makrouds)).rejects.toBe(offline);
    await failure(backend.catalog.createProduct(makrouds), 'UNAUTHENTICATED');
  });
});

describe('connectivity', () => {
  it('reads navigator.onLine in a browser and stays online where there is none', async () => {
    expect(defaultConnectivity({ onLine: true })).toBe(true);
    expect(defaultConnectivity({ onLine: false })).toBe(false);
    // Node, and any runtime whose navigator has no onLine: there is no network to lose.
    expect(defaultConnectivity({})).toBe(true);
    expect(defaultConnectivity(undefined)).toBe(true);

    vi.stubGlobal('navigator', { onLine: false });
    try {
      expect(defaultConnectivity()).toBe(false);
      // A backend built without the option follows the browser, which is what the demo runs on.
      await failure(createMemoryBackend().auth.getState(), 'NETWORK_ERROR');
    } finally {
      vi.unstubAllGlobals();
    }
    await expect(createMemoryBackend().auth.getState()).resolves.toEqual({ status: 'anonymous' });
  });

  it.each(MEMORY_OPERATIONS)(
    '%s throws NETWORK_ERROR while the device is offline, changing nothing',
    async (operation) => {
      const { backend, network, prepared } = await preparedAs('admin');
      // The same backend where the call was never made: a request that never leaves changes nothing.
      const control = await preparedAs('admin');

      network.online = false;
      const error = await failure(callFor[operation](backend, prepared), 'NETWORK_ERROR');
      expect(error.message).toBe('Could not reach the server. Check the connection and try again.');
      network.online = true;

      expect(await observable(backend, prepared)).toEqual(
        await observable(control.backend, control.prepared),
      );
      await expect(backend.auth.getState()).resolves.toEqual(await control.backend.auth.getState());
    },
  );

  it('answers offline before the faults and before the caller check, spending neither', async () => {
    const { backend, faults, network } = setup();
    const busy = new AppError('SERVER_ERROR', 'Busy');
    faults.failNext('catalog.listProducts', busy);
    network.online = false;

    // Nobody is signed in and a fault is queued: being offline comes before both.
    await failure(backend.catalog.listProducts(), 'NETWORK_ERROR');
    await failure(backend.auth.signIn(CREDENTIALS.admin), 'NETWORK_ERROR');

    network.online = true;
    // The queued fault was never spent, and the caller is checked only once a request arrives.
    await expect(backend.catalog.listProducts()).rejects.toBe(busy);
    await failure(backend.catalog.listProducts(), 'UNAUTHENTICATED');
    await signInAs(backend, 'admin');
    await expect(backend.catalog.listProducts()).resolves.toHaveLength(12);
  });
});

describe('fault injection', () => {
  it('makes the next calls throw the given AppError exactly `times` times', async () => {
    const { backend, faults } = await setupAs('cashier');
    const offline = new AppError('NETWORK_ERROR', 'Offline');
    faults.failNext('catalog.listProducts', offline, 2);

    await expect(backend.catalog.listProducts()).rejects.toBe(offline);
    await expect(backend.catalog.listCategories()).resolves.toHaveLength(4);
    await expect(backend.catalog.listProducts()).rejects.toBe(offline);
    await expect(backend.catalog.listProducts()).resolves.toHaveLength(12);
  });

  it.each(MEMORY_OPERATIONS)(
    '%s checks faults under its own name before it touches the store',
    async (operation) => {
      const { backend, faults, prepared } = await preparedAs('admin');
      // The same backend without the faulted call, to show that it changed nothing.
      const control = await preparedAs('admin');
      const fault = new AppError('SERVER_ERROR', `Fault for ${operation}`);
      faults.failNext(operation, fault);

      await expect(callFor[operation](backend, prepared)).rejects.toBe(fault);
      expect(await observable(backend, prepared)).toEqual(
        await observable(control.backend, control.prepared),
      );
      await expect(backend.auth.getState()).resolves.toEqual(await control.backend.auth.getState());

      expect(await settle(callFor[operation](backend, prepared))).toBe('resolved');
      await callFor[operation](control.backend, control.prepared);
      expect(await observable(backend, prepared)).toEqual(
        await observable(control.backend, control.prepared),
      );
    },
  );

  it.each(MEMORY_OPERATIONS)(
    '%s commits under a dropped response and then throws NETWORK_ERROR',
    async (operation) => {
      const { backend, faults, prepared } = await preparedAs('admin');
      // The same backend where the call answered: the write lands either way.
      const control = await preparedAs('admin');
      faults.dropNext(operation);

      await failure(callFor[operation](backend, prepared), 'NETWORK_ERROR');
      await callFor[operation](control.backend, control.prepared);

      expect(await observable(backend, prepared)).toEqual(
        await observable(control.backend, control.prepared),
      );
      await expect(backend.auth.getState()).resolves.toEqual(await control.backend.auth.getState());
    },
  );

  it('queues dropped responses and failures together, in the order they were added', async () => {
    const { backend, faults } = await setupAs('admin');
    const busy = new AppError('SERVER_ERROR', 'Busy');
    faults.dropNext('catalog.createCategory');
    faults.failNext('catalog.createCategory', busy);

    const dropped = await failure(
      backend.catalog.createCategory({ name: 'Surgelés', color: '#6366f1' }),
      'NETWORK_ERROR',
    );
    expect(dropped.message).toBe(
      'The request was sent but no answer arrived. It may already be recorded.',
    );
    const epices = { name: 'Épices', color: '#8b5cf6' };
    await expect(backend.catalog.createCategory(epices)).rejects.toBe(busy);
    await backend.catalog.createCategory(epices);

    // The dropped call kept the category it wrote; the failed one wrote nothing.
    const categories = await backend.catalog.listCategories();
    expect(categories.map((category) => category.name)).toEqual([
      ...DEMO_CATEGORIES.map((category) => category.name),
      'Surgelés',
      'Épices',
    ]);
  });

  it('matches any operation with * and applies faults in the order they were added', async () => {
    const { backend, faults } = setup();
    const specific = new AppError('FORBIDDEN', 'No');
    const any = new AppError('RATE_LIMITED', 'Slow down');
    faults.failNext('catalog.listProducts', specific);
    faults.failNext('*', any);

    const events: AuthState[] = [];
    backend.auth.onStateChange((state) => {
      events.push(state);
    });
    await expect(backend.auth.signIn(CREDENTIALS.admin)).rejects.toBe(any);
    expect(events).toEqual([]);
    await expect(backend.catalog.listProducts()).rejects.toBe(specific);
    await signInAs(backend, 'admin');
    await expect(backend.catalog.listProducts()).resolves.toHaveLength(12);
  });

  it('clear drops pending faults', async () => {
    const { backend, faults } = setup();
    faults.failNext('*', new AppError('NETWORK_ERROR', 'Offline'), 5);
    faults.clear();
    await expect(backend.auth.getState()).resolves.toEqual({ status: 'anonymous' });
  });

  it('refuses a times value below one or fractional', () => {
    const faults = createFaultInjector();
    const error = new AppError('NETWORK_ERROR', 'Offline');
    expect(() => faults.failNext('*', error, 0)).toThrow(AppError);
    expect(() => faults.failNext('*', error, 1.5)).toThrow(AppError);
    expect(() => faults.dropNext('*', 0)).toThrow(AppError);
    expect(() => faults.dropNext('*', 1.5)).toThrow(AppError);
    expect(faults.check('auth.getState')).toBe('run');
  });
});

describe('ids and unexpected failures', () => {
  it('uses crypto.randomUUID for ids where it exists', () => {
    expect(
      randomId({ randomUUID: () => 'from-random-uuid', getRandomValues: (bytes) => bytes }),
    ).toBe('from-random-uuid');
    expect(randomId()).toMatch(UUID_V4);
  });

  it('builds a v4 UUID from getRandomValues where randomUUID is missing', () => {
    expect(randomId({ getRandomValues: (bytes) => bytes.fill(0x00) })).toBe(
      '00000000-0000-4000-8000-000000000000',
    );
    expect(randomId({ getRandomValues: (bytes) => bytes.fill(0xff) })).toBe(
      'ffffffff-ffff-4fff-bfff-ffffffffffff',
    );
    expect(randomId({ getRandomValues: (bytes) => bytes.map((_, index) => index) })).toBe(
      '00010203-0405-4607-8809-0a0b0c0d0e0f',
    );
    expect(randomId({ getRandomValues: (bytes) => crypto.getRandomValues(bytes) })).toMatch(
      UUID_V4,
    );
  });

  it('creates rows with the default ids on a page that is not a secure context', async () => {
    const secure = crypto;
    // What http://192.168.x.x offers: getRandomValues but no randomUUID.
    vi.stubGlobal('crypto', {
      getRandomValues: (bytes: Uint8Array<ArrayBuffer>) => secure.getRandomValues(bytes),
    });
    try {
      const backend = createMemoryBackend();
      await signInAs(backend, 'admin');
      const category = await backend.catalog.createCategory({ name: 'Surgelés', color: '#6366f1' });
      expect(category.id).toMatch(UUID_V4);
      const { terminalId } = await backend.terminals.register('T1');
      expect(terminalId).toMatch(UUID_V4);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it('refuses an id source that returns anything but an unused lowercase UUID', async () => {
    for (const id of ['id-1', idNo(1).replace('0', 'A').toUpperCase(), FRAICHES]) {
      const backend = createMemoryBackend({ newId: () => id });
      await signInAs(backend, 'admin');
      await failure(
        backend.catalog.createCategory({ name: 'Surgelés', color: '#6366f1' }),
        'CONFIG_ERROR',
      );
      await expect(backend.catalog.listCategories()).resolves.toEqual(DEMO_CATEGORIES);
    }
  });

  it('turns any other failure into an UNKNOWN AppError that keeps the original as its cause', async () => {
    const broken = new TypeError('crypto.randomUUID is not a function');
    const backend = createMemoryBackend({
      newId: () => {
        throw broken;
      },
    });
    await signInAs(backend, 'admin');

    const error = await failure(
      backend.catalog.createCategory({ name: 'Surgelés', color: '#6366f1' }),
      'UNKNOWN',
    );
    expect(error.message).toBe('crypto.randomUUID is not a function');
    expect(error.cause).toBe(broken);
    await expect(backend.catalog.listCategories()).resolves.toEqual(DEMO_CATEGORIES);
  });
});

describe('orders and realtime', () => {
  it('tells the shop which topic a write changed, until the listener unsubscribes', async () => {
    const { backend } = await setupAs('waiter');
    const caisse = await clientAs(backend, CREDENTIALS.cashier);
    const heard: RealtimeTopic[] = [];
    const stop = caisse.realtime.subscribe(DEMO_SHOP_ID, (topic) => {
      heard.push(topic);
    });

    // The first item on a free table opens its order, so both topics change.
    const added = await backend.orders.addItem(
      await orderRecord(1, { tableId: TABLE_1, productId: WATER, qty: 1, note: '' }),
    );
    expect(heard).toEqual(['open_orders', 'open_order_items']);

    heard.length = 0;
    await backend.orders.send(await orderRecord(2, { tableId: TABLE_1 }));
    await backend.orders.removeItem(
      await orderRecord(3, { itemId: added.itemId, reason: 'The guest sent it back' }),
    );
    expect(heard).toEqual(['open_order_items', 'open_order_items']);

    heard.length = 0;
    // A send that stamps nothing changes nothing, so it says nothing.
    await backend.orders.send(await orderRecord(4, { tableId: TABLE_1 }));
    await backend.orders.addItem(
      await orderRecord(5, { tableId: TABLE_1, productId: WATER, qty: 1, note: '' }),
    );
    expect(heard).toEqual(['open_order_items']);

    heard.length = 0;
    await caisse.orders.cancelOrder(
      await orderRecord(6, { tableId: TABLE_1, reason: 'The guests left' }),
    );
    expect(heard).toEqual(['open_orders', 'open_order_items']);

    heard.length = 0;
    const admin = await clientAs(backend, CREDENTIALS.admin);
    await admin.catalog.createCategory({ name: 'Chicha', color: '#6366f1' });
    expect(heard).toEqual(['products']);

    stop();
    await backend.orders.addItem(
      await orderRecord(7, { tableId: TABLE_1, productId: WATER, qty: 1, note: '' }),
    );
    expect(heard).toEqual(['products']);
  });

  it('keeps a listener of another shop, and one that throws, out of the way of the write', async () => {
    const { backend } = await setupAs('waiter');
    const elsewhere: RealtimeTopic[] = [];
    backend.realtime.subscribe(OTHER_SHOP_ID, (topic) => {
      elsewhere.push(topic);
    });
    const broken = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    backend.realtime.subscribe(DEMO_SHOP_ID, () => {
      throw new TypeError('This screen is broken');
    });
    const heard: RealtimeTopic[] = [];
    backend.realtime.subscribe(DEMO_SHOP_ID, (topic) => {
      heard.push(topic);
    });

    const added = await backend.orders.addItem(
      await orderRecord(1, { tableId: TABLE_1, productId: WATER, qty: 2, note: '' }),
    );

    expect(added.status).toBe('created');
    expect(elsewhere).toEqual([]);
    expect(heard).toEqual(['open_orders', 'open_order_items']);
    expect(broken).toHaveBeenCalled();
    broken.mockRestore();
    await expect(backend.orders.openOrder(TABLE_1)).resolves.toMatchObject({
      items: [{ id: added.itemId, qty: 2 }],
    });
  });

  it('takes nothing on a retired table and leaves it off the board, but still lists it', async () => {
    const { backend } = await setupAs('waiter');

    const refused = await failure(
      backend.orders.addItem(
        await orderRecord(1, { tableId: RETIRED_TABLE, productId: WATER, qty: 1, note: '' }),
      ),
      'TABLE_INACTIVE',
    );

    expect(refused.details).toEqual({ tableId: RETIRED_TABLE });
    const tables = await backend.orders.listTables();
    expect(tables.map((table) => table.id)).toContain(RETIRED_TABLE);
    const board = await backend.orders.board();
    expect(board.map((entry) => entry.table.id)).not.toContain(RETIRED_TABLE);
    expect(board).toHaveLength(tables.filter((table) => table.isActive).length);
    expect(backend.inspect.orders()).toEqual([]);
    expect(backend.inspect.orderRecords()).toEqual([]);
  });
});
