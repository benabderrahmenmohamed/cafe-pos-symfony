import { describe, expect, it } from 'vitest';
import {
  addItem,
  emptyCart,
  offerLine,
  setCartDiscount,
  type Cart,
  type CartProduct,
} from '@/features/caisse/cart';
import type { TerminalContext } from '@/features/terminal/types';
import { keysToSnake } from '@/lib/caseConversion';
import { AppError } from '@/lib/errors';
import { mm, neg, sub, type Millimes } from '@/lib/money';
import { payloadHash } from '@/lib/payloadHash';
import { saleRecordSchema, type PaymentMethod, type Sale, type SaleRecord } from '@/ports';
import {
  buildRefundRecord,
  buildSaleRecord,
  receiptNumber,
  refundShare,
  type RecordEnvelope,
} from './records';

// Black-box tests of the sale and refund records a terminal writes. `documentProblems` restates the
// document rules of record_sale (api/migrations/sql/0001_schema.sql) and the check
// constraints of public.sales and public.sale_lines, so every record built here is one the server
// accepts.

const SESSION_ID = 'a3b1c2d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
const terminal: TerminalContext = { terminalCode: 'T1', epoch: 1 };

function uuid(n: number): string {
  return `00000000-0000-4000-8000-${n.toString(16).padStart(12, '0')}`;
}

function envelope(seq: number, overrides: Partial<RecordEnvelope> = {}): RecordEnvelope {
  return {
    id: uuid(10_000 + seq),
    seq,
    sessionId: SESSION_ID,
    createdAt: '2026-09-11T09:00:00.000Z',
    terminal,
    // These carts sit on no table: the counter is where this file sells from.
    tableId: null,
    ...overrides,
  };
}

/** A line discount in these tests. A discount always says why, so every one here says the same. */
function discountLine(cart: Cart, key: string, discount: Millimes): Cart {
  return offerLine(cart, key, discount, 'offert');
}

const first: CartProduct = { id: uuid(1), name: 'Biscuits Saida', priceMillimes: mm(1_005) };
const second: CartProduct = { id: uuid(2), name: 'Chamia 250 g', priceMillimes: mm(1_005) };
const milk: CartProduct = { id: uuid(3), name: 'Lait Délice 1 L', priceMillimes: mm(1_350) };

/**
 * first 1 × 1,005; second 1 × 1,005; milk 3 × 1,350 with 50 off (net 4,000). Subtotal 6,010; 5 % is
 * 300.5, so 301, shared as 51, 50 and 200 (the tie on the equal lines goes to the first). Line
 * totals 954, 955 and 3,800; total 5,709.
 */
function sampleCart(): Cart {
  const cart = addItem(addItem(addItem(emptyCart, first), second), milk, 3);
  return setCartDiscount(discountLine(cart, milk.id, mm(50)), 500);
}

async function rejectionOf(promise: Promise<unknown>): Promise<unknown> {
  return promise.then(
    () => expect.unreachable('expected a rejection'),
    (reason: unknown) => reason,
  );
}

async function expectRejectedAsInvalid(promise: Promise<unknown>, label?: string): Promise<void> {
  const error = await rejectionOf(promise);
  expect(error, label).toBeInstanceOf(AppError);
  expect(error, label).toHaveProperty('code', 'VALIDATION_ERROR');
}

function expectThrowsInvalid(action: () => unknown, label?: string): void {
  let error: unknown;
  try {
    action();
  } catch (caught) {
    error = caught;
  }
  expect(error, label).toBeInstanceOf(AppError);
  expect(error, label).toHaveProperty('code', 'VALIDATION_ERROR');
}

/** The sale as getSale returns it right after it was recorded. */
function saleView(record: SaleRecord): Sale {
  return {
    id: record.id,
    kind: record.kind,
    receiptNumber: receiptNumber(record.terminalCode, record.seq),
    seq: record.seq,
    terminalId: 'terminal-t1',
    terminalCode: record.terminalCode,
    sessionId: record.sessionId,
    tableId: record.tableId,
    tableName: null,
    refundsSaleId: record.refundsSaleId,
    paymentMethod: record.payment.method,
    cartDiscountMillimes: record.cartDiscountMillimes,
    totalMillimes: record.totalMillimes,
    tenderedMillimes: record.payment.tenderedMillimes,
    changeMillimes: record.payment.changeMillimes,
    createdAt: record.createdAt,
    receivedAt: record.createdAt,
    lines: record.lines.map((line) => ({ ...line, refundedQty: 0, refundedMillimes: mm(0) })),
  };
}

/** The sale as getSale returns it once `refund` was recorded. */
function afterRefund(sale: Sale, refund: SaleRecord): Sale {
  return {
    ...sale,
    lines: sale.lines.map((line) => {
      const taken = refund.lines.find((item) => item.refundsSaleLineId === line.id);
      return taken
        ? {
            ...line,
            refundedQty: line.refundedQty - taken.qty,
            refundedMillimes: sub(line.refundedMillimes, taken.netMillimes),
          }
        : line;
    }),
  };
}

/**
 * Every rule of record_sale and the ledger's check constraints that `record` breaks, as text. For a
 * refund, `refunded` is the sale as it stood before the refund arrived.
 */
function documentProblems(record: SaleRecord, refunded: Sale | null = null): string[] {
  const problems: string[] = [];
  let discount = 0n;
  let total = 0n;
  const seen = new Set<string>();
  record.lines.forEach((line, index) => {
    const at = `line ${index + 1}`;
    const qty = BigInt(line.qty);
    const unit = BigInt(line.unitPriceMillimes);
    const lineDiscount = BigInt(line.lineDiscountMillimes);
    const share = BigInt(line.allocatedDiscountMillimes);
    const lineTotal = BigInt(line.netMillimes);
    if (line.lineNo !== index + 1) {
      problems.push(`${at} is numbered ${line.lineNo}`);
    }
    if (record.kind === 'sale') {
      if (line.refundsSaleLineId !== null) {
        problems.push(`${at} refunds a line`);
      }
      if (
        qty < 1n ||
        unit < 0n ||
        lineDiscount < 0n ||
        share < 0n ||
        lineDiscount + share > qty * unit ||
        lineTotal !== qty * unit - lineDiscount - share
      ) {
        problems.push(`${at} amounts do not add up`);
      }
      discount += share;
    } else {
      const original = refunded?.lines.find((item) => item.id === line.refundsSaleLineId);
      if (line.refundsSaleLineId === null || seen.has(line.refundsSaleLineId)) {
        problems.push(`${at} names no sale line, or one named before`);
      } else {
        seen.add(line.refundsSaleLineId);
      }
      if (!original) {
        problems.push(`${at} names a line that is not on the sale`);
      } else {
        if (
          line.productId !== original.productId ||
          unit !== BigInt(original.unitPriceMillimes) ||
          lineDiscount !== 0n ||
          share !== 0n ||
          qty > -1n ||
          lineTotal > 0n
        ) {
          problems.push(`${at} does not match its sale line`);
        }
        const units = BigInt(original.refundedQty) - qty;
        const amount = BigInt(original.refundedMillimes) - lineTotal;
        if (units > BigInt(original.qty) || amount > BigInt(original.netMillimes)) {
          problems.push(`${at} refunds more than is left`);
        }
        if (units === BigInt(original.qty) && amount !== BigInt(original.netMillimes)) {
          problems.push(`${at} takes the last units without paying exactly what is left`);
        }
      }
    }
    total += lineTotal;
  });
  if (BigInt(record.cartDiscountMillimes) !== discount || BigInt(record.totalMillimes) !== total) {
    problems.push('the document totals do not match its lines');
  }
  const tendered = BigInt(record.payment.tenderedMillimes);
  const change = BigInt(record.payment.changeMillimes);
  if (record.kind === 'refund' || record.payment.method === 'card') {
    if (tendered !== total || change !== 0n) {
      problems.push('a card payment or a refund is not exactly the total with no change');
    }
  } else if (tendered < total || change !== tendered - total) {
    problems.push('cash change is not the amount tendered minus the total');
  }
  if (record.kind === 'sale' && (record.refundsSaleId !== null || total < 0n || discount < 0n)) {
    problems.push('the sale breaks the sales_kind_shape constraint');
  }
  if (
    record.kind === 'refund' &&
    (record.refundsSaleId !== refunded?.id ||
      refunded.kind !== 'sale' ||
      total > 0n ||
      discount !== 0n ||
      change !== 0n)
  ) {
    problems.push('the refund breaks the sales_kind_shape constraint');
  }
  return problems;
}

/** 32-bit linear congruential generator (Numerical Recipes constants): the same cases every run. */
function createRandom(seed: number): (bound: number) => number {
  let state = seed >>> 0;
  return (bound) => {
    state = (Math.imul(state, 1_664_525) + 1_013_904_223) >>> 0;
    return (state >>> 8) % bound;
  };
}

function randomCart(below: (bound: number) => number): Cart {
  let cart = emptyCart;
  for (let index = 1, count = 1 + below(5); index <= count; index += 1) {
    const price = below(6) === 0 ? 0 : below(60_000);
    const item = { id: uuid(index), name: `Product ${index}`, priceMillimes: mm(price) };
    cart = addItem(cart, item, 1 + below(7));
  }
  for (const line of cart.lines) {
    if (below(3) === 0) {
      cart = discountLine(cart, line.productId, mm(below(line.unitPriceMillimes * line.qty + 1)));
    }
  }
  return setCartDiscount(cart, [0, 10_000, below(10_001), below(2_000)][below(4)]);
}

const RECORD_KEYS = [
  'cart_discount_millimes',
  'created_at',
  'epoch',
  'id',
  'kind',
  'lines',
  'payload_hash',
  'payment',
  'refunds_sale_id',
  'seq',
  'session_id',
  'table_id',
  'terminal_code',
  'total_millimes',
];

const LINE_KEYS = [
  'allocated_discount_millimes',
  'id',
  'line_discount_millimes',
  'line_discount_reason',
  'line_no',
  'net_millimes',
  'open_order_item_id',
  'product_id',
  'product_name',
  'qty',
  'refunds_sale_line_id',
  'unit_price_millimes',
];

/** The keys record_sale reads from its payload, at each level. */
function expectRecordSaleKeys(record: SaleRecord): void {
  const wire = keysToSnake(record) as { lines: object[]; payment: object };
  expect(Object.keys(wire).sort()).toEqual(RECORD_KEYS);
  for (const line of wire.lines) {
    expect(Object.keys(line).sort()).toEqual(LINE_KEYS);
  }
  expect(Object.keys(wire.payment).sort()).toEqual([
    'change_millimes',
    'method',
    'tendered_millimes',
  ]);
}

describe('receiptNumber', () => {
  it('is the terminal code, a dash and the sequence number', () => {
    expect(receiptNumber('T1', 42)).toBe('T1-42');
    expect(receiptNumber('CAISSE2', 1)).toBe('CAISSE2-1');
  });
});

describe('buildSaleRecord', () => {
  it('numbers the cart lines and carries the cart totals, with the discount shared out', async () => {
    const record = await buildSaleRecord(envelope(7), sampleCart(), {
      method: 'cash',
      tenderedMillimes: mm(6_000),
    });
    const fields = {
      id: uuid(10_007),
      kind: 'sale',
      terminalCode: 'T1',
      epoch: 1,
      seq: 7,
      sessionId: SESSION_ID,
      tableId: null,
      createdAt: '2026-09-11T09:00:00.000Z',
      lines: [
        {
          id: record.lines[0].id,
          lineNo: 1,
          productId: first.id,
          openOrderItemId: null,
          productName: 'Biscuits Saida',
          qty: 1,
          unitPriceMillimes: 1_005,
          lineDiscountMillimes: 0,
          lineDiscountReason: null,
          allocatedDiscountMillimes: 51,
          netMillimes: 954,
          refundsSaleLineId: null,
        },
        {
          id: record.lines[1].id,
          lineNo: 2,
          productId: second.id,
          openOrderItemId: null,
          productName: 'Chamia 250 g',
          qty: 1,
          unitPriceMillimes: 1_005,
          lineDiscountMillimes: 0,
          lineDiscountReason: null,
          allocatedDiscountMillimes: 50,
          netMillimes: 955,
          refundsSaleLineId: null,
        },
        {
          id: record.lines[2].id,
          lineNo: 3,
          productId: milk.id,
          openOrderItemId: null,
          productName: 'Lait Délice 1 L',
          qty: 3,
          unitPriceMillimes: 1_350,
          lineDiscountMillimes: 50,
          lineDiscountReason: 'offert',
          allocatedDiscountMillimes: 200,
          netMillimes: 3_800,
          refundsSaleLineId: null,
        },
      ],
      cartDiscountMillimes: 301,
      totalMillimes: 5_709,
      payment: { method: 'cash', tenderedMillimes: 6_000, changeMillimes: 291 },
      refundsSaleId: null,
    };

    expect(record).toEqual({ ...fields, payloadHash: await payloadHash(fields) });
    expect(documentProblems(record)).toEqual([]);
  });

  it('is a valid port record whose hash covers exactly what it holds', async () => {
    const record = await buildSaleRecord(envelope(7), sampleCart(), { method: 'card' });

    expect(saleRecordSchema.parse(record)).toEqual(record);
    expect(await payloadHash(record)).toBe(record.payloadHash);
    expectRecordSaleKeys(record);
  });

  it('gives the same hash for the same sale, and a new one for another number or registration', async () => {
    const payment = { method: 'cash' as const, tenderedMillimes: mm(10_000) };
    const hash = async (next: RecordEnvelope) =>
      (await buildSaleRecord(next, sampleCart(), payment)).payloadHash;
    const base = await hash(envelope(7));

    expect(await hash(envelope(7))).toBe(base);
    const others = [
      await hash(envelope(8, { id: uuid(10_007) })),
      await hash(envelope(7, { id: uuid(20_007) })),
      await hash(envelope(7, { terminal: { terminalCode: 'T1', epoch: 2 } })),
      await hash(envelope(7, { sessionId: uuid(99) })),
    ];
    expect(new Set([base, ...others]).size).toBe(5);
  });

  it('takes the total as the cash tendered when no amount is given, with no change', async () => {
    const record = await buildSaleRecord(envelope(1), sampleCart(), { method: 'cash' });

    expect(record.payment).toEqual({ method: 'cash', tenderedMillimes: 5_709, changeMillimes: 0 });
    expect(documentProblems(record)).toEqual([]);
  });

  it('gives cash change down to the millime, and none for the exact amount', async () => {
    const pay = async (tendered: number) =>
      (
        await buildSaleRecord(envelope(1), sampleCart(), {
          method: 'cash',
          tenderedMillimes: mm(tendered),
        })
      ).payment;

    expect(await pay(5_710)).toEqual({
      method: 'cash',
      tenderedMillimes: 5_710,
      changeMillimes: 1,
    });
    expect(await pay(5_709)).toEqual({
      method: 'cash',
      tenderedMillimes: 5_709,
      changeMillimes: 0,
    });
    expect(await pay(50_000)).toEqual({
      method: 'cash',
      tenderedMillimes: 50_000,
      changeMillimes: 44_291,
    });
  });

  it('refuses a cash tender short of the total, even by one millime', async () => {
    await expectRejectedAsInvalid(
      buildSaleRecord(envelope(1), sampleCart(), { method: 'cash', tenderedMillimes: mm(5_708) }),
    );
    await expectRejectedAsInvalid(
      buildSaleRecord(envelope(1), sampleCart(), { method: 'cash', tenderedMillimes: mm(0) }),
    );
  });

  it('records a card payment as exactly the total with no change, whatever amount is passed', async () => {
    for (const tenderedMillimes of [undefined, mm(0), mm(5_708), mm(10_000)]) {
      const record = await buildSaleRecord(envelope(1), sampleCart(), {
        method: 'card',
        tenderedMillimes,
      });

      expect(record.payment, String(tenderedMillimes)).toEqual({
        method: 'card',
        tenderedMillimes: 5_709,
        changeMillimes: 0,
      });
      expect(documentProblems(record)).toEqual([]);
    }
  });

  it('records a fully discounted cart as a sale of zero', async () => {
    const cart = setCartDiscount(sampleCart(), 10_000);

    for (const method of ['cash', 'card'] as const) {
      const record = await buildSaleRecord(envelope(1), cart, { method });
      expect(record).toMatchObject({
        cartDiscountMillimes: 6_010,
        totalMillimes: 0,
        payment: { method, tenderedMillimes: 0, changeMillimes: 0 },
      });
      expect(documentProblems(record)).toEqual([]);
    }
  });

  it('refuses an empty cart with VALIDATION_ERROR', async () => {
    await expectRejectedAsInvalid(buildSaleRecord(envelope(1), emptyCart, { method: 'cash' }));
    await expectRejectedAsInvalid(buildSaleRecord(envelope(1), emptyCart, { method: 'card' }));
  });

  it('always builds a sale record_sale accepts, over many pseudo-random carts', async () => {
    const below = createRandom(0x5a1e);
    const failures: string[] = [];
    const runs = 400;
    for (let run = 1; run <= runs; run += 1) {
      const cart = randomCart(below);
      const method: PaymentMethod = below(2) === 0 ? 'cash' : 'card';
      const record = await buildSaleRecord(envelope(run), cart, { method });
      const extra = below(3) === 0 ? 0 : below(20_000);
      const withChange = await buildSaleRecord(envelope(run), cart, {
        method,
        tenderedMillimes: mm(record.totalMillimes + extra),
      });
      const problems = [...documentProblems(record), ...documentProblems(withChange)];
      if (withChange.payment.changeMillimes !== (method === 'cash' ? extra : 0)) {
        problems.push(`change ${withChange.payment.changeMillimes} for ${extra} extra`);
      }
      if ((await payloadHash(withChange)) !== withChange.payloadHash) {
        problems.push('the hash does not cover the record');
      }
      if (problems.length > 0) {
        failures.push(JSON.stringify({ cart, method, problems }));
      }
    }
    expect(failures.slice(0, 3), `${failures.length} of ${runs} carts failed`).toEqual([]);
  }, 30_000);
});

describe('refundShare', () => {
  it('splits 1,000 millimes over three units refunded one by one as 333, 333 and 334', () => {
    const parts = [refundShare(mm(1_000), 3, 0, 1), refundShare(mm(1_000), 3, 1, 1)];
    parts.push(refundShare(mm(1_000), 3, 2, 1));

    expect(parts).toEqual([333, 333, 334]);
    expect(parts.reduce((sum, part) => sum + part, 0)).toBe(1_000);
  });

  it('pays the whole amount for all three units at once, and the same in two parts', () => {
    expect(refundShare(mm(1_000), 3, 0, 3)).toBe(1_000);
    expect([refundShare(mm(1_000), 3, 0, 2), refundShare(mm(1_000), 3, 2, 1)]).toEqual([666, 334]);
    expect([refundShare(mm(1_000), 3, 0, 1), refundShare(mm(1_000), 3, 1, 2)]).toEqual([333, 667]);
  });

  it('adds up to exactly the line amount however the units are split, never paying more than is left', () => {
    const failures: string[] = [];
    for (const net of [0, 1, 2, 5, 954, 999, 1_000, 1_001, 3_800, 5_709, 123_457]) {
      for (let units = 1; units <= 7; units += 1) {
        // Every ordered way to split `units` into parts: bit i set means a cut after unit i + 1.
        for (let cuts = 0; cuts < 2 ** (units - 1); cuts += 1) {
          const sizes: number[] = [];
          let size = 1;
          for (let unit = 1; unit < units; unit += 1) {
            if (cuts & (2 ** (unit - 1))) {
              sizes.push(size);
              size = 1;
            } else {
              size += 1;
            }
          }
          sizes.push(size);

          let refunded = 0;
          let paid = 0;
          for (const refunding of sizes) {
            const part = refundShare(mm(net), units, refunded, refunding);
            const label = `net ${net}, ${units} units split ${sizes.join('+')}`;
            if (part < 0 || part > net - paid) {
              failures.push(`${label}: ${part} with ${net - paid} left`);
            }
            // Within one millime of the exact share.
            if (Math.abs(part * units - refunding * net) >= units) {
              failures.push(`${label}: ${part} is not proportional`);
            }
            refunded += refunding;
            paid += part;
            if (refunded === units && paid !== net) {
              failures.push(`${label}: paid ${paid} in total`);
            }
          }
        }
      }
    }
    expect(failures.slice(0, 5), `${failures.length} splits failed`).toEqual([]);
  });

  it('stays exact where net times units is beyond floating-point precision', () => {
    const net = Number.MAX_SAFE_INTEGER;
    const cumulative = (count: bigint) => (BigInt(net) * count) / 7n;
    const parts = [refundShare(mm(net), 7, 0, 3), refundShare(mm(net), 7, 3, 4)];

    expect(parts).toEqual([Number(cumulative(3n)), Number(cumulative(7n) - cumulative(3n))]);
    expect(BigInt(parts[0]) + BigInt(parts[1])).toBe(BigInt(net));
  });

  it.each<[string, number, number, number, number]>([
    ['no unit', 1_000, 3, 0, 0],
    ['a negative number of units', 1_000, 3, 0, -1],
    ['more units than the line has', 1_000, 3, 0, 4],
    ['more units than are left', 1_000, 3, 2, 2],
    ['a line already fully refunded', 1_000, 3, 3, 1],
    ['a line of no units', 1_000, 0, 0, 1],
    ['a negative count already refunded', 1_000, 3, -1, 1],
    ['a negative line amount', -1_000, 3, 0, 1],
    ['a fraction of a unit', 1_000, 3, 0, 1.5],
    ['a fractional line', 1_000, 2.5, 0, 1],
    ['a fractional count already refunded', 1_000, 3, 0.5, 1],
    ['NaN units', 1_000, 3, 0, Number.NaN],
  ])('refuses %s with VALIDATION_ERROR', (_label, net, units, already, refunding) => {
    expectThrowsInvalid(() => refundShare(mm(net), units, already, refunding));
  });
});

describe('buildRefundRecord', () => {
  async function recordedSale(): Promise<Sale> {
    return saleView(
      await buildSaleRecord(envelope(7), sampleCart(), {
        method: 'cash',
        tenderedMillimes: mm(6_000),
      }),
    );
  }

  it('refunds chosen units as negative lines pointing at the sale, paying out exactly the total', async () => {
    const sale = await recordedSale();
    const record = await buildRefundRecord(
      envelope(8),
      sale,
      [
        { lineNo: 3, qty: 1 },
        { lineNo: 1, qty: 1 },
      ],
      'cash',
    );
    const fields = {
      id: uuid(10_008),
      kind: 'refund',
      terminalCode: 'T1',
      epoch: 1,
      seq: 8,
      sessionId: SESSION_ID,
      tableId: null,
      createdAt: '2026-09-11T09:00:00.000Z',
      lines: [
        {
          id: record.lines[0].id,
          lineNo: 1,
          productId: milk.id,
          openOrderItemId: null,
          productName: 'Lait Délice 1 L',
          qty: -1,
          unitPriceMillimes: 1_350,
          lineDiscountMillimes: 0,
          lineDiscountReason: null,
          allocatedDiscountMillimes: 0,
          netMillimes: -1_266,
          refundsSaleLineId: sale.lines[2].id,
        },
        {
          id: record.lines[1].id,
          lineNo: 2,
          productId: first.id,
          openOrderItemId: null,
          productName: 'Biscuits Saida',
          qty: -1,
          unitPriceMillimes: 1_005,
          lineDiscountMillimes: 0,
          lineDiscountReason: null,
          allocatedDiscountMillimes: 0,
          netMillimes: -954,
          refundsSaleLineId: sale.lines[0].id,
        },
      ],
      cartDiscountMillimes: 0,
      totalMillimes: -2_220,
      payment: { method: 'cash', tenderedMillimes: -2_220, changeMillimes: 0 },
      refundsSaleId: sale.id,
    };

    expect(record).toEqual({ ...fields, payloadHash: await payloadHash(fields) });
    expect(saleRecordSchema.parse(record)).toEqual(record);
    expect(documentProblems(record, sale)).toEqual([]);
    expectRecordSaleKeys(record);
  });

  it('pays a card refund out as exactly the total too, with no change', async () => {
    const sale = await recordedSale();
    const record = await buildRefundRecord(envelope(8), sale, [{ lineNo: 2, qty: 1 }], 'card');

    expect(record.payment).toEqual({ method: 'card', tenderedMillimes: -955, changeMillimes: 0 });
    expect(documentProblems(record, sale)).toEqual([]);
  });

  it('refunds a line one unit at a time in parts that add up to its amount, the last paying what is left', async () => {
    let sale = await recordedSale();
    const parts: number[] = [];
    for (const seq of [8, 9, 10]) {
      const record = await buildRefundRecord(envelope(seq), sale, [{ lineNo: 3, qty: 1 }], 'cash');
      expect(documentProblems(record, sale), `refund ${seq}`).toEqual([]);
      parts.push(neg(record.totalMillimes));
      sale = afterRefund(sale, record);
    }

    // C(x) = floor(3,800 × x / 3): 1,266, then 2,533 − 1,266, then 3,800 − 2,533.
    expect(parts).toEqual([1_266, 1_267, 1_267]);
    expect(sale.lines[2]).toMatchObject({ refundedQty: 3, refundedMillimes: 3_800 });
    await expectRejectedAsInvalid(
      buildRefundRecord(envelope(11), sale, [{ lineNo: 3, qty: 1 }], 'cash'),
    );
  });

  it('refunds three units at once for the whole line amount', async () => {
    const sale = await recordedSale();
    const record = await buildRefundRecord(envelope(8), sale, [{ lineNo: 3, qty: 3 }], 'cash');

    expect(record.lines[0]).toMatchObject({ qty: -3, netMillimes: -3_800 });
    expect(documentProblems(record, sale)).toEqual([]);
  });

  it('never refunds more units than are left', async () => {
    const sale = await recordedSale();
    const once = await buildRefundRecord(envelope(8), sale, [{ lineNo: 3, qty: 1 }], 'cash');
    const after = afterRefund(sale, once);

    await expectRejectedAsInvalid(
      buildRefundRecord(envelope(9), sale, [{ lineNo: 3, qty: 4 }], 'cash'),
      'more than the line',
    );
    await expectRejectedAsInvalid(
      buildRefundRecord(envelope(9), after, [{ lineNo: 3, qty: 3 }], 'cash'),
      'more than is left',
    );
    const rest = await buildRefundRecord(envelope(9), after, [{ lineNo: 3, qty: 2 }], 'cash');
    expect(rest.totalMillimes).toBe(-2_534);
    expect(documentProblems(rest, after)).toEqual([]);
  });

  it('leaves out lines with no units and numbers the rest in the order chosen', async () => {
    const sale = await recordedSale();
    const record = await buildRefundRecord(
      envelope(8),
      sale,
      [
        { lineNo: 2, qty: 0 },
        { lineNo: 3, qty: 2 },
        { lineNo: 1, qty: 1 },
      ],
      'cash',
    );

    // Selections are taken in the order of the sale's lines, whatever order they arrive in.
    expect(record.lines.map((line) => [line.lineNo, line.refundsSaleLineId, line.qty])).toEqual([
      [1, sale.lines[2].id, -2],
      [2, sale.lines[0].id, -1],
    ]);
    expect(documentProblems(record, sale)).toEqual([]);
  });

  it('refuses what is not a refund of units on the sale with VALIDATION_ERROR', async () => {
    const sale = await recordedSale();
    const refund = (selections: { lineNo: number; qty: number }[], of: Sale = sale) =>
      buildRefundRecord(envelope(8), of, selections, 'cash');

    await expectRejectedAsInvalid(refund([]), 'nothing chosen');
    await expectRejectedAsInvalid(refund([{ lineNo: 1, qty: 0 }]), 'zero units');
    await expectRejectedAsInvalid(
      refund([
        { lineNo: 3, qty: 1 },
        { lineNo: 3, qty: 1 },
      ]),
      'the same line twice',
    );
    await expectRejectedAsInvalid(refund([{ lineNo: 4, qty: 1 }]), 'a line not on the sale');
    await expectRejectedAsInvalid(
      refund([{ lineNo: 1, qty: 1 }], { ...sale, kind: 'refund' }),
      'a refund of a refund',
    );
  });

  it('refunds pseudo-random sales in pseudo-random parts that record_sale accepts, down to the last millime', async () => {
    const below = createRandom(20_260_911);
    const failures: string[] = [];
    let unequalParts = 0;
    const runs = 150;
    for (let run = 1; run <= runs; run += 1) {
      const sold = await buildSaleRecord(envelope(1), randomCart(below), { method: 'cash' });
      let sale = saleView(sold);
      let seq = 1;
      let refundedTotal = 0;
      while (sale.lines.some((line) => line.refundedQty < line.qty)) {
        const selections = sale.lines
          .filter((line) => line.refundedQty < line.qty && below(2) === 0)
          .map((line) => ({ lineNo: line.lineNo, qty: 1 + below(line.qty - line.refundedQty) }))
          .reverse();
        if (selections.length === 0) {
          continue;
        }
        seq += 1;
        const method: PaymentMethod = below(2) === 0 ? 'cash' : 'card';
        const record = await buildRefundRecord(envelope(seq), sale, selections, method);
        const problems = documentProblems(record, sale);
        if (problems.length > 0) {
          failures.push(JSON.stringify({ sale, selections, problems }));
        }
        for (const line of record.lines) {
          const original = sale.lines.find((item) => item.id === line.refundsSaleLineId);
          if (original && line.netMillimes * original.qty !== line.qty * original.netMillimes) {
            unequalParts += 1;
          }
        }
        refundedTotal += record.totalMillimes;
        sale = afterRefund(sale, record);
      }
      if (refundedTotal !== neg(sold.totalMillimes)) {
        failures.push(`sale ${run}: refunded ${refundedTotal} of ${sold.totalMillimes}`);
      }
      for (const line of sale.lines) {
        if (line.refundedMillimes !== line.netMillimes) {
          failures.push(`sale ${run} line ${line.lineNo}: ${line.refundedMillimes} left over`);
        }
      }
    }
    expect(failures.slice(0, 3), `${failures.length} problems`).toEqual([]);
    // The loop must reach refunds whose parts are not exact shares, or it proves little.
    expect(unequalParts).toBeGreaterThan(20);
  });
});
