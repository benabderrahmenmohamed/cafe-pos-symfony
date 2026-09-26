import { describe, expect, it } from 'vitest';
import { keysToCamel, keysToSnake } from '@/lib/caseConversion';
import { mm } from '@/lib/money';
import { zReportSchema, type PaymentMethod, type RecordKind, type ZReport } from '@/ports';
import { computeZReport, sameZReport, type ZReportDocument } from './zReport';

// Black-box tests of the local Z-report: it must give exactly what private.compute_z_report
// (api/migrations/sql/0001_schema.sql) gives for the same documents.

const SESSION_ID = 'a3b1c2d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';

function doc(kind: RecordKind, paymentMethod: PaymentMethod, total: number): ZReportDocument {
  return { kind, paymentMethod, totalMillimes: mm(total) };
}

interface LedgerRow {
  readonly kind: RecordKind;
  readonly payment_method: PaymentMethod;
  readonly total_millimes: bigint;
}

/**
 * private.compute_z_report, clause by clause, in bigint: `sum(...) filter (where ...)` is null over
 * no rows, `coalesce(-sum(...), 0)` negates before the coalesce, and the result has the snake_case
 * keys of the jsonb the database returns.
 */
function sqlZReport(
  session: { readonly id: string; readonly opening_float_millimes: bigint },
  rows: readonly LedgerRow[],
  voidsCount: number,
  counted: bigint | null,
) {
  const sum = (where: (row: LedgerRow) => boolean): bigint | null => {
    const matching = rows.filter(where);
    return matching.length === 0 ? null : matching.reduce((t, row) => t + row.total_millimes, 0n);
  };
  const negate = (value: bigint | null): bigint | null => (value === null ? null : -value);
  const coalesce = (value: bigint | null): bigint => value ?? 0n;
  const t = {
    sales_count: rows.filter((row) => row.kind === 'sale').length,
    refunds_count: rows.filter((row) => row.kind === 'refund').length,
    gross: coalesce(sum((s) => s.kind === 'sale')),
    refunds: coalesce(negate(sum((s) => s.kind === 'refund'))),
    cash_sales: coalesce(sum((s) => s.kind === 'sale' && s.payment_method === 'cash')),
    cash_refunds: coalesce(negate(sum((s) => s.kind === 'refund' && s.payment_method === 'cash'))),
    card_sales: coalesce(sum((s) => s.kind === 'sale' && s.payment_method === 'card')),
    card_refunds: coalesce(negate(sum((s) => s.kind === 'refund' && s.payment_method === 'card'))),
  };
  return {
    session_id: session.id,
    opening_float_millimes: Number(session.opening_float_millimes),
    sales_count: t.sales_count,
    refunds_count: t.refunds_count,
    gross_millimes: Number(t.gross),
    refunds_millimes: Number(t.refunds),
    net_millimes: Number(t.gross - t.refunds),
    by_method: {
      cash: {
        sales_millimes: Number(t.cash_sales),
        refunds_millimes: Number(t.cash_refunds),
        net_millimes: Number(t.cash_sales - t.cash_refunds),
      },
      card: {
        sales_millimes: Number(t.card_sales),
        refunds_millimes: Number(t.card_refunds),
        net_millimes: Number(t.card_sales - t.card_refunds),
      },
    },
    expected_cash_millimes: Number(session.opening_float_millimes + t.cash_sales - t.cash_refunds),
    counted_cash_millimes: counted === null ? null : Number(counted),
    variance_millimes:
      counted === null
        ? null
        : Number(counted - (session.opening_float_millimes + t.cash_sales - t.cash_refunds)),
    voids_count: voidsCount,
  };
}

function toRows(documents: readonly ZReportDocument[]): LedgerRow[] {
  return documents.map((document) => ({
    kind: document.kind,
    payment_method: document.paymentMethod,
    total_millimes: BigInt(document.totalMillimes),
  }));
}

/** Cash and card sales and refunds on one session, with a float, two voids and a short count. */
const mixedDocuments = [
  doc('sale', 'cash', 12_500),
  doc('sale', 'card', 8_750),
  doc('sale', 'cash', 3_250),
  doc('refund', 'cash', -1_250),
  doc('refund', 'card', -8_750),
  doc('sale', 'card', 1_005),
  doc('refund', 'cash', -333),
];

/** The report worked out by hand, with the keys of the database's jsonb. */
const MIXED_SQL_REPORT = {
  session_id: SESSION_ID,
  opening_float_millimes: 50_000,
  sales_count: 4,
  refunds_count: 3,
  gross_millimes: 25_505,
  refunds_millimes: 10_333,
  net_millimes: 15_172,
  by_method: {
    cash: { sales_millimes: 15_750, refunds_millimes: 1_583, net_millimes: 14_167 },
    card: { sales_millimes: 9_755, refunds_millimes: 8_750, net_millimes: 1_005 },
  },
  expected_cash_millimes: 64_167,
  counted_cash_millimes: 63_900,
  variance_millimes: -267,
  voids_count: 2,
};

function mixedReport(): ZReport {
  return computeZReport({
    sessionId: SESSION_ID,
    openingFloatMillimes: mm(50_000),
    documents: mixedDocuments,
    voidsCount: 2,
    countedCashMillimes: mm(63_900),
  });
}

describe('computeZReport', () => {
  it('matches the SQL formulas for a mixed session of cash and card sales and refunds', () => {
    const report = mixedReport();

    expect(
      sqlZReport(
        { id: SESSION_ID, opening_float_millimes: 50_000n },
        toRows(mixedDocuments),
        2,
        63_900n,
      ),
    ).toEqual(MIXED_SQL_REPORT);
    expect(report).toEqual(keysToCamel(MIXED_SQL_REPORT));
    expect(zReportSchema.parse(report)).toEqual(report);
  });

  it('gives the same report whatever the order of the documents', () => {
    const reversed = computeZReport({
      sessionId: SESSION_ID,
      openingFloatMillimes: mm(50_000),
      documents: [...mixedDocuments].reverse(),
      voidsCount: 2,
      countedCashMillimes: mm(63_900),
    });

    expect(reversed).toEqual(mixedReport());
  });

  it('expects exactly the float for a session without documents', () => {
    const empty = { sessionId: SESSION_ID, openingFloatMillimes: mm(20_000), documents: [] };

    expect(computeZReport({ ...empty, voidsCount: 0, countedCashMillimes: null })).toEqual({
      sessionId: SESSION_ID,
      openingFloatMillimes: 20_000,
      salesCount: 0,
      refundsCount: 0,
      grossMillimes: 0,
      refundsMillimes: 0,
      netMillimes: 0,
      byMethod: {
        cash: { salesMillimes: 0, refundsMillimes: 0, netMillimes: 0 },
        card: { salesMillimes: 0, refundsMillimes: 0, netMillimes: 0 },
      },
      expectedCashMillimes: 20_000,
      countedCashMillimes: null,
      varianceMillimes: null,
      voidsCount: 0,
    });
  });

  it('has a variance only once cash was counted, and a count of zero is a count', () => {
    const input = {
      sessionId: SESSION_ID,
      openingFloatMillimes: mm(20_000),
      documents: [doc('sale', 'cash', 5_000)],
      voidsCount: 0,
    };

    expect(computeZReport({ ...input, countedCashMillimes: null }).varianceMillimes).toBeNull();
    expect(computeZReport({ ...input, countedCashMillimes: mm(25_000) }).varianceMillimes).toBe(0);
    expect(computeZReport({ ...input, countedCashMillimes: mm(0) })).toMatchObject({
      countedCashMillimes: 0,
      varianceMillimes: -25_000,
    });
    expect(computeZReport({ ...input, countedCashMillimes: mm(25_100) }).varianceMillimes).toBe(
      100,
    );
  });

  it('reports refunds as positive amounts, and zero refunds as 0, never -0', () => {
    const report = computeZReport({
      sessionId: SESSION_ID,
      openingFloatMillimes: mm(0),
      documents: [doc('sale', 'card', 4_000), doc('refund', 'cash', -1_500)],
      voidsCount: 0,
      countedCashMillimes: mm(0),
    });

    // toBe compares with Object.is, so these also fail on -0.
    expect(report.refundsMillimes).toBe(1_500);
    expect(report.byMethod.cash.refundsMillimes).toBe(1_500);
    expect(report.byMethod.card.refundsMillimes).toBe(0);
    expect(report.byMethod.cash.salesMillimes).toBe(0);
    expect(report.byMethod.cash.netMillimes).toBe(-1_500);
    expect(report.expectedCashMillimes).toBe(-1_500);
    expect(report.varianceMillimes).toBe(1_500);
  });

  it('never lets card documents change the expected cash', () => {
    const cashOnly = [doc('sale', 'cash', 7_000), doc('refund', 'cash', -2_000)];
    const input = { sessionId: SESSION_ID, openingFloatMillimes: mm(10_000), voidsCount: 1 };
    const withCard = computeZReport({
      ...input,
      documents: [...cashOnly, doc('sale', 'card', 99_000), doc('refund', 'card', -9_000)],
      countedCashMillimes: mm(14_000),
    });

    expect(withCard.expectedCashMillimes).toBe(15_000);
    expect(withCard.varianceMillimes).toBe(-1_000);
    expect(withCard.expectedCashMillimes).toBe(
      computeZReport({ ...input, documents: cashOnly, countedCashMillimes: null })
        .expectedCashMillimes,
    );
  });

  it('matches the SQL formulas over many pseudo-random sessions', () => {
    // 32-bit linear congruential generator (Numerical Recipes constants), fixed seed.
    let state = 20_260_911;
    const below = (bound: number): number => {
      state = (Math.imul(state, 1_664_525) + 1_013_904_223) >>> 0;
      return (state >>> 8) % bound;
    };
    const failures: string[] = [];
    const runs = 1_000;
    for (let run = 0; run < runs; run += 1) {
      const documents = Array.from({ length: below(12) }, () => {
        const method: PaymentMethod = below(2) === 0 ? 'cash' : 'card';
        return below(3) === 0
          ? doc('refund', method, -below(1_000_000))
          : doc('sale', method, below(10_000_000));
      });
      const float = below(4) === 0 ? 0 : below(500_000);
      const counted = below(4) === 0 ? null : below(20_000_000);
      const voids = below(3);

      const report = computeZReport({
        sessionId: SESSION_ID,
        openingFloatMillimes: mm(float),
        documents,
        voidsCount: voids,
        countedCashMillimes: counted === null ? null : mm(counted),
      });
      const expected = sqlZReport(
        { id: SESSION_ID, opening_float_millimes: BigInt(float) },
        toRows(documents),
        voids,
        counted === null ? null : BigInt(counted),
      );
      if (JSON.stringify(report) !== JSON.stringify(keysToCamel(expected))) {
        failures.push(JSON.stringify({ documents, float, counted, report, expected }));
      }
    }
    expect(failures.slice(0, 3), `${failures.length} of ${runs} sessions differ`).toEqual([]);
  });
});

/** Every figure `sameZReport` must compare, as a dotted path into the report. */
const COMPARED_FIGURES = [
  'openingFloatMillimes',
  'salesCount',
  'refundsCount',
  'grossMillimes',
  'refundsMillimes',
  'netMillimes',
  'byMethod.cash.salesMillimes',
  'byMethod.cash.refundsMillimes',
  'byMethod.card.salesMillimes',
  'byMethod.card.refundsMillimes',
  'expectedCashMillimes',
  'countedCashMillimes',
  'varianceMillimes',
  'voidsCount',
];

/** A copy of `report` with the figure at `path` one higher. */
function bumped(report: ZReport, path: string): ZReport {
  const copy = structuredClone(report);
  const keys = path.split('.');
  let target = copy as unknown as Record<string, unknown>;
  for (const key of keys.slice(0, -1)) {
    target = target[key] as Record<string, unknown>;
  }
  const last = keys[keys.length - 1];
  target[last] = (target[last] as number) + 1;
  return copy;
}

describe('sameZReport', () => {
  it('is true for the same figures, whatever the session id', () => {
    const report = mixedReport();

    expect(sameZReport(report, structuredClone(report))).toBe(true);
    expect(sameZReport(report, { ...report, sessionId: 'another-session' })).toBe(true);
  });

  it('is true for the server report read back from snake_case', () => {
    const server = keysToCamel(keysToSnake(mixedReport())) as ZReport;

    expect(sameZReport(mixedReport(), server)).toBe(true);
  });

  it('is true when neither report has a count, and false when only one has', () => {
    const uncounted = { ...mixedReport(), countedCashMillimes: null, varianceMillimes: null };
    const countedZero = {
      ...mixedReport(),
      countedCashMillimes: mm(0),
      varianceMillimes: mm(-64_167),
    };

    expect(sameZReport(uncounted, structuredClone(uncounted))).toBe(true);
    expect(sameZReport(uncounted, countedZero)).toBe(false);
    expect(sameZReport(countedZero, uncounted)).toBe(false);
    expect(sameZReport(countedZero, structuredClone(countedZero))).toBe(true);
    // A missing count never equals a count, even with the same variance.
    expect(sameZReport(uncounted, { ...uncounted, countedCashMillimes: mm(0) })).toBe(false);
    expect(sameZReport({ ...uncounted, varianceMillimes: mm(0) }, uncounted)).toBe(false);
  });

  it.each(COMPARED_FIGURES)('is false when %s differs by one', (path) => {
    const report = mixedReport();

    expect(sameZReport(report, bumped(report, path))).toBe(false);
    expect(sameZReport(bumped(report, path), report)).toBe(false);
  });

  it.each(['byMethod.cash.netMillimes', 'byMethod.card.netMillimes'])(
    'is false when %s differs by one',
    (path) => {
      const report = mixedReport();

      expect(sameZReport(report, bumped(report, path))).toBe(false);
    },
  );
});
