import { mm, type Millimes } from '@/lib/money';
import type { Category, Role, ShopSettings } from '@/ports';

/** A sign-in the memory backend accepts, as a row of auth.users. */
export interface MemoryAccount {
  readonly id: string;
  readonly email: string;
  readonly password: string;
  /** Offered on the login page as "Continue as <label>"; accounts without one are not offered. */
  readonly demoLabel: string | null;
}

/**
 * Shop membership and roles, as public.profiles. An account without one cannot sign in. One person
 * often holds several roles: the owner works the counter as well as the back office.
 */
export interface MemoryProfile {
  readonly userId: string;
  readonly shopId: string;
  readonly roles: readonly Role[];
  readonly displayName: string;
}

/** A table of the room, as public.dining_tables. Only an admin adds or retires one. */
export interface MemorySeedTable {
  readonly id: string;
  readonly shopId: string;
  readonly name: string;
  readonly sortOrder: number;
  /** A retired table stays for its history, but nothing may be added to it (TABLE_INACTIVE). */
  readonly isActive: boolean;
}

export interface MemoryShop {
  readonly id: string;
  readonly name: string;
  readonly settings: ShopSettings;
}

export interface MemorySeedCategory extends Category {
  readonly shopId: string;
}

/**
 * A menu item as seeded. `stockQty` is written as its opening stock movement and means something
 * only where `trackStock` is on — most café items are made to order and are not counted;
 * `isAvailable` is the daily on-the-menu / sold-out toggle, which hides nothing already ordered.
 */
export interface MemorySeedProduct {
  readonly id: string;
  readonly shopId: string;
  readonly categoryId: string | null;
  readonly name: string;
  readonly priceMillimes: Millimes;
  readonly barcode: string;
  readonly description: string;
  readonly imageUrl: string;
  readonly isAvailable: boolean;
  readonly trackStock: boolean;
  readonly stockQty: number;
  readonly createdAt: string;
}

/**
 * The whole starting state of a memory backend. Every id is a UUID, as in the database. There are
 * no terminals, sessions, sales or open orders: an admin registers a terminal first, and a table
 * opens its order when the first item lands on it.
 */
export interface MemorySeed {
  readonly shops: readonly MemoryShop[];
  readonly accounts: readonly MemoryAccount[];
  readonly profiles: readonly MemoryProfile[];
  /** In the admin's order. */
  readonly tables: readonly MemorySeedTable[];
  readonly categories: readonly MemorySeedCategory[];
  /** In list order. */
  readonly products: readonly MemorySeedProduct[];
}

const SEEDED_AT = '2026-01-05T08:00:00.000Z';

export const DEMO_SHOP_ID = '11111111-1111-4111-8111-111111111111';
/** A second shop, so tests can show that one shop never sees or changes another's data. */
export const OTHER_SHOP_ID = '22222222-2222-4222-8222-222222222222';

function category(id: string, shopId: string, name: string, color: string): MemorySeedCategory {
  return { id, shopId, name, color, createdAt: SEEDED_AT };
}

const fraiches = category(
  '44444444-4444-4444-8444-444444444401',
  DEMO_SHOP_ID,
  'Boissons fraîches',
  '#3b82f6',
);
const chaudes = category(
  '44444444-4444-4444-8444-444444444402',
  DEMO_SHOP_ID,
  'Boissons chaudes',
  '#10b981',
);
const snacks = category('44444444-4444-4444-8444-444444444403', DEMO_SHOP_ID, 'Snacks', '#f59e0b');
const patisserie = category(
  '44444444-4444-4444-8444-444444444404',
  DEMO_SHOP_ID,
  'Pâtisserie',
  '#ef4444',
);
const general = category(
  '44444444-4444-4444-8444-444444444411',
  OTHER_SHOP_ID,
  'General',
  '#6366f1',
);

function product(
  id: string,
  shelf: MemorySeedCategory,
  name: string,
  price: Millimes,
  barcode: string,
  stockQty: number,
  isAvailable = true,
): MemorySeedProduct {
  return {
    id,
    shopId: shelf.shopId,
    categoryId: shelf.id,
    name,
    priceMillimes: price,
    barcode,
    description: '',
    imageUrl: '',
    isAvailable,
    // A seeded item is counted when it was given an opening stock: bottles are, coffee is not.
    trackStock: stockQty !== 0,
    stockQty,
    createdAt: SEEDED_AT,
  };
}

function diningTable(
  id: string,
  shopId: string,
  name: string,
  sortOrder: number,
  isActive = true,
): MemorySeedTable {
  return { id, shopId, name, sortOrder, isActive };
}

/**
 * The same shops, members, tables, categories and menu as the server's demo café
 * (api/src/Demo/DemoSeeder.php), so the credential-free demo and the real one show one café. Unlike
 * the server's it registers no terminal: an admin
 * registers this device in Settings before a cashier opens a session, and no table has an open
 * order until somebody adds the first item to it.
 */
export const defaultSeed: MemorySeed = {
  shops: [
    {
      id: DEMO_SHOP_ID,
      name: 'Café des Nattes',
      settings: { receiptFooter: 'Merci pour votre visite !' },
    },
    {
      id: OTHER_SHOP_ID,
      name: 'Other Shop',
      settings: { receiptFooter: 'Thank you for your purchase!' },
    },
  ],
  accounts: [
    {
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
      email: 'admin@demo.local',
      password: 'demo-admin-2026',
      demoLabel: 'Owner',
    },
    {
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
      email: 'cashier@demo.local',
      password: 'demo-cashier-2026',
      demoLabel: 'Cashier',
    },
    {
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
      email: 'waiter@demo.local',
      password: 'demo-waiter-2026',
      demoLabel: 'Waiter',
    },
    {
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4',
      email: 'kitchen@demo.local',
      password: 'demo-kitchen-2026',
      demoLabel: 'Kitchen',
    },
    {
      id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
      email: 'other-admin@demo.local',
      password: 'other-admin-2026',
      demoLabel: null,
    },
    {
      id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',
      email: 'other-cashier@demo.local',
      password: 'other-cashier-2026',
      demoLabel: null,
    },
  ],
  profiles: [
    {
      userId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
      shopId: DEMO_SHOP_ID,
      // The owner runs the back office and works the counter, so the demo has both in one login.
      roles: ['admin', 'cashier'],
      displayName: 'Demo Owner',
    },
    {
      userId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
      shopId: DEMO_SHOP_ID,
      roles: ['cashier'],
      displayName: 'Demo Cashier',
    },
    {
      userId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
      shopId: DEMO_SHOP_ID,
      roles: ['waiter'],
      displayName: 'Demo Waiter',
    },
    {
      userId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4',
      shopId: DEMO_SHOP_ID,
      roles: ['kitchen'],
      displayName: 'Demo Kitchen',
    },
    {
      userId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
      shopId: OTHER_SHOP_ID,
      roles: ['admin'],
      displayName: 'Other Admin',
    },
    {
      userId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',
      shopId: OTHER_SHOP_ID,
      roles: ['cashier'],
      displayName: 'Other Cashier',
    },
  ],
  tables: [
    diningTable('77777777-7777-4777-8777-777777777701', DEMO_SHOP_ID, 'Salle 1', 1),
    diningTable('77777777-7777-4777-8777-777777777702', DEMO_SHOP_ID, 'Salle 2', 2),
    diningTable('77777777-7777-4777-8777-777777777703', DEMO_SHOP_ID, 'Salle 3', 3),
    diningTable('77777777-7777-4777-8777-777777777704', DEMO_SHOP_ID, 'Terrasse 1', 4),
    diningTable('77777777-7777-4777-8777-777777777705', DEMO_SHOP_ID, 'Terrasse 2', 5),
    diningTable('77777777-7777-4777-8777-777777777706', DEMO_SHOP_ID, 'Terrasse 3', 6),
    diningTable('77777777-7777-4777-8777-777777777707', DEMO_SHOP_ID, 'Comptoir', 7),
    // Put away for the winter: it stays on the admin's list and refuses anything new.
    diningTable('77777777-7777-4777-8777-777777777708', DEMO_SHOP_ID, 'Terrasse 4', 8, false),
    diningTable('77777777-7777-4777-8777-777777777711', OTHER_SHOP_ID, 'Other table 1', 1),
  ],
  categories: [fraiches, chaudes, snacks, patisserie, general],
  products: [
    product(
      '55555555-5555-4555-8555-555555555501',
      fraiches,
      'Eau minérale 50 cl',
      mm(850),
      '6194000100015',
      120,
    ),
    product(
      '55555555-5555-4555-8555-555555555502',
      fraiches,
      'Boga Cidre 33 cl',
      mm(1_350),
      '6194000200012',
      60,
    ),
    product(
      '55555555-5555-4555-8555-555555555503',
      chaudes,
      'Café express',
      mm(1_900),
      '6194000200029',
      8,
    ),
    product(
      '55555555-5555-4555-8555-555555555504',
      chaudes,
      'Café crème',
      mm(2_450),
      '6194000300019',
      40,
    ),
    product(
      '55555555-5555-4555-8555-555555555505',
      chaudes,
      'Thé à la menthe',
      mm(2_100),
      '6194000300026',
      55,
    ),
    product(
      '55555555-5555-4555-8555-555555555506',
      snacks,
      'Petit-déjeuner complet',
      mm(18_500),
      '6194000300033',
      25,
    ),
    product(
      '55555555-5555-4555-8555-555555555507',
      snacks,
      'Assiette de bricks',
      mm(7_800),
      '6194000300040',
      0,
      // Sold out today: still on the menu, greyed out, and nothing already ordered is touched.
      false,
    ),
    product(
      '55555555-5555-4555-8555-555555555508',
      snacks,
      'Salade tunisienne',
      mm(4_200),
      '6194000300057',
      30,
    ),
    product('55555555-5555-4555-8555-555555555509', patisserie, 'Pain', mm(200), '', 150),
    product('55555555-5555-4555-8555-555555555510', patisserie, 'Bambalouni', mm(450), '', 80),
    product(
      '55555555-5555-4555-8555-555555555511',
      fraiches,
      'Citronnade',
      mm(3_950),
      '6194000100022',
      35,
    ),
    product(
      '55555555-5555-4555-8555-555555555512',
      snacks,
      'Omelette merguez',
      mm(6_700),
      '6194000300064',
      20,
    ),
    product(
      '66666666-6666-4666-8666-666666666601',
      general,
      'Other product A',
      mm(1_000),
      '9990000000011',
      10,
    ),
    product(
      '66666666-6666-4666-8666-666666666602',
      general,
      'Other product B',
      mm(2_500),
      '9990000000028',
      10,
    ),
  ],
};
