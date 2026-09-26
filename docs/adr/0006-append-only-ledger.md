# 6. The sales ledger is append-only

**Status:** Accepted. Landed in Phase 3 (`ecc42fe`); the audited demo-reset exception in Phase 5 (`2a9a438`);
tables and order items joined it in v3 Phase 3 (`65fc141`); amended for this repository, where the schema is
the Symfony server's own (`09a85bc`), with one role for requests and no demo reset.

## Context

The export kept its data in a key-value store that an edge function wrote with the service role. Any row could
be overwritten by anything holding that key, and nothing recorded that it had been. A register's value is that
its history is what happened; a table that can be edited has no such value.

## Decision

`public.sales` and `public.sale_lines` are written only by `record_sale`, and are never updated or deleted.
That is enforced in three layers, kept together in the `20260911000008_rls_and_grants.sql` part of
`api/migrations/sql/0001_schema.sql` so they can be reviewed in one place.

1. **Grants.** `cafe_app`, the role every request's queries run as, is revoked from every table, then
   granted `select` back on every table of the café but `users`. The only plain client writes anywhere in
   the schema are `insert (name, color)` and `delete` on `categories`, `update (receipt_footer)` on
   `shop_settings`, and `insert` and `update` of `(name, sort_order, is_active)` and `delete` on
   `dining_tables`, each held to the shop's admins by its policy. Row-level security policies keep each
   shop's rows to its own members. Everything else goes through a `security definer` RPC, and `execute` is
   granted to `cafe_app` on those functions and on no other function in `public` — ten in the first plan,
   nineteen once the café model added the order writes, the menu of the day, stock adjustment, the
   removed-after-sent report and the room's tables.
2. **The role requests run as cannot write the ledger.** On Supabase, `insert`, `update`, `delete` and `truncate` were
   revoked from `service_role`, which bypasses row-level security, on `sales`, `sale_lines`,
   `stock_movements` and `receipt_voids`; it kept `select`, so a leaked service key could read the ledger but
   not rewrite it, where the old edge function's key could. Here that role is `cafe_app` with the other two,
   and the same four privileges are revoked from `public` on those tables: `cafe_app` reads the ledger and
   writes it only through the functions. The owner connection the server keeps — for migrations, the demo
   seed and the one read per request that says which member a token is for
   (`api/src/Security/MemberProvider.php`) — keeps its privileges, and only the triggers below stand in its
   way.
3. **Triggers, for the roles that keep their privileges** — the owner and superusers.
   `private.reject_ledger_change` backs `sales_append_only`, `sale_lines_append_only`,
   `stock_movements_append_only` and `receipt_voids_append_only` (row-level, before update or delete) and a
   `*_no_truncate` statement trigger on each. They raise `FORBIDDEN` (`PT403`) unless the transaction has
   first run `set local pos.ledger_maintenance = 'on'`. The switch grants nothing by itself — the API's role
   has no such privilege to unlock — and it does not stop a superuser, who can disable triggers. It guards
   against mistakes.

**A correction is a new document.** A refund is a `sales` row of kind `refund` with `refunds_sale_id` set,
negative quantities and a negative total, no discount and no change; `sales_kind_shape` and
`sale_lines_shape` enforce that shape at the table. `record_sale` takes
`pg_advisory_xact_lock(refunds_sale_id)` before summing earlier refunds per line, refuses more than is left,
and refuses a refund of a line's last units that does not pay exactly what remains. The original sale is never
touched: `SaleLineView.refundedQty` and `refundedMillimes` are computed from the refunds pointing at it. A
numbered record the server can never accept is voided rather than edited away (ADR 0004).

**Stock moves only through movements.** `products.stock_qty` has exactly one writer, `private.move_stock`,
which inserts a `stock_movements` row in the same call; the movements table is append-only alongside the
ledger. A product's stock is the sum of its deltas, with reasons `opening`, `adjustment`, `sale`, `refund`, and
since the café model only a product with `track_stock` on moves at all — coffee is made to order and not
counted. The product
form sends `stockDelta` — counted minus what was shown when the form opened — not a new total
(`toProductUpdateInput`), so a sale recorded while the form was open is not undone. Stock may go negative: a
sale that happened is never refused for stock. Products are archived (`archived_at`), never deleted, so sale
lines keep pointing at them. Closed sessions are final too, by `cash_sessions_closed_are_final`.

**The one exception was the nightly demo reset, and this schema does not have it.** On Supabase,
`private.reset_demo_shop` (`20260911000009_demo_reset.sql`) refused any shop not listed in
`private.demo_shops`, turned `pos.ledger_maintenance` on transaction-locally, removed the trading history of
the shop's **closed** sessions, deleted `adjustment` movements, recomputed `products.stock` from the movements
that were left, turned the switch off again before returning, and reported what it deleted. It kept open
sessions and everything in them, any sale a kept refund pointed at, and the terminals' `last_seq`, so receipt
numbering never repeated. It ran as the database owner from `pg_cron`;
`supabase/scripts/schedule_demo_reset.sql` scheduled it at 03:00 UTC and said it belonged on a demo project
only. `0001_schema.sql` left the function and `private.demo_shops` behind (ADR 0009). The triggers and their
switch are unchanged, and nothing in this repository turns the switch on apart from the one migration step
described below and `api/tests/pgtap/01_ledger.test.sql`, which turns it on inside a transaction it rolls
back, to show the owner can then change a row.

**It is tested from both sides.** `api/tests/pgtap/01_ledger.test.sql` asserts a cashier cannot update or
delete sales or sale lines or write stock directly, and that the owner is refused too — an update, a delete, a
truncate — until the transaction turns `pos.ledger_maintenance` on, and again once it is off.
`api/tests/Database/RowLevelSecurityTest.php` (`testTheRoleTheApiConnectsAsCannotWriteTheLedger`) checks that
`cafe_app` holds no `insert`, `update`, `delete` or `truncate` on any of the four ledger tables, and keeps
`select`.

### What was revised

**The café model tied the ledger to the room without loosening it.** A sale may name the table it paid
(`sales.table_id`), and a line the order item it paid (`sale_lines.open_order_item_id`, unique, so an item
is paid once); the item points back with `paid_sale_id` (ADR 0007). A line gained an id of its own, and a
refund line points at the line it refunds by that id instead of by line number.

That last change needed the switch once more, in a migration rather than at run time:
`20260911000010_cafe_schema.sql` turns `pos.ledger_maintenance` on for one `update`, which points every
refund line written before the café model at the line it refunds, turns it off again, and only then drops the
old line-number column. It changes no amount and no count, and every earlier receipt reads back as it did.

The nightly reset learned about tables (`20260911000012_demo_reset_orders.sql`): it freed the demo café's
tables of what was left on them, and kept an order item together with its order whenever a sale the reset
kept paid for it, because that item is part of the document.

**On the Symfony server requests run as one role, and the demo needs no reset.** This repository's schema is
Supabase's converted once (`api/migrations/sql/0001_schema.sql`, ADR 0009), and the migrations this record
names by file are the parts of it marked `-- from` with their names, except `20260911000009_demo_reset.sql`
and `20260911000012_demo_reset_orders.sql`, which were left behind. Supabase's three API roles became
`cafe_app`, so the first two layers are one role's grants, and the ledger privileges the service role lost
are revoked from `public`. The nightly reset and `private.demo_shops` belonged to the hosted Supabase demo and
were left behind: the public demo here is the in-browser backend, whose data lives in the visitor's tab and
starts again from its seed on every reload, so there is no demo café in the database to reset. The tests came
across with the schema (`09a85bc`); in `01_ledger.test.sql` the service role's four checks were
dropped, because the owner's checks that already followed them prove the stronger claim. The Supabase adapter's `security.test.ts` and the pgTAP file for the reset stay
in the pos-admin-dashboard repository with what they tested.

## Consequences

- The history is what happened. A wrong sale is corrected by a refund, and a record that can never be accepted
  by a void row carrying the payload, the error code, a reason and who wrote it.
- Cost: rows only accumulate. Nothing prunes `sales`, `sale_lines` or `stock_movements`, and there is no
  retention or archival scheme. A busy shop's ledger grows without bound.
- Cost: the escape hatch outlived the reset it was kept for. `pos.ledger_maintenance` is a setting, not a
  privilege: a session of the owner that turns it on can rewrite the ledger. Nothing in this repository does,
  apart from the one migration step above and `01_ledger.test.sql`, which turns it on inside a transaction
  it rolls back and checks the owner is refused without it.
- Every write path is a `security definer` RPC, so the API surface is those functions and the checks inside
  them. The order of the checks becomes part of the contract
  ([contracts/errors.md](../../contracts/errors.md), "Order of checks").
- Reading what is left of a line means summing the refunds that point at it on every read — `refundedOf` in
  the memory adapter, a join in the server's sale read (`api/src/Controller/LedgerController.php`).
- A hosted Supabase project that still runs the original edge function keeps its service-role access until
  the function is deleted; nothing in this repository reaches it. Step 7 of `docs/runbooks/kv-import.md`, kept
  in the pos-admin-dashboard repository, deletes it.

## Alternatives rejected

- **Update a sale in place, or soft-delete it with a `voided` flag.** A row that can be updated will be updated
  wrongly, and a flag does not record what the row used to say.
- **Audit triggers writing to a shadow table.** The shadow table is only as trustworthy as the privilege that
  writes it. Refusing the write is cheaper than reconstructing the truth from an audit log later.
- **Row-level security alone.** RLS does not apply to the table owner and is bypassed by Supabase's service
  role — which is precisely what the old edge function held. Grants plus triggers cover both.
- **Reset the demo shop with the service role.** It deliberately had no such privilege. The reset was a function
  the owner ran on a shop that had been listed for it.
- **Reset the demo shop completely, catalog and terminals included.** Lowering `last_seq` would make a register
  hand out receipt numbers it has already used.
