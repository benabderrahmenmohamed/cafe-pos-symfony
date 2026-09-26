import { changeDue, totals, type Cart } from '@/features/caisse/cart';
import type { TerminalContext } from '@/features/terminal/types';
import { AppError } from '@/lib/errors';
import { add, mm, neg, ZERO, type Millimes } from '@/lib/money';
import { withPayloadHash } from '@/lib/payloadHash';
import { parseOrInvalid } from '@/lib/validation';
import {
  saleRecordSchema,
  type PaymentMethod,
  type Sale,
  type SaleLine,
  type SaleRecord,
} from '@/ports';

/** Fields every numbered record needs from the device. */
export interface RecordEnvelope {
  readonly id: string;
  readonly seq: number;
  readonly sessionId: string;
  readonly createdAt: string;
  readonly terminal: TerminalContext;
  /**
   * The table being paid, or null for a counter sale — a coffee taken away that never sat on one.
   * The server checks every line against this table's open order, so it is what turns a payment
   * into "these rows of that table are paid" rather than "some products were sold".
   */
  readonly tableId: string | null;
}

export function receiptNumber(terminalCode: string, seq: number): string {
  return `${terminalCode}-${seq}`;
}

/**
 * The row id of line `lineNo` of the record `recordId`: the first sixteen bytes of
 * SHA-256("<record id>:<line no>"), laid out as a UUID.
 *
 * The device names its own rows, as it names the record, because a refund can be written before the
 * sale it gives back has reached a server — a register that sold offline and is refunding the same
 * receipt — and the line it points at has to have an id by then. `record_sale` stores what it was
 * given (api/migrations/sql/0001_schema.sql).
 *
 * Derived rather than random so that the same sale, built twice, is the same record down to its
 * hash: two records could then never be stored under one id with different contents.
 */
async function saleLineId(recordId: string, lineNo: number): Promise<string> {
  const bytes = new TextEncoder().encode(`${recordId}:${lineNo}`);
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  const hex = Array.from(digest.slice(0, 16), (byte) => byte.toString(16).padStart(2, '0')).join(
    '',
  );
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function invalid(message: string, details?: Record<string, unknown>): AppError {
  return new AppError('VALIDATION_ERROR', message, { details });
}

/**
 * A sale record from the cart. Cash uses `tenderedMillimes` (the total when omitted) and computes
 * change; card is always exactly the total.
 */
export async function buildSaleRecord(
  envelope: RecordEnvelope,
  cart: Cart,
  payment: { readonly method: PaymentMethod; readonly tenderedMillimes?: Millimes },
): Promise<SaleRecord> {
  if (cart.lines.length === 0) {
    throw invalid('The cart is empty');
  }
  const cartTotals = totals(cart);
  const lines: SaleLine[] = await Promise.all(
    cart.lines.map(async (line, index) => ({
      id: await saleLineId(envelope.id, index + 1),
      lineNo: index + 1,
      // The row of the table this line pays; null when nothing was on a table.
      openOrderItemId: line.orderItemId ?? null,
      productId: line.productId,
      productName: line.name,
      qty: line.qty,
      unitPriceMillimes: line.unitPriceMillimes,
      lineDiscountMillimes: cartTotals.lines[index].lineDiscountMillimes,
      lineDiscountReason: line.lineDiscountReason ?? null,
      allocatedDiscountMillimes: cartTotals.lines[index].cartDiscountShareMillimes,
      netMillimes: cartTotals.lines[index].totalMillimes,
      refundsSaleLineId: null,
    })),
  );
  const total = cartTotals.totalMillimes;
  const tendered = payment.method === 'cash' ? (payment.tenderedMillimes ?? total) : total;
  const record = await withPayloadHash({
    id: envelope.id,
    kind: 'sale' as const,
    terminalCode: envelope.terminal.terminalCode,
    epoch: envelope.terminal.epoch,
    seq: envelope.seq,
    sessionId: envelope.sessionId,
    tableId: envelope.tableId,
    createdAt: envelope.createdAt,
    lines,
    cartDiscountMillimes: cartTotals.discountMillimes,
    totalMillimes: total,
    payment: {
      method: payment.method,
      tenderedMillimes: tendered,
      changeMillimes: payment.method === 'cash' ? changeDue(total, tendered) : ZERO,
    },
    refundsSaleId: null,
  });
  return parseOrInvalid(saleRecordSchema, record, 'the sale');
}

/**
 * The amount for refunding `refunding` of a line's `units`, after `alreadyRefunded` were refunded:
 * C(already + refunding) − C(already) with C(x) = floor(net × x / units). However a line is refunded
 * in parts, the parts add up to exactly its net amount.
 */
export function refundShare(
  netMillimes: Millimes,
  units: number,
  alreadyRefunded: number,
  refunding: number,
): Millimes {
  if (
    !Number.isSafeInteger(units) ||
    !Number.isSafeInteger(alreadyRefunded) ||
    !Number.isSafeInteger(refunding) ||
    units < 1 ||
    alreadyRefunded < 0 ||
    refunding < 1 ||
    alreadyRefunded + refunding > units ||
    netMillimes < 0
  ) {
    throw invalid('A refund must take between one unit and what is left of the line', {
      units,
      alreadyRefunded,
      refunding,
    });
  }
  const cumulative = (count: number) => (BigInt(netMillimes) * BigInt(count)) / BigInt(units);
  return mm(Number(cumulative(alreadyRefunded + refunding) - cumulative(alreadyRefunded)));
}

export interface RefundSelection {
  /** The line number on the original sale. */
  readonly lineNo: number;
  readonly qty: number;
}

/** A refund record for chosen units of `sale`. Refunds pay out exactly their total. */
export async function buildRefundRecord(
  envelope: RecordEnvelope,
  sale: Sale,
  selections: readonly RefundSelection[],
  method: PaymentMethod,
): Promise<SaleRecord> {
  if (sale.kind !== 'sale') {
    throw invalid('Only a sale can be refunded');
  }
  const chosen = selections.filter((selection) => selection.qty > 0);
  if (chosen.length === 0) {
    throw invalid('Choose at least one unit to refund');
  }
  const seen = new Set<number>();
  const lines: SaleLine[] = await Promise.all(
    chosen.map(async (selection, index) => {
      if (seen.has(selection.lineNo)) {
        throw invalid('Each line can be refunded once per refund', { lineNo: selection.lineNo });
      }
      seen.add(selection.lineNo);
      const original = sale.lines.find((line) => line.lineNo === selection.lineNo);
      if (!original) {
        throw invalid('That line is not on the sale', { lineNo: selection.lineNo });
      }
      const amount = refundShare(
        original.netMillimes,
        original.qty,
        original.refundedQty,
        selection.qty,
      );
      return {
        id: await saleLineId(envelope.id, index + 1),
        lineNo: index + 1,
        // A refund gives money back; it never pays a row of a table, so it names none.
        openOrderItemId: null,
        productId: original.productId,
        productName: original.productName,
        qty: -selection.qty,
        unitPriceMillimes: original.unitPriceMillimes,
        lineDiscountMillimes: ZERO,
        lineDiscountReason: null,
        allocatedDiscountMillimes: ZERO,
        netMillimes: neg(amount),
        refundsSaleLineId: original.id,
      };
    }),
  );
  const total = add(...lines.map((line) => line.netMillimes));
  const record = await withPayloadHash({
    id: envelope.id,
    kind: 'refund' as const,
    terminalCode: envelope.terminal.terminalCode,
    epoch: envelope.terminal.epoch,
    seq: envelope.seq,
    sessionId: envelope.sessionId,
    tableId: null,
    createdAt: envelope.createdAt,
    lines,
    cartDiscountMillimes: ZERO,
    totalMillimes: total,
    payment: { method, tenderedMillimes: total, changeMillimes: ZERO },
    refundsSaleId: sale.id,
  });
  return parseOrInvalid(saleRecordSchema, record, 'the refund');
}
