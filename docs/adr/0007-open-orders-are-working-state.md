# 7. Open orders are working state, not the ledger

**Status:** Accepted. Landed with the café model in v3 Phase 3 (`65fc141`); the device's side of it —
order records in the outbox, drawn over the server's reads — in v3 Phase 4 (`5b44149`); table management
and cancelling at the counter in `2e063e1`; the author on every order record after Phase 6; amended for this
repository, where the café's devices hear of a change by polling the server (`71cdd69`).

## Context

The first plan built a counter register: a sale named products directly, and the sale was the only thing a
device wrote. A café takes orders long before anyone pays. Waiters put items on tables from phones, often
with no network; the kitchen needs to know what was sent; items come off; a table pays in parts; the guests at
another table leave and it is cancelled. That state changes all the time and several devices change it at
once. The ledger (ADR 0006) is append-only and numbered (ADR 0004), and nothing a waiter taps should have
to be either. The question was where this state lives and how it meets the ledger.

## Decision

**Two kinds of state, with different rules.** The ledger — `sales`, `sale_lines`, `stock_movements`,
`receipt_voids` — is what happened to money and is never dropped. The room — `dining_tables`,
`open_orders`, `open_order_items` (`20260911000010_cafe_schema.sql`) — is what is on the tables right now.
Orders and their items are stamped as things happen and never deleted, and a table is kept by the foreign
keys once an order or a sale names it; but none of it is a document: nothing about them is numbered, and a
device may give up on a change to them.

**The server opens an order; nobody asks it to.** There is no "open order" record. `order_item_add` names
the table, never an order: the server finds the table's open order or creates it, and the partial unique
index `open_orders_one_open_per_table` makes "the table's open order" one row. Two devices adding to the
same free table cannot race on creating it. An add that arrives after the caisse closed the table opens the
next order with that item, so a waiter's offline tap is never lost; the caisse sees one unpaid item.

**A row's life is its stamps.** `sent_at` (one send is one kitchen ticket), `prepared_at`, `removed_at`
with `removed_by` and a required `removed_reason`, and `paid_sale_id`. `itemStage` in
`src/features/orders/tableOrder.ts` reads the stage off them, and every screen reads it the same way.
Removing keeps the row, because the admin's report of items removed after the kitchen was told
(`removed_after_sent`) is the point: it is how a café catches a waiter who sells a coffee and takes it off
the bill. A cancel stamps every active row removed with the cancel's reason, and is refused
(`ORDER_CHANGED`) once any row of the order is paid.

**An item's id is the id of the record that added it.** `open_order_items.id` is the add record's id, so
a replayed add answers with the item it already created, and the phone shows the item under its final id
the moment the waiter taps.

**Payment is where the room meets the ledger.** A table payment is one `record_sale` whose lines name
`open_order_item_id`. The server checks that each named item is active, unpaid, on the table's open order,
and still matches its product, quantity and unit price — otherwise `ORDER_CHANGED`, the counter reads the
table again and pays again. It stamps the items `paid_sale_id` and closes the order when nothing unpaid is
left, so a table pays in parts. A line that names no item is a counter line on the same bill
(`20260911000013_counter_sales_and_tables.sql`), and a sale with no table pays no item at all.

**Order records replay like ledger records.** Every order RPC takes a client id and a payload hash and
stores its outcome in `order_records`: the same id and hash answer what they answered the first time, a
different hash is `IDEMPOTENCY_CONFLICT`.

**On the device, an order record is queued, drawn, and may be given up on.** Adds, removals, sends,
prepares and cancels go into the device's one queue with its sales (ADR 0005), in the order they were
written. The screens draw that queue over the server's last read (`src/features/orders/overlay.ts`): a
record still on its way as a flagged change, an acked one as the server now holds it until a read made
after the ack replaces it, and a queued table payment by marking its rows "being paid", so a counter with
no network cannot take the same rows' money twice. Unlike a ledger record, an order record the server
refuses — `ORDER_CHANGED`, `ORDER_CLOSED`, `ITEM_NOT_FOUND`, `TABLE_INACTIVE` — can be discarded with a
reason into the device's dead-letter list, because a stale item on a table the caisse already closed must not
stop a waiter's phone for ever.

**Other devices re-read; nothing is patched.** `RealtimePort` tells a screen which kind of row changed —
`dining_tables`, `open_orders`, `open_order_items` or `products` — and the screen marks the queries that
cover it stale (`useRealtimeRefresh`). The memory backend uses an in-process emitter; the REST adapter polls
`GET /api/v1/open-orders?since=<cursor>` every couple of seconds, and the server answers with the names
stamped in `private.shop_changes` since that cursor (`api/migrations/sql/0002_changes.sql`).

### What was revised

**An order record names who did it.** The café model first sent order records without an author, as the
spec's payloads have none, and the server stamped `added_by` and `removed_by` with whoever sent the record. On a
phone passed between waiters that is the wrong person: a removal one waiter queued with no network, sent after
the next one signed in, was reported under the second — in the one report written to catch removals. Every
order record now carries `actorUserId`, the member signed in when it was written (`useOrderWrites`), under the
payload hash, so a replay cannot change whose it is. `private.order_actor` already accepted it: the server
checks that the person belongs to the shop (`FORBIDDEN` otherwise), stamps them where the record stamps a
person, and `order_records.submitted_by` keeps the login that sent it. A record queued before the change names
nobody and is credited to its sender. This is the one place the payloads go beyond the spec
(`OrderRecord.actor_user_id` in `contracts/openapi.yaml`).

**The report shows the login a removal was sent under.** An author the server can only check against the
shop is the device's word, and `order_records` did not say which item a record took off. Migration
`20260913000015_removal_submitted_by.sql` stamps `removal_submitted_by` — the login that sent the removal or
the cancel — on every item it takes off, and `removed_after_sent` returns it as `submitted_by` beside
`removed_by`. The admin's report says "Synced under … login" on a row where the two differ: a phone passed on,
or a record in somebody else's name. An item taken off before the migration has no login recorded, and the
report says nothing about it.

**Other devices hear of a change by asking.** On Supabase a Realtime channel on the four tables pushed the
name of what changed to every screen. This repository has no Supabase (ADR 0009), and the Symfony server
holds no connections, so the café's devices ask it: triggers on the four tables stamp `private.shop_changes`,
and a poll answers the names of what changed since the device's cursor — names, never rows, as before. The
screens did not change: they still re-read what a name covers, so a missed or repeated poll costs a read and
never a wrong screen. The migrations this record names by file are the parts of
`api/migrations/sql/0001_schema.sql` marked `-- from` with those names.

## Consequences

- The ledger holds money and only money. A thousand taps a day stay out of the receipt sequence, and the
  rules that keep receipts gapless never meet an item someone changed their mind about.
- Two waiters can work one table, each offline, and the server applies their records in the order they
  arrive; the first add opens the order.
- Cost: what a device shows of a table is the server's read plus its own queue, and the rules for drawing
  one over the other — `overlayOrder`, `overlayKitchen`, `changedTables` — are the most intricate code in
  the app. They are pure functions with their own tests for that reason.
- Cost: a payment can be refused because the table moved, and a refused payment is a numbered record that
  stops the register's queue until a person acts (ADR 0004). The counter narrows the window: it only charges
  rows the server has read back and that this device is not changing (`holdReason` in
  `src/features/caisse/payment.ts`).
- Cost: a discarded order record is a tap that never happened at the table, and the dead-letter list exists
  only on the device that discarded it.
- Cost: the author of an order record is the device's word. The server checks only that the person it
  names belongs to the shop, as it does for the person on a cash session, so a member who calls the RPCs
  directly can still name a colleague. What they cannot do is hide: the removal carries the login that sent
  it, and the report prints that login beside the colleague's name.
- Order rows accumulate like the ledger: nothing in this repository deletes them, and a café keeps its
  history. The nightly reset that freed the Supabase demo's tables is not in this schema (ADR 0006).

## Alternatives rejected

- **Orders in the ledger, as draft sales.** Every tap would be a numbered document that can never be
  dropped, and one stale add would stop a till's queue.
- **An explicit "open the table" record.** Two waiters opening the same free table offline would create two
  orders, and the server would have to merge them.
- **Delete what is taken off.** A deleted row cannot say who removed it after the kitchen was told, which is
  the one question the report exists to answer.
- **Keep the order on the devices and sync it as a document** (last write wins, or a CRDT). Payment needs
  the server to decide what is owed at the moment money is taken; a merged document cannot refuse a payment
  for a row somebody removed a second earlier.
- **Patch screens from the realtime payload.** A missed or reordered event would leave a wrong screen with
  nothing to correct it. Re-reading costs a request and cannot be wrong.
