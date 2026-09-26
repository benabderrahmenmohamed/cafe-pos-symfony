import { devices, expect, test, type Browser, type Page } from '@playwright/test';
import {
  addTableToRoom,
  addToTable,
  closeReceipt,
  confirmPayment,
  openApp,
  openSessionWithFloat,
  openTable,
  registerThisDeviceAs,
  sendToKitchen,
  signIn,
  startPayingWholeTable,
  syncChip,
  tableTile,
  ticket,
  type Face,
} from './support/cafe';

/**
 * The café on a real server, three devices at once: the waiter's phone, the kitchen screen and the
 * counter, each a browser context of its own — its own sign-in, its own device id and its own queue,
 * as three real devices have. Nothing is handed from one to another but the server, so every screen
 * here changes because another device wrote something.
 *
 * The server is the Symfony service in api/, holding the demo café `php bin/console app:seed-demo`
 * puts in it, and a screen learns what another device changed by asking it every couple of seconds.
 *
 * The run makes its own table and terminal, named after the moment it started, so it needs no reset
 * and leaves the seeded café as it found it.
 */

const OWNER = { email: 'owner@demo.local', password: 'demo-owner-2026' };
const WAITER = { email: 'waiter@demo.local', password: 'demo-waiter-2026' };
const KITCHEN = { email: 'kitchen@demo.local', password: 'demo-kitchen-2026' };

/** Realtime reaches the other devices within a second or two; a loaded CI machine gets longer. */
const LIVE = { timeout: 20_000 };

async function device(
  browser: Browser,
  baseURL: string | undefined,
  credentials: { readonly email: string; readonly password: string },
  face: Face,
  options: Parameters<Browser['newContext']>[0] = {},
): Promise<Page> {
  // A context made here does not inherit the project's options, so the address is passed on.
  const context = await browser.newContext({ ...options, baseURL });
  const page = await context.newPage();
  await openApp(page);
  await signIn(page, credentials, face);
  return page;
}

test('a table goes from the waiter’s phone to the kitchen and the till, live, on three devices', async ({
  browser,
  baseURL,
}) => {
  const run = Date.now().toString(36).slice(-5).toUpperCase();
  const terminal = `E2E${run}`;
  const table = `E2E ${run}`;

  // The counter: the owner adds a table for this run, makes this browser a terminal and opens the
  // session, then works the till.
  const counter = await device(browser, baseURL, OWNER, 'admin');
  await addTableToRoom(counter, table);
  await registerThisDeviceAs(counter, terminal);
  await counter.getByRole('link', { name: 'Caisse', exact: true }).click();
  await expect(counter).toHaveURL(/\/caisse$/);
  await openSessionWithFloat(counter, '20.000');

  // The kitchen screen, already on before anything is ordered.
  const kitchen = await device(browser, baseURL, KITCHEN, 'kitchen');
  await expect(ticket(kitchen, table)).toHaveCount(0);

  // The waiter's phone takes the order and tells the kitchen.
  const phone = await device(browser, baseURL, WAITER, 'serveur', devices['Pixel 7']);
  await openTable(phone, table);
  await addToTable(phone, { product: 'Thé à la menthe', qty: 2, note: 'Bien chaud' });
  await sendToKitchen(phone, 1);
  await expect(syncChip(phone)).toHaveAccessibleName(/^Sync: Synced/);

  // The ticket reaches the kitchen without anyone there touching anything.
  const card = ticket(kitchen, table);
  await expect(card).toContainText('2× Thé à la menthe', LIVE);
  await expect(card).toContainText('Bien chaud');
  await card.getByRole('button', { name: 'Mark Thé à la menthe prepared' }).click();
  await expect(syncChip(kitchen)).toHaveAccessibleName(/^Sync: Synced/);
  await expect(ticket(kitchen, table)).toHaveCount(0, LIVE);

  // The phone loses its network, and the next order waits on it until the network is back.
  await phone.context().setOffline(true);
  await addToTable(phone, { product: 'Express' });
  await sendToKitchen(phone, 1);
  await expect(syncChip(phone)).toHaveAccessibleName(/^Sync: 2 to send/);
  await expect(ticket(kitchen, table)).toHaveCount(0);
  await phone.context().setOffline(false);
  await expect(syncChip(phone)).toHaveAccessibleName(/^Sync: Synced/, LIVE);
  await expect(ticket(kitchen, table)).toContainText('1× Express', LIVE);

  // The counter sees what the table owes and takes it, under this terminal's first number.
  await expect(tableTile(counter, table)).toBeVisible(LIVE);
  const checkout = await startPayingWholeTable(counter, table);
  const receipt = await confirmPayment(counter, checkout);
  await expect(receipt).toContainText(`${terminal}-1`);
  await closeReceipt(counter);
  await expect(syncChip(counter)).toHaveAccessibleName(/^Sync: Synced/, LIVE);
  await expect(tableTile(counter, table)).toContainText('Free', LIVE);

  // And the table is free on the waiter's phone too.
  await expect(phone.getByText('Nothing on this table yet')).toBeVisible(LIVE);

  await Promise.all([counter, kitchen, phone].map((page) => page.context().close()));
});
