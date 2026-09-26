# cafe-pos-symfony

An offline-first point of sale for a Tunisian café, in one React app with four faces: the waiter's phone, the counter, the kitchen screen and the back office.

> **Status:** this started as a Figma Make export — a register screen and an admin dashboard over a key-value store — and is now the café the [spec](docs/spec.md) describes. Waiters keep taking orders and the counter keeps taking money when the network drops: every order and every payment is queued on the device and reaches the server exactly once, in order. Money is exact to the millime, receipts are numbered per terminal without gaps, and the sales ledger is append-only. The server is the Symfony service in [`api/`](api/README.md), over PostgreSQL, and it serves [contracts/openapi.yaml](contracts/openapi.yaml). The UI reaches its backend only through ports, so the same app also runs on an in-browser demo that needs no server at all. The café ran on Supabase first; that version, and its history, is in the `pos-admin-dashboard` repository.

## The four faces

| Face                 | Who opens it        | On                    | What happens there                                                                                                                                                                                                   |
| -------------------- | ------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/serveur` — Salle   | waiters             | a phone, mobile-first | The room as a grid of tables. Open a table, add from the menu with a note for the kitchen, send, take an item off with a reason, mark a dish sold out for the day.                                                   |
| `/kitchen` — Cuisine | the kitchen, admins | a screen at the pass  | One ticket per send, oldest first, live. Mark items prepared; an item taken off after it was sent stays on its ticket as a void, with the reason.                                                                    |
| `/caisse` — Caisse   | cashiers, admins    | a registered terminal | Open and close a cash session with a Z-report. Pay a whole table or the items ticked, discount or offer a line with a reason, take a percentage off, refund, and cancel a table's order while nothing on it is paid. |
| `/admin` — Admin     | admins              | a desktop             | Products and prices, the menu of the day, categories, the room's tables, the report of items removed after they were sent, the receipt footer, and registering this device as a terminal.                            |

A person can hold several roles — the owner is admin and cashier — and switches between their faces from the header. Every face carries the sync chip, which says whether what was done on this device has reached the server and leads to that face's Conflicts screen; only an admin can void a receipt there.

## Screenshots

<table>
  <tr>
    <td width="30%"><img src="docs/screenshots/serveur-room.png" alt="The waiter's phone: the room as a grid of tables, with what each owes and what the kitchen has not been told"></td>
    <td width="30%"><img src="docs/screenshots/serveur-table-offline.png" alt="A table on the waiter's phone with no network: the order taken offline is on the table, flagged Not synced, and the chip says 1 to send"></td>
    <td>
      <strong>The waiter's phone.</strong> The room, and a table whose next order was taken with no network: it is on the table at once, flagged, and goes out when the phone reconnects.
    </td>
  </tr>
</table>

![The kitchen screen: one ticket per send, with a check to mark each item prepared](docs/screenshots/kitchen.png)

![The counter: the room beside the table being paid, with a coffee offered and the reason on the line](docs/screenshots/caisse.png)

![The back office: the café's tables, in service or not, and what each is doing right now](docs/screenshots/admin-tables.png)

## What it does differently

- **Offline-first.** Everything done during service — an item put on a table or taken off, a send, a dish marked prepared, an order cancelled, a payment or a refund, a session opened or closed — is a record written to IndexedDB before any request. One queue per device drains in the order records were written, one at a time, under a Web Lock, retrying without limit and stopping at the first record the server refuses. The screens draw that queue over the server's last read, so a tap shows at once, flagged until it is synced. A record names the person who made it, so a phone passed from one waiter to the next still credits each with their own taps. What the server has taken is cleared from the device after a week. The back office — products, tables, settings — needs the network.
- **Money done right.** Integer millimes everywhere, never a float. A discount on the whole payment is rounded once and shared across its lines by largest remainder, so the lines add up to the total exactly. Receipts are numbered per terminal — `C1-17` is the counter's seventeenth — in the same IndexedDB transaction that queues the sale, and the server accepts only the next number. Sales are never updated or deleted: a refund is a new document, and a receipt that can never be accepted is voided with a reason, not skipped.
- **Backend-swappable.** The screens call hooks, the hooks call eight ports, and one composition root chooses the adapter: `rest`, the café's Symfony server, or `memory`, a backend that lives in the browser tab for the demo and the tests. One contract suite holds them to the same answers, down to the error code: it runs on the memory backend, on the REST adapter over a fake of the API, and, unchanged, against the Symfony service over HTTP.

## Stack

- React 18, TypeScript in strict mode, Vite 6, and a service worker from vite-plugin-pwa that asks before it updates
- Tailwind CSS 4 and [shadcn/ui](https://ui.shadcn.com/) components on Radix UI, lucide-react icons, sonner toasts
- React Router 7, TanStack Query 5 with its cache kept in IndexedDB per user, react-hook-form with Zod 4
- An outbox in IndexedDB, drained under the Web Locks API
- Ports and adapters: an in-memory backend for the demo and the tests, and a REST adapter written against [contracts/openapi.yaml](contracts/openapi.yaml), which asks the server every couple of seconds what has changed
- [`api/`](api/README.md): PHP 8.2+ and Symfony 7.4 with Doctrine DBAL and Doctrine Migrations, LexikJWT, NelmioCors and PHPUnit — the service that answers that contract
- PostgreSQL 17, with row-level security and transactional functions that hold the rules; pgTAP for the database's own tests, run by `pg_prove`
- ESLint (typescript-eslint, react-hooks) and Prettier; Vitest with Testing Library, fake-indexeddb and MSW; Playwright for the end-to-end specs; Lighthouse for accessibility and performance

## Architecture

```mermaid
flowchart LR
  subgraph cafe["The café's devices"]
    serveur["/serveur<br/>waiter's phone"]
    kitchen["/kitchen<br/>screen at the pass"]
    caisse["/caisse<br/>registered terminal"]
    admin["/admin<br/>back office"]
  end

  subgraph app["One React app, in each browser"]
    screens["Screens and hooks<br/>the room drawn from the server's read<br/>and this device's queue"]
    outbox[("Outbox in IndexedDB<br/>one queue per device, under a Web Lock")]
    ports["Eight ports<br/>auth · catalog · orders · realtime<br/>sales · sessions · settings · terminals"]
  end

  subgraph adapters["Adapters, one per build"]
    memory["memory<br/>the demo and the tests"]
    rest["rest<br/>contracts/openapi.yaml"]
  end

  service["Symfony service (api/)<br/>signs members in, carries records to the database"]
  postgres[("Postgres<br/>row-level security, append-only ledger, open orders")]

  cafe --> screens
  screens -->|"writes, before any request"| outbox
  outbox -->|"drains in order, exactly once"| ports
  screens -->|reads| ports
  ports --> memory
  ports --> rest
  rest -->|"HTTP, and a poll every couple of seconds for what changed"| service
  service --> postgres
```

An order taken with no network, and paid at the counter:

```mermaid
sequenceDiagram
  participant W as Waiter's phone
  participant Q as Phone's outbox
  participant S as Server
  participant K as Kitchen screen
  participant C as Counter
  W->>Q: add 2 × Café express, then send (no network)
  Note over W: on the table at once, flagged "Not synced"
  Q--xS: no network: kept, retried with backoff
  Q->>S: back online: order_item_add, then order_send
  S-->>Q: created — a repeat of the same record would answer "replayed"
  K->>S: every couple of seconds: what changed since my cursor?
  S-->>K: open_order_items — a name, no rows
  K->>S: re-reads its tickets, marks the coffees prepared
  C->>S: record_sale C1-17, naming the items it pays
  S-->>C: created — the table closes when nothing is owed
```

## Design decisions

The decisions worth arguing about, each with what it costs and what was rejected, are in [docs/adr](docs/adr):

| ADR                                                          | Decision                                                                 |
| ------------------------------------------------------------ | ------------------------------------------------------------------------ |
| [0001](docs/adr/0001-feature-folders.md)                     | Feature folders, with ports, adapters and a layout per face beside them  |
| [0002](docs/adr/0002-money-in-millimes.md)                   | Money is an integer number of millimes, never a float                    |
| [0003](docs/adr/0003-ports-and-adapters.md)                  | The UI reaches a backend only through ports                              |
| [0004](docs/adr/0004-per-terminal-receipt-sequence.md)       | Receipt numbers are allocated per terminal and stay gapless              |
| [0005](docs/adr/0005-offline-outbox.md)                      | Records are queued on the device before any network call                 |
| [0006](docs/adr/0006-append-only-ledger.md)                  | Sales are never updated or deleted; a refund is a new document           |
| [0007](docs/adr/0007-open-orders-are-working-state.md)       | What is on the tables is working state beside the ledger, not part of it |
| [0008](docs/adr/0008-terminals-are-payment-devices.md)       | A terminal is a device that takes payment, not a person or a role        |
| [0009](docs/adr/0009-the-server-is-symfony-over-postgres.md) | The service behind the REST contract is Symfony over the same schema     |

## Getting started

You need Node.js 22.13+ (22.x), 24.x or 26+.

### Demo, no credentials

```bash
npm install
npm run dev:demo
```

Open http://localhost:5173. The backend lives in the browser and starts empty again on every reload. The demo accounts take the one device in turn, as a small café's tablet is passed round:

1. **Continue as Owner** (admin and cashier), open **Settings** and register this device as terminal `T1`. Log out.
2. **Continue as Waiter**, open a table, add from the menu and **Send** it to the kitchen. Log out.
3. **Continue as Kitchen** and mark what was sent prepared. Log out.
4. **Continue as Cashier**, open a session with an opening float, pay the table, and close the session to see the Z-report.

Switch the browser to offline at any step: taps and payments are kept on the device and go out when the connection is back.

A reload starts the whole device over: the backend, the queue and this device's terminal registration all go, because the demo clears them at boot rather than replay records into a café that no longer exists. Repeat step 1 to register `T1` before paying again.

### The café, on the Symfony server

Needs Docker, or PHP 8.2+ with `pdo_pgsql`, `intl` and `zip`, Composer 2 and PostgreSQL 17. [`api/README.md`](api/README.md) has the whole of it; the short way, with the container, from the repository root:

```bash
VITE_BACKEND=rest VITE_API_BASE_URL=http://localhost:8000 docker compose --profile cafe up --build
```

That is Postgres, the Symfony service on http://localhost:8000 with the schema applied and the demo café seeded on its first start, and the app on http://localhost:8080 pointed at it. A café started this way keeps what it is told until `docker compose --profile cafe down --volumes`.

Without Docker, run the service from `api/`. `api/.env` expects Postgres on `127.0.0.1:5433`, with the user `postgres` (password `postgres`) and a database `cafe`; put any other address in `api/.env.local`, as [`api/README.md`](api/README.md) explains.

```bash
composer install
php bin/console lexik:jwt:generate-keypair     # the keys that sign the tokens
php bin/console doctrine:database:create --connection=admin --if-not-exists   # the database, if it is not there yet
php bin/console doctrine:migrations:migrate    # the schema
php bin/console app:seed-demo                  # the demo café, its members and its menu
php -S 127.0.0.1:8000 -t public                # the server
```

Then, in a second terminal at the repository root, point the app at it. `.env.example` already says `VITE_BACKEND=rest` and `VITE_API_BASE_URL=http://127.0.0.1:8000`:

```bash
cp .env.example .env
npm run dev
```

Open http://localhost:5173. `app:seed-demo` puts in the demo café, Café de la Marsa, with eight tables, two terminals (`C1` at the counter, `S1` in the room) and a dozen things on the menu, and a second shop the isolation tests use. Its members:

| Account                    | Password             | Roles                        |
| -------------------------- | -------------------- | ---------------------------- |
| `owner@demo.local`         | `demo-owner-2026`    | admin and cashier, demo café |
| `admin@demo.local`         | `demo-admin-2026`    | admin, demo café             |
| `cashier@demo.local`       | `demo-cashier-2026`  | cashier, demo café           |
| `waiter@demo.local`        | `demo-waiter-2026`   | waiter, demo café            |
| `kitchen@demo.local`       | `demo-kitchen-2026`  | kitchen, demo café           |
| `other-admin@demo.local`   | `other-admin-2026`   | admin, other shop            |
| `other-cashier@demo.local` | `other-cashier-2026` | cashier, other shop          |
| `other-waiter@demo.local`  | `other-waiter-2026`  | waiter, other shop           |

These accounts exist only in a database `app:seed-demo` has filled. Running it again on the same database writes nothing: the café is already there.

## Environment variables

| Variable            | Required    | Description                                                                                                                                                            |
| ------------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `VITE_BACKEND`      | No          | Backend adapter: `rest` (default), the Symfony server; or `memory`, the backend that lives in the browser tab.                                                         |
| `VITE_API_BASE_URL` | With `rest` | Where the Symfony server is, without the `/api/v1` prefix, for example `http://127.0.0.1:8000`. It serves the API of [contracts/openapi.yaml](contracts/openapi.yaml). |

Vite inlines these values at build time, so a change needs a rebuild. `.env.demo` sets `VITE_BACKEND=memory` for `npm run dev:demo`.

The tests against a running server read these from the environment, never from `.env`:

| Variable           | Description                                                                                                                               |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `CONTRACT_BACKEND` | `rest` runs the port contract suite against the Symfony server at `API_BASE_URL`, beside its runs on the memory backend and the fake API. |
| `E2E_BACKEND`      | `rest` adds the three-device Playwright spec, against the Symfony server at `API_BASE_URL`.                                               |
| `API_BASE_URL`     | Where the Symfony server is for those two, `http://127.0.0.1:8000` unless it is set.                                                      |

## Scripts

| Command                 | What it does                                                                                                                                                                      |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `npm run dev`           | Start the dev server with the backend from `.env`.                                                                                                                                |
| `npm run dev:demo`      | Start the dev server with the in-memory demo backend.                                                                                                                             |
| `npm run build`         | Build for production into `dist/`.                                                                                                                                                |
| `npm run preview`       | Serve the production build locally.                                                                                                                                               |
| `npm run lint`          | Run ESLint (no warnings allowed) and Prettier check.                                                                                                                              |
| `npm run format`        | Format the codebase with Prettier.                                                                                                                                                |
| `npm run typecheck`     | Type-check with `tsc --noEmit`.                                                                                                                                                   |
| `npm test`              | Run the Vitest suite, including the contract suite on the memory backend and on the REST adapter over a fake of the API.                                                          |
| `npm run test:contract` | Run only the contract suite; with `CONTRACT_BACKEND=rest`, against the Symfony server as well.                                                                                    |
| `npm run test:e2e`      | Run the Playwright specs: the café on one device against the in-browser demo, and with `E2E_BACKEND=rest` the waiter, kitchen and counter as three devices on the Symfony server. |
| `npm run api:types`     | Regenerate `src/adapters/rest/api.types.ts` from [contracts/openapi.yaml](contracts/openapi.yaml).                                                                                |

The server's own commands run from `api/`: `php bin/console` for the migrations and the demo café, `php bin/phpunit` for its tests and `php -S` to serve it. [`api/README.md`](api/README.md) lists them.

## Testing

- **Unit, page and contract tests** (Vitest, Testing Library, fake-indexeddb, MSW): the rules of every feature as plain modules — the cart, the payment, the room drawn over the queue, the kitchen tickets, the outbox and its retention — each screen behind the guard the app puts in front of it, on the memory backend the demo runs, and the port contract suite of `src/ports/__contracts__` on the memory backend and on the REST adapter over an MSW fake of the API. With `CONTRACT_BACKEND=rest` the same suite, unchanged, runs against the Symfony service over HTTP.
- **The server's own tests** (PHPUnit, `api/tests`): every endpoint over HTTP against a real Postgres — signing in, the menu, the room, the five order records, the money and the drawer — and, under them, what row-level security shows a member and refuses the role the API connects as.
- **Database tests** (pgTAP, `api/tests/pgtap`, run with `pg_prove` against a migrated and seeded database; each file rolls back): the ledger's immutability and refund limits, the order functions, sales with and without a table, table names, who an order record credits, saving whether a product is on the menu and counted, and malformed payloads answered with `VALIDATION_ERROR`. [`api/tests/pgtap/README.md`](api/tests/pgtap/README.md) explains them.
- **End to end** (Playwright): the café on one device against the demo — an order taken with no network, prepared, paid while the payment's answer is lost, and the drawer closed balanced; an order the server refuses and a waiter discards; a removal still queued when the tablet changes hands, reported under the waiter who made it and the owner's login that synced it; and every target on every screen of the waiter's phone measured at 44 px or more. With `E2E_BACKEND=rest`, the waiter's phone, the kitchen and the counter as three devices against the Symfony server, each screen changing because another device wrote something.
- **Lighthouse** 12.8, on the demo build served compressed, through user flows over twenty-one screens and dialogs of the four faces: accessibility, best practices and SEO 100 on every one; performance 91 on a phone and 100 on a desktop for the first load.

## Database

The schema is the migrations in `api/migrations/`: each `Version*.php` class runs one SQL file in `api/migrations/sql/`, and nothing generates them. `0001_schema.sql` is the baseline — the Supabase migrations the café first ran on, converted once — and is never changed; `0002_changes.sql` records what changed for the screens that poll, `0003_reads.sql` is a single grant, and `0004_malformed_payloads.sql` makes three malformed payloads answer `VALIDATION_ERROR`. A change to the schema is the next migration; [`api/README.md`](api/README.md) says how.

- **Shops and profiles.** An account is a row of `public.users`, its password hashed by the server. Every member belongs to one shop and holds one or more of `admin`, `cashier`, `waiter` and `kitchen`. Row-level security keeps each shop's rows to its own members.
- **Catalog.** Categories and products, archived rather than deleted. `is_available` is the daily sold-out toggle; a product with `track_stock` counts its stock as the sum of append-only `stock_movements`, and most of a café's menu does not.
- **The room.** `dining_tables`, taken out of service but never deleted, names unique within the café. `open_orders`, created by the server when the first item lands on a free table, one open order per table. `open_order_items`, stamped as they are sent, prepared, taken off with a reason, and paid — never deleted. A removal is stamped with the person its record names and, beside them, the login that sent it, and the removed-items report shows both when they differ. `order_records` makes every order write replayable by its id and payload hash.
- **Terminals and cash sessions.** A terminal keeps `last_seq` and a registration `epoch`; a terminal has at most one open session, and a closed session cannot change.
- **Sales ledger.** `sales` and `sale_lines` accept writes only through `record_sale`; nobody can update or delete them — the role the API connects as has no right to, and a trigger refuses the schema's owner as well. A table payment names the order items it pays, and the server refuses it with `ORDER_CHANGED` if one of them was paid, taken off or changed in the meantime. Refunds are rows of kind `refund` that name the sale, with negative lines that each name the line they take back. `receipt_voids` lets an admin give up on a numbered record that can never be accepted, without leaving a gap.
- **What changed.** `private.shop_changes` holds one row per shop and topic — tables, orders, items, products — stamped by a trigger whenever a row of that topic changes. `GET /api/v1/open-orders?since=<cursor>` answers the names stamped since the cursor, and no rows: a screen that hears its topic reads again.

Every function the server calls raises the typed errors of [contracts/errors.md](contracts/errors.md), and the server answers each with that file's HTTP status; the app decides what to do from the code alone. The API's JSON uses snake_case keys, and the REST adapter converts them to the camelCase of the ports.

## Roles

A member's roles and shop come from `public.profiles`, read by the server on every request, never from the token. Nothing in this repository creates an account except `app:seed-demo`: insert a new member's row into `public.users` yourself, with the password hashed the way `api/src/Demo/DemoSeeder.php` hashes it (`password_hash($password, PASSWORD_BCRYPT)`), then add their profile once you have confirmed who owns the account. Run it as the schema's owner, the connection the migrations use (`DATABASE_ADMIN_URL`): the role the API connects as may read profiles but not write them.

```sql
insert into public.profiles (user_id, shop_id, roles, display_name)
select u.id, '<shop-id>', array['waiter'], '<name>' from public.users u where u.id = '<user-id>'
returning user_id;
```

A role change applies to the member's next request; the app shows it after they log out and back in.

## Delivery

### Run it in a container

There are two images: the app's, from the `Dockerfile` at the root, and the server's, from [`api/Dockerfile`](api/Dockerfile).

The app's is a multi-stage build that compiles the app with Node and hands `dist/` to nginx, so the image carries no Node runtime and no source. It listens on 8080 as an unprivileged user and answers `/healthz`.

```bash
docker compose up --build
```

Open http://localhost:8080. Compose publishes to `127.0.0.1:8080` and nothing else: the app needs a secure context for the Web Crypto API, Web Locks and the service worker, and `localhost` is one. To reach it from the café's other devices, put it behind TLS rather than publishing plain HTTP.

The image defaults to the credential-free demo. Vite inlines its configuration at build time, so the café is another image, told where its server is:

```bash
docker build \
  --build-arg VITE_BACKEND=rest \
  --build-arg VITE_API_BASE_URL=https://<where-the-server-is> \
  -t cafe-pos-symfony .
```

Nothing comes from `.env`: `.dockerignore` keeps it out of the build context, along with the host's `node_modules`, which are built for the wrong platform.

The whole café — the app, the Symfony service and its database — is the `cafe` profile of the same file:

```bash
VITE_BACKEND=rest VITE_API_BASE_URL=http://localhost:8000 docker compose --profile cafe up --build
```

In the server's image, Composer installs its dependencies in one stage and Apache serves `public/` in the other, so nothing that installs anything ships. On start it makes a keypair if none is mounted, applies the migrations — retrying while the database is still starting — and seeds the demo café when `SEED_DEMO=1`, which the `cafe` profile sets. Its health check asks for `/api/v1/products` with no token and expects the 401 the contract promises, which needs no database. A café that means it sets its own `APP_SECRET`, `DATABASE_URL`, `DATABASE_ADMIN_URL`, `JWT_PASSPHRASE` and `CORS_ALLOW_ORIGIN` — the origins its app is served from — and mounts its own keys at `/var/www/html/config/jwt`: keys made in the container live and die with it, so every new container — a rebuild, or `down` and `up` again — would sign every device out.

nginx compresses what it serves. `index.html`, `sw.js` and `manifest.webmanifest` go out with `no-cache`, so a release is picked up on the next visit and a browser never holds an old service worker; the manifest goes out as `application/manifest+json`, which nginx does not know by itself. `/assets/` is immutable, because those file names change whenever their contents do. Every other path — `/serveur`, `/caisse`, `/kitchen`, `/admin` and everything under them — falls back to the app shell.

`.github/workflows/ci.yml` runs lint, typecheck, the Vitest suite and a build on every push and pull request, then two jobs side by side. One runs the Playwright spec of the café on one device. The other is the Symfony service: its schema migrated and the demo café seeded into Postgres 17, the pgTAP tests, its own PHPUnit suite, a member signed in over HTTP, the port contract suite and the three-device spec against it, and finally its image built with a database of its own and asked to sign the owner in.

### Deploy it to a static host

`netlify.toml` deploys the public demo to **Netlify**. The build command, the publish directory, the single-page fallback and the same cache and security headers as nginx are all in that one committed file, so nothing about the deployment is hidden in a dashboard. It holds no secrets: the site it builds is the in-browser backend.

The app is static files, so any host that can serve `dist/` works. Whatever you use needs the rules above: compression, the fallback to `index.html`, long caching for `/assets/` only, and revalidation for `index.html` and `sw.js`.

### The two demos

| Demo        | Who can open it                               | What is behind it                                                                            |
| ----------- | --------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Public demo | Anyone, with no credentials                   | The in-memory backend, in the visitor's own browser. Nothing is shared.                      |
| Demo café   | Whoever runs the server, with the demo logins | The Symfony server and a real Postgres, seeded with the demo café. It keeps what it is told. |

The **public demo** is what `VITE_BACKEND=memory` builds, and what the container image and the Netlify site serve by default. Each visitor gets their own backend, starting empty; a reload empties it again. There is no account to create, no server to reach and nothing anyone can break for anyone else.

The **demo café** is the café run yourself, as [Getting started](#getting-started) shows: `php bin/console app:seed-demo` puts it in a fresh database, and the `cafe` profile of compose does so on its first start. There is a login for each role — owner, admin, cashier, waiter, kitchen — so the faces can be opened on different devices at once and the room, the ledger, the Z-reports and the sync behaviour seen against a real database. Because the sales ledger is append-only, nothing in this repository takes a café back to its starting state: a fresh start is a fresh database, which with the container is `docker compose --profile cafe down --volumes`.

## Before and after

Measured against the Figma Make export this started from (`d3cdb2c`, recorded in
[docs/baseline.md](docs/baseline.md)):

|                     | Export                                                   | Now                                                                                                                                        |
| ------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Faces               | a register screen and an admin dashboard                 | four: the waiter's phone, the kitchen screen, the counter and the back office                                                              |
| Direct dependencies | 55                                                       | 18                                                                                                                                         |
| Dev dependencies    | 4                                                        | 22                                                                                                                                         |
| JavaScript          | 634 kB, one chunk                                        | the app's own code 216 kB (62 kB compressed); libraries in five chunks a release leaves cached; each backend in a chunk of its own         |
| Tests               | none                                                     | 1,597 unit, page and contract tests, 70 server tests, 194 database assertions, 2 Playwright specs                                          |
| Lint and types      | neither; `typescript` not installed                      | ESLint with no warnings allowed, `tsc` strict                                                                                              |
| Money               | floats, shown as `$12.50`                                | integer millimes, shown as `12,500 DT`                                                                                                     |
| Recording a sale    | two requests against a key-value store anyone could edit | one request, recorded in one transaction into an append-only ledger, paying exactly the rows of the table it names                         |
| No network          | nothing works                                            | orders, sends, kitchen marks, payments and sessions queued on the device, sent exactly once and in order when it is back                   |
| Lighthouse          | favicon 404, no meta description, no robots.txt          | accessibility, best practices and SEO 100 on twenty-one screens and dialogs of the four faces; performance 91 on a phone, 100 on a desktop |

Two numbers went the other way, on purpose. `node_modules` grew past the export's 188 MB, and dev dependencies from 4 to 22: that is the test and delivery tooling — Vitest, Testing Library, MSW, Playwright — none of which ships to a browser.

## Roadmap

- **ESC/POS printing**, so kitchen tickets and receipts leave on paper.
- **Splitting one item between payers.** Today an item is paid whole.
- **Discarded order records reported to the back office from every device**, rather than listed only where they were discarded (see Known issues).

## Known issues

- **A record the server refuses stops this device's queue.** Later records wait behind it until a person retries it, voids it (a receipt, admin only) or discards it with a reason (an order record) on the Conflicts screen. That is deliberate — nothing may reach the server out of order — but it needs someone to look.
- **A discarded order record is listed only on the device that discarded it.** The dead-letter list is on the Conflicts screen of that phone or tablet; nothing reports it to the back office.

## Credits

UI components come from [shadcn/ui](https://ui.shadcn.com/), used under the [MIT license](https://github.com/shadcn-ui/ui/blob/main/LICENSE.md).
