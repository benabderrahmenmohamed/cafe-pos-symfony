-- The café model, against the demo café: tables, open orders as working state, the
-- kitchen, and payment against order items. This is the Phase 3 list of docs/spec.md — shop
-- isolation, role limits, ledger immutability, lazy order creation under two devices, partial
-- payment, a late add after payment, ORDER_CHANGED on a stale line, replay, SEQUENCE_GAP, a second
-- session open and refund limits — plus the contract of the five order RPCs themselves.
--
-- Every payload here uses the café key names (open_order_item_id, allocated_discount_millimes,
-- net_millimes, cart_discount_millimes, refunds_sale_line_id). 01_ledger.test.sql pays with the
-- names the app used before, which is how both halves of the wire contract stay covered.
begin;

create schema if not exists extensions;
create extension if not exists pgtap with schema extensions;
-- pgTAP is called by name, and part of each file calls it as the API's own role.
set local search_path = public, extensions;
grant usage on schema extensions to cafe_app;

select plan(54);

create schema test_helpers;
grant usage on schema test_helpers to cafe_app;

create function test_helpers.login(p_user uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('app.user_id', p_user::text, true);
  perform set_config('role', 'cafe_app', true);
end;
$$;

-- The error an SQL statement raises, as { code, message, detail }, or null if it succeeds.
create function test_helpers.error_of(p_sql text)
returns jsonb
language plpgsql
as $$
declare
  v_detail text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return jsonb_build_object('code', sqlstate, 'message', sqlerrm, 'detail', case when v_detail ~ '^\s*\{' then v_detail::jsonb end);
end;
$$;

-- A payload hash is 64 lowercase hex digits; which digits they are is the client's business.
create function test_helpers.hash(p_seed text)
returns text
language sql
immutable
as $$ select md5(p_seed) || md5('salt' || p_seed) $$;

-- An add exactly as src/ports/orders.ts writes it. The item takes the record's own id, so the
-- caller knows what it created without reading anything back.
create function test_helpers.add(p_id uuid, p_table uuid, p_product uuid, p_qty integer, p_device text, p_note text default '')
returns jsonb
language sql
as $$
  select public.order_item_add(jsonb_build_object(
    'id', p_id, 'table_id', p_table, 'product_id', p_product, 'qty', p_qty, 'note', p_note,
    'device_id', p_device, 'added_at', '2026-09-12T12:00:00Z', 'payload_hash', test_helpers.hash(p_id::text)
  ))
$$;

-- Paying a set of items, the way the caisse builds it: one line per item, at the quantity and the
-- price the waiter put on the table. subtotal_millimes is left out on purpose — it is derived, and
-- a payload that does not state it is still a valid one.
-- p_line_discount and p_reason are the "offert" case: a discount on a line, with the reason the
-- cashier gave for it, applied to every line of the payment.
create function test_helpers.pay(
  p_id uuid, p_seq bigint, p_session uuid, p_table uuid, p_items uuid[],
  p_method text default 'cash', p_hash text default null,
  p_line_discount bigint default 0, p_reason text default null
)
returns jsonb
language sql
security definer
as $$
  with lines as (
    select row_number() over (order by array_position(p_items, i.id)) as line_no, i.*
    from public.open_order_items i
    where i.id = any (p_items)
  )
  select jsonb_build_object(
    'id', p_id, 'kind', 'sale', 'terminal_code', 'C1', 'epoch', 0, 'seq', p_seq,
    'session_id', p_session, 'table_id', p_table,
    'created_at', '2026-09-12T13:00:00Z', 'payload_hash', coalesce(p_hash, test_helpers.hash(p_id::text)),
    'lines', (
      select jsonb_agg(
        jsonb_build_object(
          'line_no', l.line_no, 'open_order_item_id', l.id, 'product_id', l.product_id,
          'product_name', l.name_snapshot, 'qty', l.qty, 'unit_price_millimes', l.unit_price_millimes,
          'line_discount_millimes', p_line_discount, 'line_discount_reason', p_reason,
          'allocated_discount_millimes', 0,
          'net_millimes', l.qty * l.unit_price_millimes - p_line_discount
        )
        order by l.line_no
      )
      from lines l
    ),
    'cart_discount_millimes', 0,
    'total_millimes', (select sum(l.qty * l.unit_price_millimes - p_line_discount) from lines l),
    'payment', jsonb_build_object(
      'method', p_method,
      'tendered_millimes', (select sum(l.qty * l.unit_price_millimes - p_line_discount) from lines l),
      'change_millimes', 0
    )
  )
$$;

-- A refund of p_qty units of one line of p_sale, paying p_amount, pointing at the line by its id.
create function test_helpers.refund(
  p_id uuid, p_seq bigint, p_session uuid, p_sale uuid, p_line_no integer, p_qty integer, p_amount bigint
)
returns jsonb
language sql
security definer
as $$
  select jsonb_build_object(
    'id', p_id, 'kind', 'refund', 'terminal_code', 'C1', 'epoch', 0, 'seq', p_seq,
    'session_id', p_session, 'created_at', '2026-09-12T15:30:00Z', 'payload_hash', test_helpers.hash(p_id::text),
    'refunds_sale_id', p_sale,
    'lines', jsonb_build_array(jsonb_build_object(
      'line_no', 1, 'refunds_sale_line_id', l.id, 'product_id', l.product_id, 'product_name', l.product_name,
      'qty', -p_qty, 'unit_price_millimes', l.unit_price_millimes, 'line_discount_millimes', 0,
      'allocated_discount_millimes', 0, 'net_millimes', -p_amount)),
    'cart_discount_millimes', 0, 'total_millimes', -p_amount,
    'payment', jsonb_build_object('method', 'cash', 'tendered_millimes', -p_amount, 'change_millimes', 0))
  from public.sale_lines l
  where l.sale_id = p_sale and l.line_no = p_line_no
$$;

grant execute on all functions in schema test_helpers to cafe_app;

-- Seed ids
--   shop A 11111111-1111-4111-8111-111111111111, shop B 22222222-2222-4222-8222-222222222222
--   admin aaa…1, cashier aaa…2, waiter aaa…3, kitchen aaa…4, owner (admin + cashier) aaa…5
--   terminals C1 (33333333-…-333331) and S1, both at epoch 0
--   tables dddddddd-dddd-4ddd-8ddd-dddddddddd01 … 08, and …b1 in shop B
--   Express 55555555-…-555505 (1200, untracked), Eau minérale 50 cl 55555555-…-555501 (850, tracked)

-- ---------------------------------------------------------------------------------------------
-- Shop isolation
select test_helpers.login('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2');
select is(
  (select count(*)::integer from public.dining_tables),
  1,
  'a member of another shop sees only its own table'
);
select is(
  test_helpers.error_of($$ select test_helpers.add('cccccccc-cccc-4ccc-8ccc-cccccccccc01',
    'dddddddd-dddd-4ddd-8ddd-dddddddddd01', '66666666-6666-4666-8666-666666666601', 1, 'other-phone') $$),
  jsonb_build_object('code', 'PT403', 'message', 'FORBIDDEN',
    'detail', jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01')),
  'adding to a table of another shop is FORBIDDEN naming the table'
);

-- ---------------------------------------------------------------------------------------------
-- Roles. A waiter carries no register, the kitchen touches nobody's table, and the owner is two
-- roles at once.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5');
select is(
  public.my_profile() -> 'roles',
  '["admin", "cashier"]'::jsonb,
  'the owner holds admin and cashier at once'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select public.open_session(jsonb_build_object(
  'id', '77777777-7777-4777-8777-777777777701', 'terminal_code', 'C1', 'epoch', 0,
  'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'opened_at', '2026-09-12T08:00:00Z',
  'opening_float_millimes', 50000, 'payload_hash', test_helpers.hash('open-1')
));

select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select throws_ok(
  $$ select public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888801', 1,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01', array[]::uuid[])) $$,
  'PT403', 'FORBIDDEN', 'a waiter cannot record a sale'
);
select throws_ok(
  $$ select public.order_cancel(jsonb_build_object('id', 'cccccccc-cccc-4ccc-8ccc-cccccccccc02',
    'table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01', 'reason', 'Partis sans payer',
    'created_at', '2026-09-12T12:00:00Z', 'payload_hash', test_helpers.hash('cancel-forbidden'))) $$,
  'PT403', 'FORBIDDEN', 'a waiter cannot cancel an order'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4');
select throws_ok(
  $$ select test_helpers.add('cccccccc-cccc-4ccc-8ccc-cccccccccc03',
    'dddddddd-dddd-4ddd-8ddd-dddddddddd01', '55555555-5555-4555-8555-555555555505', 1, 'kitchen-screen') $$,
  'PT403', 'FORBIDDEN', 'the kitchen cannot put an item on a table'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select throws_ok(
  $$ select public.adjust_stock(jsonb_build_object('id', 'cccccccc-cccc-4ccc-8ccc-cccccccccc04',
    'product_id', '55555555-5555-4555-8555-555555555501', 'qty_delta', 5, 'reason', 'Livraison',
    'created_at', '2026-09-12T12:00:00Z', 'payload_hash', test_helpers.hash('adjust-forbidden'))) $$,
  'PT403', 'FORBIDDEN', 'a cashier cannot adjust stock'
);

-- ---------------------------------------------------------------------------------------------
-- Two devices, one free table: the order is created by the server, so they cannot race on it.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select is(
  (test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
     '55555555-5555-4555-8555-555555555505', 2, 'phone-1') ->> 'order_id')
  = (test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
     '55555555-5555-4555-8555-555555555501', 1, 'phone-2') ->> 'order_id'),
  true,
  'two devices adding to the same free table land on one order'
);
select is(
  (select jsonb_build_object(
     'items', count(*),
     'names', array_agg(i.name_snapshot order by i.name_snapshot),
     'prices', array_agg(i.unit_price_millimes order by i.name_snapshot))
   from public.open_order_items i
   join public.open_orders o on o.id = i.order_id
   where o.table_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd01' and o.status = 'open'),
  jsonb_build_object('items', 2, 'names', jsonb_build_array('Eau minérale 50 cl', 'Express'),
    'prices', jsonb_build_array(850, 1200)),
  'both items are on that order, each with the name and the price it was added at'
);
select is(
  test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    '55555555-5555-4555-8555-555555555505', 2, 'phone-1') ->> 'status',
  'replayed',
  'the same add twice is stored once and replays its answer'
);
select is(
  test_helpers.error_of($$ select public.order_item_add(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    'product_id', '55555555-5555-4555-8555-555555555505', 'qty', 9, 'note', '', 'device_id', 'phone-1',
    'added_at', '2026-09-12T12:00:00Z', 'payload_hash', test_helpers.hash('another-payload'))) $$),
  jsonb_build_object('code', 'PT409', 'message', 'IDEMPOTENCY_CONFLICT',
    'detail', jsonb_build_object('id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01')),
  'the same record id with another payload is IDEMPOTENCY_CONFLICT'
);
select is(
  test_helpers.error_of($$ select test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03',
    'dddddddd-dddd-4ddd-8ddd-dddddddddd01', '55555555-5555-4555-8555-555555555599', 1, 'phone-1') $$),
  jsonb_build_object('code', 'PT404', 'message', 'NOT_FOUND',
    'detail', jsonb_build_object('product_id', '55555555-5555-4555-8555-555555555599')),
  'a product that is not on the menu is NOT_FOUND naming it'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');
update public.dining_tables set is_active = false where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd08';
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select is(
  test_helpers.error_of($$ select test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04',
    'dddddddd-dddd-4ddd-8ddd-dddddddddd08', '55555555-5555-4555-8555-555555555505', 1, 'phone-1') $$),
  jsonb_build_object('code', 'PT409', 'message', 'TABLE_INACTIVE',
    'detail', jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd08')),
  'a table that is not in service is TABLE_INACTIVE'
);

-- ---------------------------------------------------------------------------------------------
-- One send is one ticket, and the kitchen works from it.
select is(
  public.order_send(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10', 'table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    'sent_at', '2026-09-12T12:05:00Z', 'device_id', 'phone-1', 'payload_hash', test_helpers.hash('send-1')
  )) ->> 'affected',
  '2',
  'one send stamps every unsent item of the table'
);
select is(
  public.order_send(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee11', 'table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    'sent_at', '2026-09-12T12:06:00Z', 'device_id', 'phone-1', 'payload_hash', test_helpers.hash('send-2')
  )) ->> 'affected',
  '0',
  'a second send with nothing new to tell the kitchen stamps nothing'
);
select is(
  test_helpers.error_of($$ select public.order_send(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee12', 'table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd07',
    'sent_at', '2026-09-12T12:06:00Z', 'device_id', 'phone-1', 'payload_hash', test_helpers.hash('send-3'))) $$),
  jsonb_build_object('code', 'PT409', 'message', 'ORDER_CLOSED',
    'detail', jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd07')),
  'sending a table nobody has ordered at is ORDER_CLOSED'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4');
select is(
  public.order_item_prepare(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee13', 'item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01',
    'created_at', '2026-09-12T12:10:00Z', 'device_id', 'kitchen-screen', 'payload_hash', test_helpers.hash('prep-1')
  )) ->> 'affected',
  '1',
  'the kitchen marks a sent item prepared'
);

-- ---------------------------------------------------------------------------------------------
-- Removing after the kitchen was told, and the report that exists because of it.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee20', 'dddddddd-dddd-4ddd-8ddd-dddddddddd03',
  '55555555-5555-4555-8555-555555555510', 3, 'phone-2');
select public.order_send(jsonb_build_object(
  'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee21', 'table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd03',
  'sent_at', '2026-09-12T12:20:00Z', 'device_id', 'phone-2', 'payload_hash', test_helpers.hash('send-4')
));
select public.order_item_remove(jsonb_build_object(
  'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee22', 'item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee20',
  'reason', 'Client parti', 'created_at', '2026-09-12T12:25:00Z', 'device_id', 'phone-2',
  'payload_hash', test_helpers.hash('remove-1')
));
select is(
  (select jsonb_build_object('kept', count(*), 'by', max(i.removed_by::text), 'why', max(i.removed_reason))
   from public.open_order_items i where i.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee20'),
  jsonb_build_object('kept', 1, 'by', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3', 'why', 'Client parti'),
  'a removed item keeps its row, stamped with who took it off and why'
);
select is(
  test_helpers.error_of($$ select public.order_item_remove(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee23', 'item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee99',
    'reason', 'Erreur', 'created_at', '2026-09-12T12:25:00Z', 'device_id', 'phone-2',
    'payload_hash', test_helpers.hash('remove-2'))) $$),
  jsonb_build_object('code', 'PT404', 'message', 'ITEM_NOT_FOUND',
    'detail', jsonb_build_object('item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee99')),
  'removing an item that is on no table is ITEM_NOT_FOUND'
);
select is(
  test_helpers.error_of($$ select public.order_item_prepare(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee24', 'item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee20',
    'created_at', '2026-09-12T12:26:00Z', 'device_id', 'kitchen-screen',
    'payload_hash', test_helpers.hash('prep-2'))) $$) ->> 'code',
  'PT403',
  'a waiter cannot mark an item prepared'
);
-- An item taken off before the kitchen ever heard of it is not fraud, and is not in the report.
select test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee25', 'dddddddd-dddd-4ddd-8ddd-dddddddddd04',
  '55555555-5555-4555-8555-555555555510', 1, 'phone-2');
select public.order_item_remove(jsonb_build_object(
  'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee26', 'item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee25',
  'reason', 'Erreur de saisie', 'created_at', '2026-09-12T12:27:00Z', 'device_id', 'phone-2',
  'payload_hash', test_helpers.hash('remove-3')
));
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');
select is(
  -- Around now(), never a date written here: removed_at is when the server took the removal, so a
  -- fixed day stops matching the day after it.
  public.removed_after_sent(now() - interval '1 hour', now() + interval '1 hour'),
  jsonb_build_array(jsonb_build_object(
    'item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee20',
    'table_name', 'Table 3',
    'product_name', 'Croissant',
    'qty', 3,
    'unit_price_millimes', 1200,
    -- Read back rather than written out: how a timestamptz renders depends on the session's zone,
    -- and what this proves is the row the report chose, not the clock's spelling.
    'sent_at', (select to_jsonb(i.sent_at) #>> '{}' from public.open_order_items i where i.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee20'),
    'removed_at', (select to_jsonb(i.removed_at) #>> '{}' from public.open_order_items i where i.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee20'),
    'removed_by', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
    'removed_by_name', 'Demo Waiter',
    'removed_reason', 'Client parti',
    'submitted_by', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
    'submitted_by_name', 'Demo Waiter'
  )),
  'the report names the waiter, the table, the item and the reason, and only for items the kitchen had been told about'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select throws_ok(
  $$ select public.removed_after_sent('2026-09-12T00:00:00Z', '2026-09-13T00:00:00Z') $$,
  'PT403', 'FORBIDDEN', 'the removed-after-sent report is the admin''s'
);

-- ---------------------------------------------------------------------------------------------
-- Paying a table in parts.
select is(
  public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888801', 1,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'::uuid])),
  jsonb_build_object('sale_id', '88888888-8888-4888-8888-888888888801', 'receipt_number', 'C1-1', 'status', 'created'),
  'paying one item of a table is a sale of its own'
);
select is(
  (select jsonb_build_object('status', o.status, 'paid', (
     select jsonb_agg(i.paid_sale_id order by i.id) from public.open_order_items i where i.order_id = o.id))
   from public.open_orders o where o.table_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd01'),
  jsonb_build_object('status', 'open', 'paid',
    jsonb_build_array('88888888-8888-4888-8888-888888888801', null)),
  'the item carries the sale that paid it and the order stays open for the rest'
);
-- Two tills could both be looking at this table: the second one must not be able to take the same
-- item again while the order is still open.
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888808', 2,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'::uuid])) $$),
  jsonb_build_object('code', 'PT409', 'message', 'ORDER_CHANGED', 'detail', jsonb_build_object(
    'table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    'item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01',
    'line_no', 1)),
  'an item that is already paid cannot be paid again, even while its order is still open'
);
select is(
  public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888802', 2,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02'::uuid])) ->> 'receipt_number',
  'C1-2',
  'the rest of the table is a second sale'
);
select is(
  (select o.status from public.open_orders o where o.table_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd01'),
  'closed',
  'with nothing unpaid left the order closes and the table is free'
);
select is(
  public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888801', 1,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'::uuid])),
  jsonb_build_object('sale_id', '88888888-8888-4888-8888-888888888801', 'receipt_number', 'C1-1', 'status', 'replayed'),
  'a replayed payment returns replayed with the same receipt number'
);
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888810', 9,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'::uuid])) $$) -> 'detail',
  jsonb_build_object('expected_seq', 3, 'received_seq', 9),
  'a gap in the receipt numbers is SEQUENCE_GAP naming the number expected'
);

-- A waiter's offline add, arriving after the caisse closed the table, opens a new order rather than
-- being lost.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select is(
  (select jsonb_build_object('new_order', r.order_id <> o.id, 'status', o.status)
   from (select (test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee30', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
                   '55555555-5555-4555-8555-555555555505', 1, 'phone-2') ->> 'order_id')::uuid as order_id) r
   join public.open_orders o on o.table_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd01' and o.status = 'closed'),
  jsonb_build_object('new_order', true, 'status', 'closed'),
  'an add for a table that was already paid opens a new order instead of reopening the old one'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888803', 3,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'::uuid])) $$),
  jsonb_build_object('code', 'PT409', 'message', 'ORDER_CHANGED', 'detail', jsonb_build_object(
    'table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    'item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01',
    'line_no', 1)),
  'a line naming an item that is already paid is ORDER_CHANGED, with the table, the item and the line'
);
select is(
  test_helpers.error_of($$ select public.record_sale(jsonb_set(
    test_helpers.pay('88888888-8888-4888-8888-888888888804', 3, '77777777-7777-4777-8777-777777777701',
      'dddddddd-dddd-4ddd-8ddd-dddddddddd01', array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee30'::uuid]),
    '{lines,0,qty}', '4')) $$) ->> 'message',
  'ORDER_CHANGED',
  'a line whose quantity no longer matches the item is ORDER_CHANGED too'
);
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888809', 3,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd03',
    array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee20'::uuid])) $$) ->> 'message',
  'ORDER_CHANGED',
  'and so is a line naming an item a waiter took off the table while the till was adding up'
);
select throws_ok(
  $$ select public.open_session(jsonb_build_object(
    'id', '77777777-7777-4777-8777-777777777702', 'terminal_code', 'C1', 'epoch', 0,
    'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'opened_at', '2026-09-12T09:00:00Z',
    'opening_float_millimes', 0, 'payload_hash', test_helpers.hash('open-2'))) $$,
  'PT409', 'SESSION_ALREADY_OPEN', 'a second session on a terminal that already has one is refused'
);

-- ---------------------------------------------------------------------------------------------
-- Refund limits: the ledger is the same one Phase 3 built, now pointing at lines by their id.
select is(
  test_helpers.error_of($$ select public.record_sale(jsonb_build_object(
    'id', '88888888-8888-4888-8888-888888888805', 'kind', 'refund', 'terminal_code', 'C1', 'epoch', 0,
    'seq', 3, 'session_id', '77777777-7777-4777-8777-777777777701',
    'created_at', '2026-09-12T14:00:00Z', 'payload_hash', test_helpers.hash('refund-1'),
    'refunds_sale_id', '88888888-8888-4888-8888-888888888802',
    'lines', jsonb_build_array(jsonb_build_object(
      'line_no', 1,
      'refunds_sale_line_id', (select l.id from public.sale_lines l where l.sale_id = '88888888-8888-4888-8888-888888888802' and l.line_no = 1),
      'product_id', '55555555-5555-4555-8555-555555555501', 'product_name', 'Eau minérale 50 cl',
      'qty', -2, 'unit_price_millimes', 850, 'line_discount_millimes', 0,
      'allocated_discount_millimes', 0, 'net_millimes', -1700)),
    'cart_discount_millimes', 0, 'total_millimes', -1700,
    'payment', jsonb_build_object('method', 'cash', 'tendered_millimes', -1700, 'change_millimes', 0))) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('line_no', 1, 'remaining_qty', 1, 'remaining_millimes', 850)),
  'a refund of more units than a line has left is refused, saying what is left'
);
select is(
  public.record_sale(jsonb_build_object(
    'id', '88888888-8888-4888-8888-888888888806', 'kind', 'refund', 'terminal_code', 'C1', 'epoch', 0,
    'seq', 3, 'session_id', '77777777-7777-4777-8777-777777777701',
    'created_at', '2026-09-12T14:00:00Z', 'payload_hash', test_helpers.hash('refund-2'),
    'refunds_sale_id', '88888888-8888-4888-8888-888888888802',
    'lines', jsonb_build_array(jsonb_build_object(
      'line_no', 1,
      'refunds_sale_line_id', (select l.id from public.sale_lines l where l.sale_id = '88888888-8888-4888-8888-888888888802' and l.line_no = 1),
      'product_id', '55555555-5555-4555-8555-555555555501', 'product_name', 'Eau minérale 50 cl',
      'qty', -1, 'unit_price_millimes', 850, 'line_discount_millimes', 0,
      'allocated_discount_millimes', 0, 'net_millimes', -850)),
    'cart_discount_millimes', 0, 'total_millimes', -850,
    'payment', jsonb_build_object('method', 'cash', 'tendered_millimes', -850, 'change_millimes', 0)
  )) ->> 'receipt_number',
  'C1-3',
  'a refund within what is left points at the sale line by its id and is accepted'
);

-- ---------------------------------------------------------------------------------------------
-- Cancelling a table.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee40', 'dddddddd-dddd-4ddd-8ddd-dddddddddd05',
  '55555555-5555-4555-8555-555555555505', 1, 'phone-1');
select test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee41', 'dddddddd-dddd-4ddd-8ddd-dddddddddd05',
  '55555555-5555-4555-8555-555555555510', 1, 'phone-1');
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888807', 4,
  '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd05',
  array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee40'::uuid]));
select is(
  test_helpers.error_of($$ select public.order_cancel(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee42', 'table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd05',
    'reason', 'Erreur de caisse', 'created_at', '2026-09-12T15:00:00Z',
    'payload_hash', test_helpers.hash('cancel-1'))) $$) ->> 'message',
  'ORDER_CHANGED',
  'an order somebody has already paid part of cannot be cancelled'
);
select is(
  public.order_cancel(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee43', 'table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd03',
    'reason', 'Table partie sans commander', 'created_at', '2026-09-12T15:00:00Z',
    'payload_hash', test_helpers.hash('cancel-2')
  )) ->> 'status',
  'created',
  'a table with nothing paid on it can be cancelled'
);
select is(
  (select o.status from public.open_orders o where o.table_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd03'),
  'cancelled',
  'the cancelled order is closed for good, not left open'
);

-- ---------------------------------------------------------------------------------------------
-- An offered item exists only at payment, and always says why.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee60', 'dddddddd-dddd-4ddd-8ddd-dddddddddd06',
  '55555555-5555-4555-8555-555555555505', 1, 'phone-1');
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888811', 5,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd06',
    array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee60'::uuid], 'cash', null, 200, null)) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('line_no', 1, 'field', 'line_discount_reason')),
  'a discounted line without a reason is refused'
);
select is(
  public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888812', 5,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd06',
    array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee60'::uuid], 'cash', null, 200, 'Offert, attente trop longue')) ->> 'receipt_number',
  'C1-5',
  'the same line with a reason is accepted'
);
select is(
  (select jsonb_build_object('reason', l.line_discount_reason, 'net', l.line_total_millimes)
   from public.sale_lines l where l.sale_id = '88888888-8888-4888-8888-888888888812'),
  jsonb_build_object('reason', 'Offert, attente trop longue', 'net', 1000),
  'the receipt keeps the reason and the line pays 1200 less the 200 that was offered'
);

-- ---------------------------------------------------------------------------------------------
-- Paying a whole table at once, and refunding it line by line: what is left to refund belongs to
-- the line, not to the receipt.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee70', 'dddddddd-dddd-4ddd-8ddd-dddddddddd07',
  '55555555-5555-4555-8555-555555555505', 1, 'phone-1');
select test_helpers.add('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee71', 'dddddddd-dddd-4ddd-8ddd-dddddddddd07',
  '55555555-5555-4555-8555-555555555501', 2, 'phone-1');
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select is(
  public.record_sale(test_helpers.pay('88888888-8888-4888-8888-888888888813', 6,
    '77777777-7777-4777-8777-777777777701', 'dddddddd-dddd-4ddd-8ddd-dddddddddd07',
    array['eeeeeeee-eeee-4eee-8eee-eeeeeeeeee70'::uuid, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee71'::uuid])) ->> 'receipt_number',
  'C1-6',
  'one payment can take the whole table at once'
);
select is(
  (select o.status from public.open_orders o where o.table_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd07'),
  'closed',
  'and the order closes with it'
);
select is(
  public.record_sale(test_helpers.refund('88888888-8888-4888-8888-888888888814', 7,
    '77777777-7777-4777-8777-777777777701', '88888888-8888-4888-8888-888888888813', 2, 1, 850)) ->> 'receipt_number',
  'C1-7',
  'one unit of the second line comes back'
);
select is(
  public.record_sale(test_helpers.refund('88888888-8888-4888-8888-888888888815', 8,
    '77777777-7777-4777-8777-777777777701', '88888888-8888-4888-8888-888888888813', 1, 1, 1200)) ->> 'receipt_number',
  'C1-8',
  'and the first line can still be refunded in full: what an earlier refund took came off its own line'
);

-- ---------------------------------------------------------------------------------------------
-- The ledger these payments wrote is still append-only, for everybody.
select throws_ok($$ update public.sales set total_millimes = 0 $$, '42501', null, 'a cashier cannot update a sale');
select throws_ok($$ delete from public.sales $$, '42501', null, 'a cashier cannot delete a sale');
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');
select throws_ok($$ update public.sales set total_millimes = 0 $$, '42501', null, 'nor can an admin');
select throws_ok($$ update public.open_order_items set paid_sale_id = null $$, '42501',
  null, 'nobody marks an item unpaid by hand either');
reset role;
select throws_ok($$ delete from public.sales $$, 'PT403', 'FORBIDDEN', 'not even the database owner');

-- ---------------------------------------------------------------------------------------------
-- Stock follows the products the café counts, and nothing else.
select is(
  (select jsonb_build_object(
     'eau', (select p.stock_qty from public.products p where p.id = '55555555-5555-4555-8555-555555555501'),
     'express_movements', (select count(*) from public.stock_movements m where m.product_id = '55555555-5555-4555-8555-555555555505'))),
  -- 120 at opening, three units sold across the day and one of them refunded.
  jsonb_build_object('eau', 119, 'express_movements', 0),
  'a tracked product follows its sales and its refunds, and an untracked one never moves at all'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');
select is(
  public.adjust_stock(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee50', 'product_id', '55555555-5555-4555-8555-555555555501',
    'qty_delta', -4, 'reason', 'Casse', 'created_at', '2026-09-12T16:00:00Z',
    'payload_hash', test_helpers.hash('adjust-1')
  )),
  jsonb_build_object('status', 'created', 'product_id', '55555555-5555-4555-8555-555555555501', 'stock_qty', 115),
  'an admin adjustment moves the count and says where it landed'
);
select is(
  public.adjust_stock(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee50', 'product_id', '55555555-5555-4555-8555-555555555501',
    'qty_delta', -4, 'reason', 'Casse', 'created_at', '2026-09-12T16:00:00Z',
    'payload_hash', test_helpers.hash('adjust-1')
  )) ->> 'status',
  'replayed',
  'the same adjustment twice moves the count once'
);

select * from finish();
rollback;
