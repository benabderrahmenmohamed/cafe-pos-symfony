# The database's own tests

The rules that matter most live in Postgres, not in PHP: the append-only ledger, gapless receipt
numbers, refunds bounded by what is left on a line, the order records, and row-level security that
keeps one café out of another's rows. These files test them in SQL, with
[pgTAP](https://pgtap.org), against the schema `api/migrations` builds and the café
`php bin/console app:seed-demo` puts in it.

Each file runs inside one transaction and rolls it back, so they leave the database exactly as they
found it and can run on the development database as well as on a throwaway one.

## Running them

They need the pgTAP extension installed in the Postgres server (on Debian and Ubuntu,
`postgresql-17-pgtap`) and `pg_prove` to run them (`libtap-parser-sourcehandler-pgtap-perl`). Each
file creates the extension itself, in a schema of its own, inside its transaction.

```bash
php bin/console doctrine:migrations:migrate
php bin/console app:seed-demo
pg_prove -h 127.0.0.1 -U postgres -d cafe tests/pgtap/*.test.sql
```

CI does exactly this on every push (`.github/workflows/ci.yml`, the Symfony job).

## Where they came from

The café first ran on Supabase, and these tests were written for it; they were ported when the
schema moved to this server. What changed is only how a test acts as a member: Supabase read the
caller from a JWT, this server writes the member on the connection (`app.user_id`), and Supabase's
`authenticated` and `anon` roles are this server's single `cafe_app`.

Comments that name a migration by number (`migration 20260913000014`) mean the Supabase migration
the rule was first written in. Those migrations are what `api/migrations/sql/0001_schema.sql` was
converted from; their history is kept in the `pos-admin-dashboard` repository.

Two of the original files are not here, because what they tested is not part of this schema: the
import of the old app's key-value store, and the nightly reset of a public demo café.
