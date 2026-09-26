import { computeZReport } from '@/features/sessions/zReport';
import { AppError } from '@/lib/errors';
import { sub, ZERO, type Millimes } from '@/lib/money';
import type { CashSession, Sale, ZReport } from '@/ports';
import type { MemoryStore, MemoryTerminal, SaleRow, SessionRow } from './store';

/*
 * Checks and views shared by terminals, sessions and sales, each named after the database helper it
 * stands for. Details use the port's camelCase keys, which is what the REST adapter produces
 * from the server's snake_case ones.
 */

/**
 * The terminal a record names, in the caller's shop, as private.lock_terminal: FORBIDDEN when there
 * is none. Calls run one at a time, so there is nothing to lock.
 */
export function terminalFor(store: MemoryStore, shopId: string, code: string): MemoryTerminal {
  for (const terminal of store.terminals.values()) {
    if (terminal.shopId === shopId && terminal.code === code) {
      return terminal;
    }
  }
  throw new AppError('FORBIDDEN', 'This terminal is not registered in your shop.', {
    details: { terminalCode: code },
  });
}

/** TERMINAL_SUPERSEDED unless `epoch` is the terminal's current registration (private.require_epoch). */
export function requireEpoch(terminal: MemoryTerminal, epoch: number): void {
  if (epoch !== terminal.epoch) {
    throw new AppError(
      'TERMINAL_SUPERSEDED',
      'This terminal was registered again on another device. Register this device again.',
      { details: { terminalCode: terminal.code, currentEpoch: terminal.epoch } },
    );
  }
}

/** FORBIDDEN unless the person named on a record belongs to the shop (private.require_member). */
export function requireMember(store: MemoryStore, shopId: string, userId: string): void {
  if (store.profiles.get(userId)?.shopId !== shopId) {
    throw new AppError('FORBIDDEN', 'The person on this record is not a member of your shop.', {
      details: { actorUserId: userId },
    });
  }
}

/** SEQUENCE_GAP unless `seq` is the terminal's next receipt number. */
export function requireNextSeq(terminal: MemoryTerminal, seq: number, message: string): void {
  if (seq !== terminal.lastSeq + 1) {
    throw new AppError('SEQUENCE_GAP', message, {
      details: { expectedSeq: terminal.lastSeq + 1, receivedSeq: seq },
    });
  }
}

export function openSessionOn(store: MemoryStore, terminalId: string): SessionRow | undefined {
  for (const session of store.sessions.values()) {
    if (session.terminalId === terminalId && session.closedAt === null) {
      return session;
    }
  }
  return undefined;
}

function terminalById(store: MemoryStore, id: string): MemoryTerminal {
  const terminal = store.terminals.get(id);
  if (!terminal) {
    throw new AppError('UNKNOWN', `A stored record names a terminal that does not exist: ${id}`);
  }
  return terminal;
}

/** A session as the ports show it (private.session_json). */
export function sessionView(store: MemoryStore, session: SessionRow): CashSession {
  return {
    id: session.id,
    terminalId: session.terminalId,
    terminalCode: terminalById(store, session.terminalId).code,
    openedBy: session.openedBy,
    openedAt: session.openedAt,
    openingFloatMillimes: session.openingFloatMillimes,
    closedAt: session.closedAt,
    closedBy: session.closedBy,
    closingCountedMillimes: session.closingCountedMillimes,
    forceCloseReason: null,
    zReport: session.serverZReport === null ? null : structuredClone(session.serverZReport),
  };
}

/**
 * The report of a session from the documents and voids named on it, with the same formulas as
 * private.compute_z_report. `countedCashMillimes` is null while the session is open.
 */
export function zReportOf(
  store: MemoryStore,
  session: SessionRow,
  countedCashMillimes: Millimes | null,
): ZReport {
  const documents = Array.from(store.sales.values())
    .filter((sale) => sale.sessionId === session.id)
    .map((sale) => ({
      kind: sale.kind,
      paymentMethod: sale.paymentMethod,
      totalMillimes: sale.totalMillimes,
    }));
  const voidsCount = Array.from(store.receiptVoids.values()).filter(
    (voided) => voided.sessionId === session.id,
  ).length;
  return computeZReport({
    sessionId: session.id,
    openingFloatMillimes: session.openingFloatMillimes,
    documents,
    voidsCount,
    countedCashMillimes,
  });
}

/** The report stored when `session` closed. */
export function storedZReport(session: SessionRow): ZReport {
  if (session.serverZReport === null) {
    throw new AppError('UNKNOWN', `The closed session ${session.id} has no stored report`);
  }
  return structuredClone(session.serverZReport);
}

/** How much of the line `lineId` of sale `saleId` stored refunds have taken back, as positive amounts. */
export function refundedOf(
  store: MemoryStore,
  saleId: string,
  lineId: string,
): { readonly qty: number; readonly millimes: Millimes } {
  let qty = 0;
  let millimes = ZERO;
  for (const document of store.sales.values()) {
    if (document.refundsSaleId !== saleId) {
      continue;
    }
    for (const line of document.lines) {
      if (line.refundsSaleLineId === lineId) {
        qty -= line.qty;
        millimes = sub(millimes, line.netMillimes);
      }
    }
  }
  return { qty, millimes };
}

/** A stored sale or refund as the ports show it, with what refunds have taken back of each line. */
export function saleView(store: MemoryStore, sale: SaleRow): Sale {
  return {
    id: sale.id,
    kind: sale.kind,
    receiptNumber: sale.receiptNumber,
    seq: sale.seq,
    terminalId: sale.terminalId,
    terminalCode: terminalById(store, sale.terminalId).code,
    sessionId: sale.sessionId,
    tableId: sale.tableId,
    // The table's name as it is now, retired or not: a receipt read later still says where it was paid.
    tableName: sale.tableId === null ? null : (store.diningTables.get(sale.tableId)?.name ?? null),
    refundsSaleId: sale.refundsSaleId,
    paymentMethod: sale.paymentMethod,
    cartDiscountMillimes: sale.cartDiscountMillimes,
    totalMillimes: sale.totalMillimes,
    tenderedMillimes: sale.tenderedMillimes,
    changeMillimes: sale.changeMillimes,
    createdAt: sale.createdAt,
    receivedAt: sale.receivedAt,
    lines: sale.lines.map((line) => {
      const refunded =
        sale.kind === 'sale' ? refundedOf(store, sale.id, line.id) : { qty: 0, millimes: ZERO };
      return { ...line, refundedQty: refunded.qty, refundedMillimes: refunded.millimes };
    }),
  };
}
