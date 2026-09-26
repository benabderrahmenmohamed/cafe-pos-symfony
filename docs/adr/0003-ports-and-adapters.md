# 3. The UI reaches a backend only through ports

**Status:** Accepted. Ports and the memory and Supabase adapters landed in Phase 2 (`1758053`); the error
contract and the shared contract suite in Phase 3 (`ecc42fe`); the REST adapter in Phase 5 (`2a9a438`); the
orders and realtime ports with the café model, v3 Phase 3 (`65fc141`); amended for this repository, where the
Supabase adapter is gone and the REST adapter is the café (`71cdd69`).

## Context

The export called Supabase from inside its pages — an edge function over a key-value store, reached with the
project's client. Three things followed from that: a page could not be tested without a network, there was no
way to show the app to anyone without credentials, and there was nowhere to put the Spring Boot service the
project was then meant to move to; the service it got is the Symfony server in `api/` (ADR 0009).

## Decision

**Ports.** `src/ports` holds `AuthPort`, `CatalogPort`, `OrdersPort`, `RealtimePort`, `SalesPort`,
`SessionsPort`, `SettingsPort` and `TerminalsPort`, gathered as `Backend` in `src/ports/index.ts`. Their
types are Zod schemas, so an adapter parses what it returns rather than asserting it.

**One error vocabulary.** Every failure crossing a port is an `AppError` carrying one of the eighteen codes in
`src/lib/errors.ts`, documented in [contracts/errors.md](../../contracts/errors.md). Callers decide from the
code alone, never the message. `errorClass` maps each code to `retriable`, `auth` or `conflict`, which is
exactly what the outbox acts on (ADR 0005).

**Two adapters.**

| Adapter               | What is behind it                                                                                                                       |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `src/adapters/memory` | The reference implementation: the credential-free demo and most tests.                                                                  |
| `src/adapters/rest`   | The HTTP API of [contracts/openapi.yaml](../../contracts/openapi.yaml), served by the Symfony server in `api/` (ADR 0009). The default. |

**Composition root.** `src/lib/backend.ts` is the only module that names an adapter. It reads `backendKind()`
from `VITE_BACKEND` and `await import()`s one, so a build downloads only the backend it runs on.
`src/lib/backend-context.tsx` hands the result to the tree and features reach it through `useBackend`.

**One contract suite for both, and for the server.** `src/ports/__contracts__` exports
`describeBackendContract(makeFixture)`, which runs the auth, catalog, orders, terminals, sessions and sales
suites. Each adapter runs it unchanged — `src/adapters/memory/contract.test.ts`, and
`src/adapters/rest/contract.test.ts` over MSW — and `src/adapters/rest/live.contract.test.ts` runs it against
the Symfony server itself when `CONTRACT_BACKEND=rest`. The fixture signs one backend in per role — admin,
cashier, waiter and kitchen — because what a role may do is part of the contract. The suite builds its records
with the app's own builders (`buildSaleRecord`, `buildRefundRecord`, `buildOpenSessionRecord`, the order
record builders), so it sends the payloads the app actually writes. Its header states the rule: the database
defines the semantics, and each adapter must pass the suite unchanged.

**Lint enforces the arrangement.** `eslint.config.js`:

- Everything under `src/` except `src/adapters/**` and `src/lib/backend.ts` may not import `@/adapters/**`
  or `restEnv` from `@/lib/env`. `no-restricted-syntax` adds what static import rules miss:
  `import()` of an adapter, and `import.meta.glob`.
- `src/app`, `src/components`, `src/features` and `src/routes` have `fetch`, `XMLHttpRequest`, `WebSocket` and
  `EventSource` as restricted globals: screens make no requests of their own.
- The memory adapter may not import the REST one; what adapters share lives in `src/lib` or `src/ports`. The
  one crossing is a test's: `src/adapters/rest/fakeApi.ts` serves the contract over the memory backend, and
  nothing that ships imports it.
- `src/lib/money.ts` and `src/features/caisse/cart.ts` additionally may not import React, the router, TanStack,
  the backend modules or `@/lib/env`, and may not call `new Date()`, `Date.now`, `Math.random`,
  `crypto.randomUUID` or `crypto.getRandomValues`, or touch `localStorage`, `sessionStorage` or `indexedDB`.

### What was revised

**The memory adapter gained real checks.** In Phase 2 it had `authorize(store, ['admin'])`, which read the
role off the signed-in session — enough for a demo to behave plausibly. Phase 3 replaced it with
`requireProfile(context, allowed)` in `src/adapters/memory/support.ts`, which reads role and shop from
`store.profiles` exactly as `private.require_profile()` does, and raises `FORBIDDEN` for an account with no
profile rather than letting it through. `src/adapters/memory/ledger.ts` went further and named its helpers
after the database's: `terminalFor` for `private.lock_terminal`, `requireEpoch`, `requireMember`,
`requireNextSeq`, `sessionView` for `private.session_json`, `zReportOf` for `private.compute_z_report`.

It had to change because the same suite now runs against both: the memory backend has to refuse what the
database refuses, with the same code and the same `details` keys. That is what makes it a reference
implementation instead of a stub.

**The café model added two ports and four codes.** `OrdersPort` carries the room — tables, the grid,
each table's open order, the kitchen's tickets, the removed-after-sent report and the five order writes
(ADR 0007) — and `RealtimePort.subscribe(shopId, listener)` says which kind of row another device changed.
Each adapter answers it its own way: an in-process emitter in the memory backend, and in the REST adapter a
poll of `GET /api/v1/open-orders?since=<cursor>` with backoff; the Supabase adapter had a Realtime channel.
The codes `ORDER_CHANGED`, `ORDER_CLOSED`, `ITEM_NOT_FOUND` and `TABLE_INACTIVE` joined the vocabulary, all
of the conflict class. A behaviour the suite has no case for can still drift apart: a duplicate table name
reached the app from Supabase as a bare constraint violation, `UNKNOWN`, while the memory backend accepted
it. It was found by reading, and fixed the way everything else here is —
`20260913000014_dining_table_names.sql` (now the part of `api/migrations/sql/0001_schema.sql` marked
`-- from` with that name) and the memory backend both answer `VALIDATION_ERROR` on the name,
and the suite now has the case.

**Supabase left, and the REST adapter became the café.** This repository keeps one server, the Symfony one in
`api/` (ADR 0009), which serves the contract the REST adapter was written against; the Supabase version stays,
with all its history, in the pos-admin-dashboard repository. So `src/adapters/supabase` went, with
`@supabase/supabase-js`, its run of the contract suite and its lint rules (`71cdd69`), and `VITE_BACKEND`
defaults to `rest` where it defaulted to `supabase`. The memory adapter stays, for the credential-free public
demo and as the reference the other is held to. The suite still runs three times: against the memory backend,
against the REST adapter over MSW, and against the running server.

## Consequences

- Two implementations of every behaviour, and a server behind one of them. A new port method is two adapters,
  a route in `fakeApi.ts` and in the server, and a case in the suite.
- The credential-free demo and the one-device Playwright spec (`e2e/cafe-memory.spec.ts`) are possible at all,
  because the memory backend is a real backend with faults, connectivity and live updates
  (`createFaultInjector`, `defaultConnectivity`, its realtime emitter).
- Cost: the contract suite is the slowest part of the test run, and two of its three runs need something
  beyond the memory backend — MSW, or the running Symfony server (`CONTRACT_BACKEND=rest`). CI runs the live
  one in its Symfony job, on every push, against a café it has just migrated and seeded.
- Cost: the boundaries are lint, not types. A file with an eslint-disable can still import an adapter.
- `src/adapters/rest/contract.test.ts` proves the REST adapter against `src/adapters/rest/fakeApi.ts` — MSW
  serving the OpenAPI shapes over the memory ledger. As its own test header says, what that proves is the
  adapter and the wire format: paths, bearer token, snake_case out and camelCase in, 201 against 200, and every
  error code read back from the envelope. `live.contract.test.ts` runs the same suite against the running
  server, and proves the server.

## Alternatives rejected

- **Call Supabase from hooks and mock it in tests.** A mock drifts from the database and cannot be run against
  it; a credential-free demo would then be a second mock, drifting separately.
- **One `ApiClient` interface instead of eight ports.** Sales, sessions, the room and the catalog have
  different shapes and different callers. Small ports keep a test fixture small.
- **A folder convention with no lint rules.** A single `import { supabase }` in a component silently undoes the
  arrangement; Phase 2 added the rules for that reason.
- **Generated clients as the port type.** The port types are what the UI wants to work with.
  `src/adapters/rest/api.types.ts` is generated from the OpenAPI document and stays inside the adapter, behind
  `keysToCamel` and a port schema.
