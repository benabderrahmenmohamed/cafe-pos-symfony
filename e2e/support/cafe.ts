/**
 * The café as the people in it drive it — the waiter's phone, the kitchen screen, the counter and the
 * back office. Every helper works a screen by its roles and the words on it, never a class name, so a
 * rewrite of the markup that keeps the app usable keeps the specs passing. Both specs use them: the
 * credential-free demo on one device, and three devices against the Symfony server.
 */
import { expect, type Locator, type Page } from '@playwright/test';

/** The faces signing in lands on (src/features/auth/roles.ts), by the heading each one wears. */
export type Face = 'admin' | 'caisse' | 'serveur' | 'kitchen';

const FACE_PATHS: Record<Face, RegExp> = {
  admin: /\/admin$/,
  caisse: /\/caisse$/,
  serveur: /\/serveur$/,
  kitchen: /\/kitchen$/,
};

/** A string as a regular expression that matches it literally. */
function literal(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Signing in and out

/** The accounts the memory backend offers on its login page (src/adapters/memory/seed.ts). */
export type DemoAccount = 'Owner' | 'Cashier' | 'Waiter' | 'Kitchen';

const DEMO_HOME: Record<DemoAccount, Face> = {
  Owner: 'admin',
  Cashier: 'caisse',
  Waiter: 'serveur',
  Kitchen: 'kitchen',
};

/** Loads the app and waits for its way in. */
export async function openApp(page: Page): Promise<void> {
  await page.goto('/');
  await expect(page.getByRole('button', { name: 'Login' })).toBeVisible();
}

/** Memory demo: signs in with one of its "Continue as" buttons and waits for the face it lands on. */
export async function continueAs(page: Page, account: DemoAccount): Promise<void> {
  await page.getByRole('button', { name: `Continue as ${account}` }).click();
  await expect(page).toHaveURL(FACE_PATHS[DEMO_HOME[account]]);
}

/** A real backend: signs in with the form and waits for `face`. */
export async function signIn(
  page: Page,
  credentials: { readonly email: string; readonly password: string },
  face: Face,
): Promise<void> {
  await page.getByLabel('Email').fill(credentials.email);
  await page.getByLabel('Password').fill(credentials.password);
  await page.getByRole('button', { name: 'Login' }).click();
  await expect(page).toHaveURL(FACE_PATHS[face]);
}

export async function signOut(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Logout' }).click();
  await expect(page.getByRole('button', { name: 'Login' })).toBeVisible();
}

/** The chip in every face's header: the one place a person reads whether their taps went out. */
export function syncChip(page: Page): Locator {
  return page.getByRole('link', { name: /^Sync:/ });
}

// The back office

/** Admin: registers the browser this test drives as terminal `code`, from Settings. */
export async function registerThisDeviceAs(page: Page, code: string): Promise<void> {
  await page.getByRole('link', { name: 'Settings', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
  await page.getByLabel('Register As').fill(code);
  // The card asks before registering, and Playwright dismisses a dialog nobody handles.
  page.once('dialog', (dialog) => void dialog.accept());
  await page.getByRole('button', { name: 'Register Device' }).click();
  await expect(page.getByText(`This device is now terminal ${code}`)).toBeVisible();
}

/** Admin: adds a table to the room, from Tables. */
export async function addTableToRoom(page: Page, name: string): Promise<void> {
  await page.getByRole('link', { name: 'Tables', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Tables' })).toBeVisible();
  await page.getByRole('button', { name: 'Add table' }).click();
  const dialog = page.getByRole('dialog', { name: 'Add a table' });
  await dialog.getByLabel('Name').fill(name);
  await dialog.getByRole('button', { name: 'Add table' }).click();
  await expect(page.getByRole('row', { name: new RegExp(literal(name)) })).toBeVisible();
}

// The room

/** A table's tile on the grid; its accessible name starts with the table's name. */
export function tableTile(page: Page, name: string): Locator {
  return page.getByRole('button', { name: new RegExp(`^${literal(name)}`) });
}

/** A waiter taps a table and waits for its screen. */
export async function openTable(page: Page, name: string): Promise<void> {
  await tableTile(page, name).click();
  await expect(page.getByRole('heading', { name, exact: true })).toBeVisible();
}

/** One row of the table on screen; the toasts outside the page are list items too. */
export function tableRow(page: Page, product: string): Locator {
  return page.getByRole('main').getByRole('listitem').filter({ hasText: product });
}

export interface MenuChoice {
  readonly product: string;
  readonly qty?: number;
  readonly note?: string;
}

/** The waiter's menu, open over the table. */
function menuSheet(page: Page): Locator {
  return page.getByRole('dialog', { name: 'Add to the table' });
}

/** A waiter adds each choice to the open table, from the menu, and closes the menu. */
export async function addToTable(page: Page, ...choices: readonly MenuChoice[]): Promise<void> {
  await page.getByRole('button', { name: 'Add', exact: true }).click();
  const sheet = menuSheet(page);
  await expect(sheet).toBeVisible();
  for (const { product, qty = 1, note = '' } of choices) {
    await sheet.getByRole('button', { name: new RegExp(`^${literal(product)}`) }).click();
    for (let more = 1; more < qty; more += 1) {
      await sheet.getByRole('button', { name: 'One more' }).click();
    }
    if (note !== '') {
      await sheet.getByLabel('Note for the kitchen').fill(note);
    }
    await sheet.getByRole('button', { name: 'Add to the table' }).click();
    // Back on the list, ready for the next choice: the item is on the table.
    await expect(sheet.getByLabel('Search the menu')).toBeVisible();
  }
  await page.keyboard.press('Escape');
  await expect(sheet).toBeHidden();
}

/** A waiter tells the kitchen about everything on the table not sent yet. */
export async function sendToKitchen(page: Page, count: number): Promise<void> {
  await page.getByRole('button', { name: `Send ${count}` }).click();
  await expect(page.getByRole('button', { name: 'Nothing to send' })).toBeVisible();
}

// The kitchen

/** The kitchen's card for one send to `table`. */
export function ticket(page: Page, table: string): Locator {
  return page.getByRole('article').filter({ has: page.getByRole('heading', { name: table }) });
}

// The counter

/** Cashier: opens the terminal's session with a counted float, in dinars. */
export async function openSessionWithFloat(page: Page, float: string): Promise<void> {
  await expect(page.getByText('Open a session')).toBeVisible();
  await page.getByLabel('Opening float (DT)').fill(float);
  await page.getByRole('button', { name: 'Open session' }).click();
  // The counter is on screen once the session is on this device; it never waits for the server.
  await expect(page.getByRole('button', { name: 'Close session' })).toBeVisible();
}

/** The receipt the counter shows the moment a payment is written: the only dialog with Done. */
export function receiptDialog(page: Page): Locator {
  return page
    .getByRole('dialog')
    .filter({ has: page.getByRole('button', { name: 'Done' }) })
    .first();
}

/** Cashier: picks the table, ticks everything on it and opens the payment. */
export async function startPayingWholeTable(page: Page, table: string): Promise<Locator> {
  await tableTile(page, table).click();
  await page.getByRole('button', { name: 'Everything' }).click();
  await page.getByRole('button', { name: 'Pay the whole table' }).click();
  const checkout = page.getByRole('dialog', { name: new RegExp(`^${literal(table)} — `) });
  await expect(checkout).toBeVisible();
  return checkout;
}

/** Confirms a payment in cash at the total and leaves the receipt on screen for the caller. */
export async function confirmPayment(page: Page, checkout: Locator): Promise<Locator> {
  await checkout.getByRole('button', { name: 'Confirm' }).click();
  const receipt = receiptDialog(page);
  await expect(receipt).toBeVisible();
  return receipt;
}

export async function closeReceipt(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Done' }).click();
  await expect(receiptDialog(page)).toBeHidden();
}

/** Opens this terminal's sales, which lists what the server holds and what is still on the way. */
export async function openSales(page: Page): Promise<Locator> {
  await page.getByRole('button', { name: 'Sales' }).click();
  const sheet = page
    .getByRole('dialog')
    .filter({ hasText: 'Recent sales and refunds of this terminal' });
  await expect(sheet).toBeVisible();
  return sheet;
}

export async function closeSheet(page: Page, sheet: Locator): Promise<void> {
  await page.keyboard.press('Escape');
  await expect(sheet).toBeHidden();
}

// Touch targets

/** The smallest a target may be, each way, on the waiter's phone. */
export const MIN_TARGET_PX = 44;

/**
 * Fails unless every target a person can reach on screen now is at least MIN_TARGET_PX wide and tall.
 * A target is anything focusable or pressable: links, buttons, form fields, switches. What an open
 * dialog hides from the accessibility tree is not reachable, so it is not counted; neither are the
 * toasts, which no one taps, nor the invisible focus guards around a dialog.
 */
export async function expectTouchTargets(page: Page, where: string): Promise<void> {
  const small = await page.evaluate(async (min) => {
    // A dialog zooms in from 95 %: measured mid-animation, a 44 px button reads 43. What runs for
    // ever — a spinning sync icon — is left out of the wait.
    const finite = document
      .getAnimations()
      .filter((animation) => animation.effect?.getComputedTiming().iterations !== Infinity);
    await Promise.all(finite.map((animation) => animation.finished.catch(() => undefined)));
    const selector = [
      'a[href]',
      'button',
      'input:not([type="hidden"])',
      'select',
      'textarea',
      '[role="button"]',
      '[role="switch"]',
      '[role="checkbox"]',
      '[role="link"]',
      '[tabindex]:not([tabindex="-1"])',
    ].join(',');
    const reachable = (element: Element): boolean => {
      if (element.closest('[aria-hidden="true"], [inert], [data-sonner-toaster]')) {
        return false;
      }
      if (element.hasAttribute('data-radix-focus-guard')) {
        return false;
      }
      const style = getComputedStyle(element);
      const box = element.getBoundingClientRect();
      return style.visibility !== 'hidden' && style.display !== 'none' && box.width > 0;
    };
    return [...document.querySelectorAll(selector)].filter(reachable).flatMap((element) => {
      const box = element.getBoundingClientRect();
      if (box.width >= min && box.height >= min) {
        return [];
      }
      const label =
        element.getAttribute('aria-label') ??
        element.textContent?.trim().slice(0, 40) ??
        element.tagName.toLowerCase();
      return [
        `${label || element.tagName.toLowerCase()}: ${Math.round(box.width)}×${Math.round(box.height)}`,
      ];
    });
  }, MIN_TARGET_PX);
  expect(small, `targets smaller than ${MIN_TARGET_PX} px on ${where}`).toEqual([]);
}

// The queue

/** Follows the sync chip to the face's Conflicts screen. */
export async function openConflicts(page: Page): Promise<Locator> {
  await syncChip(page).click();
  await expect(page.getByRole('heading', { name: 'Conflicts', level: 1 })).toBeVisible();
  return page.getByRole('main');
}
