# api — the Symfony server

The café's backend, written against [`../contracts/openapi.yaml`](../contracts/openapi.yaml): the
same 28 paths — 35 operations — the REST adapter of the app already calls, all of them served. The
screens stay as they are — they are the part that keeps working with no network — and this server
took the place behind them that Supabase held when the café first ran.

## What it needs

- PHP 8.2 or newer with `pdo_pgsql`, `intl` and `zip` — what `Dockerfile` installs and CI enables;
  the rest of what `composer.json` asks for is in any stock build
- Composer 2
- PostgreSQL 17

## How this machine is set up

Docker does not start here, so PostgreSQL runs from the binaries EnterpriseDB publishes, with no
installer and no Windows service:

| Thing | Where |
| --- | --- |
| PHP | `C:\xampp\php` (the extensions above were switched on in `php.ini`; the old file is kept as `php.ini.bak-20260925`) |
| Postgres programs | `C:\Users\shini\pgsql\bin` |
| Its data | `C:\Users\shini\pgdata` |
| Address | `127.0.0.1:5433`, user `postgres`, password `postgres` |
| Databases | `cafe` for development, `cafe_test` for the tests |
| Key generation | XAMPP's OpenSSL needs its config named: `OPENSSL_CONF=C:/xampp/php/extras/openssl/openssl.cnf` before `lexik:jwt:generate-keypair` |

Start and stop the database:

```bash
C:/Users/shini/pgsql/bin/pg_ctl.exe -D C:/Users/shini/pgdata -o "-p 5433" -l C:/Users/shini/pgdata/server.log start
C:/Users/shini/pgsql/bin/pg_ctl.exe -D C:/Users/shini/pgdata stop
```

## Commands

```bash
composer install
php bin/console lexik:jwt:generate-keypair                                  # the keys that sign the tokens
php bin/console doctrine:database:create --connection=admin --if-not-exists # the database
php bin/console doctrine:migrations:migrate                                 # the schema
php bin/console app:seed-demo                                               # the demo café, its members and its menu
php bin/console doctrine:database:create --connection=admin --if-not-exists --env=test  # the tests' own
php bin/phpunit                                                             # the tests
php -S 127.0.0.1:8000 -t public                                             # the server
```

The tests fill their own database with the schema and the café themselves; they need it to exist.

## Two roles, on purpose

| Connection | Role | For |
| --- | --- | --- |
| `default` (`DATABASE_URL`) | `cafe_app` | every request; row-level security applies to it |
| `admin` (`DATABASE_ADMIN_URL`) | the owner | migrations, fixtures, and one read per request: which member it is for |

A request tells the database who it is for with `set_config('app.user_id', …)`, and the policies do
the rest: a member reads their own café and no other, and nobody writes the ledger by hand — not even
this API, which records a sale by calling `record_sale`. `tests/Database/RowLevelSecurityTest.php`
holds those promises down.

The exception is worth naming, because it is the one place where row-level security does not apply to
a request. A connection that has not said who it is for sees no profile at all, and at sign-in nobody
has — so `src/Security/MemberProvider.php` reads the member over the owner's connection, by e-mail
when they sign in and by id when a token brings them back. It reads that one row and nothing else, by
an identity and never by anything else a request carries; everything the request then does runs as
`cafe_app`, under the policies.

## Where the schema comes from

The schema is the migrations in `migrations/`, each a Doctrine class that runs one SQL file in
`migrations/sql/`. They are the source: nothing generates them, and a change to the schema is the
next one.

`0001_schema.sql` is where it started. The café ran on Supabase first, and that file is its sixteen
migrations of the day converted once, with three substitutions: `auth.users` became `public.users`,
`auth.uid()` became `private.current_user_id()` reading `app.user_id`, and Supabase's three API roles
became the single `cafe_app`. The key-value import of the old app, the nightly demo reset and the
Realtime publication were left behind. The originals, and the script that converted them, are in the
history of the `pos-admin-dashboard` repository.

That file is history. Doctrine has run it on every database this server has had and will never run
it again, so a statement added to it would reach a fresh database and no other — which is why the
last fix written for Supabase, `0004_malformed_payloads.sql`, is a migration of its own. To change the
schema, add the next `migrations/sql/000N_*.sql`, a `VersionYYYYMMDDNNNNNN` class that runs it, and its
line in `tests/Support/CafeSchema.php`; if the change is to a rule, add a pgTAP test for it in
`tests/pgtap/`.

Two migrations are this server's own. `0002_changes.sql` is the one thing Supabase provided that a
PHP server cannot — see below — and `0003_reads.sql` is a single grant, so that the sessions this
server lists and the sessions its functions answer with are shaped by the same code.

`DATABASE_URL` lives in `.env` for local work. In the test environment `config/packages/doctrine.yaml`
adds `_test` to the database's name, so the tests run on `cafe_test`, which the tests
are free to empty.

Anywhere else, put it in `.env.local` rather than in the environment. Symfony reads its configuration
from `$_ENV` and `$_SERVER`, never from `getenv()`, and not every SAPI fills those from the process
environment: PHP's built-in server fills neither, so a server started with `DATABASE_URL` exported
uses the one in `.env` and says nothing about it. `.env.local` is read the same way by all of them,
which is why CI writes one and why the container's entrypoint writes what it was told into one. A
test run needs `.env.test.local` as well, because Symfony ignores `.env.local` in the test
environment on purpose: a developer's local overrides must not change what the tests do.

## Live screens, without a live connection

When the café ran on Supabase, its Realtime pushed the names of the tables that changed down a
websocket. This server holds no connections, so the app's REST client polls
`GET /api/v1/open-orders?since=<cursor>` every couple of seconds for the same four names — which is
what `contracts/openapi.yaml` has always said that endpoint is.

`private.shop_changes` is one row per café and topic, stamped by a trigger whenever a row of that
topic changes, and the poll answers the names whose stamp is newer than the cursor. It carries no
rows, and the app took none from Supabase's pushes either: a screen that hears its topic reads again, so a missed
poll or a repeated one costs a read and never a wrong screen. The stamp is `clock_timestamp()`, not
`now()`, because two writes in one transaction must not share a moment, and the cursor is read
before the changes, never after, so a change landing between the two is answered twice rather than
never.

## Timestamps

Every timestamp leaves as `2026-09-25T14:03:11.250Z`: UTC, `Z`, three digits of a second — the form
every client of this contract already writes, and compares against, to the letter. Postgres writes
the same moment as `2026-09-25T14:03:11.25+00:00`, so `src/Api/WireTimestamps.php` re-renders them on
the way out, in one place, and `App\Db\Cafe` sets the connection to UTC so that place only ever has
one spelling to fix. No query has to remember, which matters because the reads shape their JSON in
the database and the record functions were written for Supabase.

## In a container

```bash
# From the repository root: Postgres, this service on :8000, the app on :8080 pointed at it.
VITE_BACKEND=rest VITE_API_BASE_URL=http://localhost:8000 docker compose --profile cafe up --build
```

`Dockerfile` installs the dependencies with Composer in one stage and serves `public/` with Apache in the
other, so nothing that installs anything ships. The entrypoint makes a keypair if none is mounted, applies
the migrations - retrying while the database is still starting - and seeds the demo café when `SEED_DEMO=1`.

A café that means it sets its own `APP_SECRET`, `DATABASE_URL`, `DATABASE_ADMIN_URL`, `JWT_PASSPHRASE` and
`CORS_ALLOW_ORIGIN`, and mounts its own keys at `/var/www/html/config/jwt`: keys made inside the container
live and die with it, so every new container would sign every device out and two replicas would reject each
other's tokens. `MIGRATE_ON_START=0` leaves the schema to whoever deploys it.

## How the app reaches it

```bash
VITE_BACKEND=rest VITE_API_BASE_URL=http://127.0.0.1:8000 npm run dev
```

Nothing in the screens changes: the app reaches every backend through the same ports, and this one
answers the REST contract. `rest` is the app's default backend and `.env.example` holds both lines,
so with an `.env` copied from it, `npm run dev` alone does the same.

## What holds it to the contract

`php bin/phpunit` is this server's own suite: the endpoints over HTTP, and the policies under them.
It proves the server against the contract as this repo reads it.

The rules that matter most live in Postgres rather than in PHP — the append-only ledger, gapless
receipt numbers, refunds bounded by what is left on a line, the order records, and the row-level
security that keeps one café out of another's rows — and `tests/pgtap` tests them in SQL, with
pgTAP and `pg_prove`, against the migrated and seeded café. They were written when the café ran on
Supabase and came here with the schema; [`tests/pgtap/README.md`](tests/pgtap/README.md) says what
they need and how to run them. They talk to Postgres alone, not to this server, and each file rolls
back what it did, so they leave the database as they found it.

Two suites that already existed prove it against the app that has to use it, and neither was written
for it: the port contract suite, the same one the in-browser backend passes, and the three-device
spec, written when the café ran on Supabase. Both run unchanged:

```bash
# From the repository root: the port contract suite, 61 tests, against the server at API_BASE_URL.
CONTRACT_BACKEND=rest API_BASE_URL=http://127.0.0.1:8000 npx vitest run live.contract

# The waiter's phone, the kitchen screen and the counter, in three browsers at once.
E2E_BACKEND=rest API_BASE_URL=http://127.0.0.1:8000 npx playwright test --project=rest
```

Both need the server running (`php -S 127.0.0.1:8000 -t public`) against a database that has been
migrated and seeded. On Windows, PowerShell sets those variables with `$env:NAME='value';` first.

They leave their tables, sessions and sales in the database, as a café does: every run takes a table
and a terminal code of its own, so nothing has to be reset between them.

CI runs all four, in the `symfony` job of `.github/workflows/ci.yml`.
