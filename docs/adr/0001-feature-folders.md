# 1. Feature folders over the generated page-and-context layout

**Status:** Accepted. Landed in Phase 2 (`1758053`, "structure, ports and adapters, integer money").

## Context

The Figma Make export (`d3cdb2c`, measured in [docs/baseline.md](../baseline.md)) put a screen in one file
under `src/app/pages/`: `POS.tsx` was 648 lines and 21.9 KB, `Products.tsx` 424, `Categories.tsx` 266,
`Settings.tsx` 252, `Login.tsx` 171. `src/app/contexts/AuthContext.tsx` (139 lines) held the session, the
role and the calls that fetched data. `src/app/routes.tsx` wired them together.

Each page fetched its own data, did its own money arithmetic in floats, and built its own dialogs. Of 65
files under `src/`, 37 were unreachable from `src/main.tsx`. There were no tests, no `tsconfig.json` and no
ESLint, so nothing said what belonged where. A file that size has no seam to test through: to check that a
cart adds up, you had to render the POS screen and a backend with it.

## Decision

Group by feature, and keep the parts of a feature that need no DOM out of its components.

```
src/features/<feature>/
  components/   React: screens, dialogs, cards
  hooks/        TanStack Query hooks and other React state
  types.ts      the port types this feature uses
  *.ts          the feature's rules: plain modules, no React
src/ports/      the interfaces the UI may call (ADR 0003)
src/adapters/   the implementations: memory, rest
src/lib/        cross-feature helpers: money, errors, payloadHash, env, query, backend
src/routes/     appRoutes.tsx, ProtectedRoute, a layout per face
src/components/ui/  shared shadcn/ui components
```

The sixteen features are `admin`, `auth`, `caisse`, `categories`, `dashboard`, `kitchen`, `menu`, `orders`,
`pos`, `products`, `sales`, `serveur`, `sessions`, `settings`, `sync` and `terminal`. The rules of a feature
sit at its root as ordinary modules and are unit-tested directly: `src/features/caisse/cart.ts` and
`payment.ts`, `src/features/orders/overlay.ts`, `tableOrder.ts` and `board.ts`, `src/features/pos/gate.ts`,
`queue.ts` and `recording.ts`, `src/features/sales/records.ts`, `src/features/sessions/zReport.ts`,
`src/features/sync/outbox.ts` and `retention.ts`. Each one says in its header that it runs without a DOM.

Routing stays out of the features: `src/routes/appRoutes.tsx` composes the four faces — `/admin`,
`/caisse`, `/serveur`, `/kitchen` — and wraps each in `ProtectedRoute` with the roles that
`FACES` in `src/features/auth/roles.ts` allows it.

### What was revised

**The café model added six features and turned two layouts into four faces.** `orders` holds the room — what
is on each table, drawn over the server's read (ADR 0007); `caisse`, `serveur` and `kitchen` are three of
the four faces; `menu` is the menu of the day both the back office and the waiter's phone draw; `admin`
holds the back office's café screens. The two layouts became one per face. The register's cart moved from
`pos` to `caisse`, where the spec puts it, and its old path was deleted once nothing imported it; `pos`
kept what every till shares — the queue's view of a register, the gate, the wording of a record's state.

## Consequences

- A screen's rules are testable without rendering it. `cart.test.ts`, `payment.test.ts`, `overlay.test.ts`,
  `gate.test.ts`, `queue.test.ts`, `zReport.test.ts` and `outbox.test.ts` run in the node environment.
- The export's one POS file is now spread across `caisse`, `pos`, `sales` and `sessions`. That is more files
  to open and more imports to follow, and the cost is real for a small change.
- Features import each other: `src/features/pos/queue.ts` pulls from `@/features/sessions/zReport` and
  `@/features/sync/types`. Nothing enforces a dependency direction between features — the only boundaries
  ESLint checks are ports/adapters and the purity of `src/lib/money.ts` and `src/features/caisse/cart.ts`
  (ADR 0003). Feature coupling is a review question, not a build error.
- `src/features/*/types.ts` is mostly a re-export of port types. It is a second thin layer to keep in step
  with `src/ports`.
- `src/components/ui` stays global, so a feature folder is not self-contained: it owns its screens, not the
  buttons in them.

## Alternatives rejected

- **Keep pages and contexts.** The export's own shape is what made it untestable: `AuthContext` mixed session,
  role and data access, `POS.tsx` did cart arithmetic and reached the backend, and there was nowhere to put a
  second backend. Phases 3 to 5 each added a concern (a ledger, a queue, a third adapter) that would have
  landed inside those same files.
- **Layer folders (`components/`, `hooks/`, `pages/`, `services/`).** A change to selling would touch four
  folders, and nothing in the tree says which files belong to one another.
- **A package per feature, in an npm workspace.** One app, one build, one deployment. The tooling would buy
  nothing today, and the boundaries it enforces are already enforced by lint where they matter.
- **Feature folders with no ports layer.** Rejected for the reasons in ADR 0003: without ports there is no
  credential-free demo, no contract suite and no place for a second backend.
