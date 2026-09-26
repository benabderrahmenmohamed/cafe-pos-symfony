-- Ledger and RPC contract, against the demo café. See api/tests/pgtap/README.md for how to run it.
begin;

create schema if not exists extensions;
create extension if not exists pgtap with schema extensions;
-- pgTAP is called by name, and part of each file calls it as the API's own role.
set local search_path = public, extensions;
grant usage on schema extensions to cafe_app;

select plan(72);

-- Helpers live in a throwaway schema inside this transaction.
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

create function test_helpers.logout()
returns void
language plpgsql
as $$
begin
  perform set_config('app.user_id', '', true);
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

-- The caller's first table. Every fixture sale in this file is paid at it.
create function test_helpers.first_table()
returns uuid
language sql
security definer
as $$
  select t.id
  from public.dining_tables t
  join public.profiles p on p.shop_id = t.shop_id
  where p.user_id = private.current_user_id()
  order by t.sort_order
  limit 1
$$;

-- A sale pays for items of a table's open order, so a payload needs an item to name. This puts one
-- on that table, opening an order lazily the way order_item_add does, and returns its id. A product
-- the caller's shop does not have, or a price above the cap an order item may hold, gets a made-up
-- id instead: record_sale looks at the product and at the price before it looks at the item, and
-- those tests are about the earlier answer.
create function test_helpers.order_item(p_product uuid, p_qty integer, p_unit bigint)
returns uuid
language plpgsql
security definer
as $$
declare
  v_shop uuid;
  v_table uuid;
  v_order uuid;
  v_item uuid := gen_random_uuid();
  v_product public.products;
begin
  select p.shop_id into v_shop from public.profiles p where p.user_id = private.current_user_id();
  select * into v_product from public.products where id = p_product and shop_id = v_shop;
  if not found or p_unit > 1000000000000 then
    return v_item;
  end if;
  v_table := test_helpers.first_table();
  select o.id into v_order from public.open_orders o where o.table_id = v_table and o.status = 'open';
  if v_order is null then
    insert into public.open_orders (shop_id, table_id) values (v_shop, v_table) returning id into v_order;
  end if;
  insert into public.open_order_items (
    id, shop_id, order_id, product_id, name_snapshot, unit_price_millimes, qty, added_by, added_at
  )
  values (v_item, v_shop, v_order, p_product, v_product.name, p_unit, p_qty, private.current_user_id(), now());
  return v_item;
end;
$$;

-- A one-line cash sale of `p_qty` units at `p_unit` on terminal C1, paying for one order item. The
-- amounts keep the key names the app used before the café model, so every call here also proves
-- that a record queued by the older client is still accepted.
create function test_helpers.sale(
  p_id uuid, p_seq bigint, p_session uuid, p_epoch integer, p_hash text,
  p_product uuid, p_qty integer, p_unit bigint,
  p_method text default 'cash', p_tendered bigint default null
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_item uuid := test_helpers.order_item(p_product, p_qty, p_unit);
begin
  return jsonb_build_object(
    'id', p_id, 'kind', 'sale', 'terminal_code', 'C1', 'epoch', p_epoch, 'seq', p_seq, 'session_id', p_session,
    'table_id', test_helpers.first_table(),
    'created_at', '2026-09-11T10:00:00Z', 'payload_hash', p_hash,
    'lines', jsonb_build_array(jsonb_build_object(
      'line_no', 1, 'open_order_item_id', v_item, 'product_id', p_product, 'product_name', 'Test product', 'qty', p_qty,
      'unit_price_millimes', p_unit, 'line_discount_millimes', 0, 'cart_discount_share_millimes', 0,
      'line_total_millimes', p_qty * p_unit
    )),
    'subtotal_millimes', p_qty * p_unit, 'discount_millimes', 0, 'total_millimes', p_qty * p_unit,
    'payment', jsonb_build_object(
      'method', p_method,
      'tendered_millimes', coalesce(p_tendered, p_qty * p_unit),
      'change_millimes', coalesce(p_tendered, p_qty * p_unit) - p_qty * p_unit
    )
  );
end;
$$;

-- A refund of `p_qty` units of line 1 of `p_sale` at `p_unit`, paying `p_amount` (qty x unit when null).
create function test_helpers.refund(
  p_id uuid, p_seq bigint, p_session uuid, p_epoch integer, p_hash text,
  p_sale uuid, p_product uuid, p_qty integer, p_unit bigint, p_amount bigint default null
)
returns jsonb
language sql
as $$
  select jsonb_build_object(
    'id', p_id, 'kind', 'refund', 'terminal_code', 'C1', 'epoch', p_epoch, 'seq', p_seq, 'session_id', p_session,
    'created_at', '2026-09-11T11:00:00Z', 'payload_hash', p_hash, 'refunds_sale_id', p_sale,
    'lines', jsonb_build_array(jsonb_build_object(
      'line_no', 1, 'refunds_line_no', 1, 'product_id', p_product, 'product_name', 'Test product', 'qty', -p_qty,
      'unit_price_millimes', p_unit, 'line_discount_millimes', 0, 'cart_discount_share_millimes', 0,
      'line_total_millimes', -coalesce(p_amount, p_qty * p_unit)
    )),
    'subtotal_millimes', -coalesce(p_amount, p_qty * p_unit), 'discount_millimes', 0,
    'total_millimes', -coalesce(p_amount, p_qty * p_unit),
    'payment', jsonb_build_object('method', 'cash', 'tendered_millimes', -coalesce(p_amount, p_qty * p_unit), 'change_millimes', 0)
  )
$$;

-- A unique-key clash on a record id needs two concurrent transactions, which one test session cannot
-- run. These triggers stand in for the other request: while test_helpers.clash names them, they store
-- a row under the same id inside the RPC's own write, after its idempotency check has passed.
create function test_helpers.clash(p_kind text)
returns void
language plpgsql
as $$
begin
  perform set_config('test_helpers.clash', coalesce(p_kind, ''), true);
end;
$$;

create function test_helpers.clash_sale()
returns trigger
language plpgsql
as $$
declare
  v_row public.sales;
begin
  if pg_trigger_depth() = 1 then
    v_row := new;
    v_row.seq := new.seq + 1000;
    v_row.receipt_number := new.receipt_number || '-clash';
    insert into public.sales values (v_row.*);
  end if;
  return new;
end;
$$;

-- A closed session under the same id as the one being opened.
create function test_helpers.clash_open()
returns trigger
language plpgsql
as $$
begin
  if pg_trigger_depth() = 1 then
    insert into public.cash_sessions (
      id, shop_id, terminal_id, opened_by, open_submitted_by, opened_at, opening_float_millimes, open_payload_hash,
      close_request_id, closed_at, closed_by, close_submitted_by, close_received_at, closing_counted_millimes,
      close_payload_hash, server_z_report
    )
    values (
      new.id, new.shop_id, new.terminal_id, new.opened_by, new.open_submitted_by, new.opened_at, 0, repeat('0', 64),
      gen_random_uuid(), new.opened_at, new.opened_by, new.opened_by, now(), 0, repeat('0', 64), '{}'::jsonb
    );
  end if;
  return new;
end;
$$;

-- Another closed session under the same close request id as the close being stored.
create function test_helpers.clash_close()
returns trigger
language plpgsql
as $$
begin
  if pg_trigger_depth() = 1 then
    insert into public.cash_sessions (
      id, shop_id, terminal_id, opened_by, open_submitted_by, opened_at, opening_float_millimes, open_payload_hash,
      close_request_id, closed_at, closed_by, close_submitted_by, close_received_at, closing_counted_millimes,
      close_payload_hash, server_z_report
    )
    values (
      gen_random_uuid(), new.shop_id, new.terminal_id, new.opened_by, new.open_submitted_by, new.opened_at, 0, repeat('0', 64),
      new.close_request_id, new.closed_at, new.closed_by, new.close_submitted_by, now(), 0, repeat('0', 64), '{}'::jsonb
    );
  end if;
  return new;
end;
$$;

create trigger test_clash_sale before insert on public.sales
  for each row when (current_setting('test_helpers.clash', true) = 'sale')
  execute function test_helpers.clash_sale();
create trigger test_clash_open before insert on public.cash_sessions
  for each row when (current_setting('test_helpers.clash', true) = 'open')
  execute function test_helpers.clash_open();
create trigger test_clash_close before update on public.cash_sessions
  for each row when (current_setting('test_helpers.clash', true) = 'close')
  execute function test_helpers.clash_close();

grant execute on all functions in schema test_helpers to cafe_app;

-- Seed ids
--   shop A admin   aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1   shop A cashier aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2
--   shop B cashier bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2   water (850, stock 120) 55555555-5555-4555-8555-555555555501
--   shop B product 66666666-6666-4666-8666-666666666601   each shop has a terminal C1 at epoch 0

-- Nobody on the connection gets nothing. There is no anonymous role on this server - a request
-- without a token is refused before it reaches the database - so the one that matters is the API's
-- own role before it has said who a request is for.
select test_helpers.logout();
select is((select count(*)::integer from public.sales), 0, 'nobody on the connection reads a sale');
select throws_ok(
  $$ select public.record_sale('{}'::jsonb) $$, 'PT401', 'UNAUTHENTICATED',
  'nobody on the connection records a sale'
);
reset role;
-- A role that was granted nothing has what PUBLIC has, and that is no function of the café's.
create role test_nobody;
select is(
  (select count(*)::integer
   from pg_catalog.pg_proc pr
   join pg_catalog.pg_namespace n on n.oid = pr.pronamespace
   where n.nspname = 'public' and has_function_privilege('test_nobody', pr.oid, 'execute')),
  0,
  'a role granted nothing can execute no function in public, not even through PUBLIC'
);
-- Supabase also checked the default privileges of functions added later, because PostgREST publishes
-- every function in public as an endpoint of its own. This server publishes none - a controller calls
-- the functions it names - so that check has nothing left to protect here.

-- A signed-in user without a session token is UNAUTHENTICATED inside the RPC.
select test_helpers.logout();
select throws_ok($$ select public.my_profile() $$, 'PT401', 'UNAUTHENTICATED', 'no JWT subject is UNAUTHENTICATED');

select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select is(public.my_profile() -> 'roles', '["cashier"]'::jsonb, 'my_profile returns the roles the member holds');

-- Sessions
select is(
  public.open_session(jsonb_build_object(
    'id', '77777777-7777-4777-8777-777777777701', 'terminal_code', 'C1', 'epoch', 0,
    'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'opened_at', '2026-09-11T08:00:00Z',
    'opening_float_millimes', 50000, 'payload_hash', repeat('a', 64)
  )) ->> 'status',
  'created',
  'open_session creates the session'
);
select is(
  public.open_session(jsonb_build_object(
    'id', '77777777-7777-4777-8777-777777777701', 'terminal_code', 'C1', 'epoch', 0,
    'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'opened_at', '2026-09-11T08:00:00Z',
    'opening_float_millimes', 50000, 'payload_hash', repeat('a', 64)
  )) ->> 'status',
  'replayed',
  'a replayed open_session returns replayed, not SESSION_ALREADY_OPEN'
);
select throws_ok(
  $$ select public.open_session(jsonb_build_object(
    'id', '77777777-7777-4777-8777-777777777701', 'terminal_code', 'C1', 'epoch', 0,
    'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'opened_at', '2026-09-11T08:00:00Z',
    'opening_float_millimes', 60000, 'payload_hash', repeat('b', 64))) $$,
  'PT409', 'IDEMPOTENCY_CONFLICT', 'the same session id with another payload is IDEMPOTENCY_CONFLICT'
);
select throws_ok(
  $$ select public.open_session(jsonb_build_object(
    'id', '77777777-7777-4777-8777-777777777702', 'terminal_code', 'C1', 'epoch', 0,
    'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'opened_at', '2026-09-11T08:05:00Z',
    'opening_float_millimes', 0, 'payload_hash', repeat('c', 64))) $$,
  'PT409', 'SESSION_ALREADY_OPEN', 'a second open session on the terminal is SESSION_ALREADY_OPEN'
);
select throws_ok(
  $$ select public.open_session(jsonb_build_object(
    'id', '77777777-7777-4777-8777-777777777702', 'terminal_code', 'C1', 'epoch', 0,
    'actor_user_id', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2', 'opened_at', 'not a time',
    'opening_float_millimes', -1, 'payload_hash', repeat('c', 64))) $$,
  'PT409', 'SESSION_ALREADY_OPEN', 'SESSION_ALREADY_OPEN comes before the actor, float and time checks'
);

-- Sales: created, replayed, no duplicate row
select is(
  public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888801', 1, '77777777-7777-4777-8777-777777777701', 0,
    repeat('d', 64), '55555555-5555-4555-8555-555555555501', 2, 850, 'cash', 2000)) ->> 'receipt_number',
  'C1-1',
  'the first sale on C1 is receipt C1-1'
);
select is(
  public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888801', 1, '77777777-7777-4777-8777-777777777701', 0,
    repeat('d', 64), '55555555-5555-4555-8555-555555555501', 2, 850, 'cash', 2000)),
  jsonb_build_object('sale_id', '88888888-8888-4888-8888-888888888801', 'receipt_number', 'C1-1', 'status', 'replayed'),
  'a replayed record_sale returns replayed with the same receipt number'
);
select is((select count(*)::integer from public.sales), 1, 'a replay does not insert a second sale');
select is(
  (select stock_qty from public.products where id = '55555555-5555-4555-8555-555555555501'),
  118,
  'the sale takes 2 units out of stock'
);
select is(
  (select sum(delta)::integer from public.stock_movements where product_id = '55555555-5555-4555-8555-555555555501'),
  118,
  'stock equals the sum of its movements'
);
select throws_ok(
  $$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888801', 1, '77777777-7777-4777-8777-777777777701', 0,
    repeat('e', 64), '55555555-5555-4555-8555-555555555501', 3, 850)) $$,
  'PT409', 'IDEMPOTENCY_CONFLICT', 'the same sale id with another payload is IDEMPOTENCY_CONFLICT'
);

-- Numbering
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888802', 3,
    '77777777-7777-4777-8777-777777777701', 0, repeat('f', 64), '55555555-5555-4555-8555-555555555501', 1, 850)) $$) -> 'detail' ->> 'expected_seq',
  '2',
  'a gap is SEQUENCE_GAP with expected_seq'
);

-- Unknown references are NOT_FOUND naming the id; an id that is not a UUID is a malformed payload
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888802', 2,
    '77777777-7777-4777-8777-777777777799', 0, repeat('f', 64), '55555555-5555-4555-8555-555555555501', 1, 850)) $$),
  jsonb_build_object('code', 'PT404', 'message', 'NOT_FOUND', 'detail', jsonb_build_object('session_id', '77777777-7777-4777-8777-777777777799')),
  'an unknown session is NOT_FOUND with session_id'
);
select is(
  test_helpers.error_of($$ select public.record_sale(jsonb_set(test_helpers.sale('88888888-8888-4888-8888-888888888802', 2,
    '77777777-7777-4777-8777-777777777701', 0, repeat('f', 64), '55555555-5555-4555-8555-555555555501', 1, 850),
    '{session_id}', '"no-such-session"')) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR', 'detail', jsonb_build_object('field', 'session_id')),
  'a session id that is not a UUID is VALIDATION_ERROR naming the field'
);
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888802', 2,
    '77777777-7777-4777-8777-777777777701', 0, repeat('f', 64), '55555555-5555-4555-8555-555555555599', 1, 850)) $$),
  jsonb_build_object('code', 'PT404', 'message', 'NOT_FOUND', 'detail', jsonb_build_object('product_id', '55555555-5555-4555-8555-555555555599')),
  'an unknown product is NOT_FOUND with product_id'
);
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888802', 2,
    '77777777-7777-4777-8777-777777777701', 0, repeat('f', 64), '66666666-6666-4666-8666-666666666601', 1, 1000)) $$),
  jsonb_build_object('code', 'PT404', 'message', 'NOT_FOUND', 'detail', jsonb_build_object('product_id', '66666666-6666-4666-8666-666666666601')),
  'a product of another shop is NOT_FOUND in this shop'
);
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.refund('88888888-8888-4888-8888-888888888802', 2,
    '77777777-7777-4777-8777-777777777701', 0, repeat('f', 64), '88888888-8888-4888-8888-888888888899',
    '55555555-5555-4555-8555-555555555501', 1, 850)) $$),
  jsonb_build_object('code', 'PT404', 'message', 'NOT_FOUND', 'detail', jsonb_build_object('sale_id', '88888888-8888-4888-8888-888888888899')),
  'a refund of an unknown sale is NOT_FOUND with sale_id'
);

-- Payment and totals
select throws_ok(
  $$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888803', 2, '77777777-7777-4777-8777-777777777701', 0,
    repeat('f', 64), '55555555-5555-4555-8555-555555555501', 1, 850, 'cash', 800)) $$,
  'PT422', 'VALIDATION_ERROR', 'cash tendered below the total is rejected'
);
select throws_ok(
  $$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888803', 2, '77777777-7777-4777-8777-777777777701', 0,
    repeat('f', 64), '55555555-5555-4555-8555-555555555501', 1, 850, 'card', 1000)) $$,
  'PT422', 'VALIDATION_ERROR', 'a card payment with change is rejected'
);
select throws_ok(
  $$ select public.record_sale(jsonb_set(test_helpers.sale('88888888-8888-4888-8888-888888888803', 2, '77777777-7777-4777-8777-777777777701', 0,
    repeat('f', 64), '55555555-5555-4555-8555-555555555501', 1, 850), '{total_millimes}', '900')) $$,
  'PT422', 'VALIDATION_ERROR', 'totals that do not match the lines are rejected'
);

-- The ledger cannot be written directly
select throws_ok($$ update public.sales set total_millimes = 0 $$, '42501', null, 'a cashier cannot update sales');
select throws_ok($$ delete from public.sales $$, '42501', null, 'a cashier cannot delete sales');
select throws_ok($$ delete from public.sale_lines $$, '42501', null, 'a cashier cannot delete sale lines');
select throws_ok($$ update public.products set stock_qty = 999 $$, '42501', null, 'a cashier cannot write stock directly');
select throws_ok($$ select public.register_terminal('T9') $$, 'PT403', 'FORBIDDEN', 'a cashier cannot register a terminal');

-- Refunds
select is(
  public.record_sale(test_helpers.refund('88888888-8888-4888-8888-888888888804', 2, '77777777-7777-4777-8777-777777777701', 0,
    repeat('1', 64), '88888888-8888-4888-8888-888888888801', '55555555-5555-4555-8555-555555555501', 1, 850)) ->> 'status',
  'created',
  'refunding one of the two units is accepted'
);
select throws_ok(
  $$ select public.record_sale(test_helpers.refund('88888888-8888-4888-8888-888888888805', 3, '77777777-7777-4777-8777-777777777701', 0,
    repeat('2', 64), '88888888-8888-4888-8888-888888888801', '55555555-5555-4555-8555-555555555501', 2, 850)) $$,
  'PT422', 'VALIDATION_ERROR', 'refunding more than is left is rejected'
);
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.refund('88888888-8888-4888-8888-888888888809', 3,
    '77777777-7777-4777-8777-777777777701', 0, repeat('7', 64), '88888888-8888-4888-8888-888888888801',
    '55555555-5555-4555-8555-555555555501', 1, 850, 800)) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('line_no', 1, 'remaining_qty', 1, 'remaining_millimes', 850)),
  'a refund of the last unit must pay exactly what is left of the line'
);
select is(
  (select stock_qty from public.products where id = '55555555-5555-4555-8555-555555555501'),
  119,
  'a refund puts the unit back in stock'
);

-- Another shop sees nothing of shop A, and naming shop A's session is FORBIDDEN
select test_helpers.login('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2');
select is((select count(*)::integer from public.sales), 0, 'a cashier of shop B sees no sales of shop A');
select is((select count(*)::integer from public.products), 2, 'a cashier of shop B sees only its own products');
select is((select count(*)::integer from public.cash_sessions), 0, 'a cashier of shop B sees no sessions of shop A');
select throws_ok(
  $$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888806', 1, '77777777-7777-4777-8777-777777777701', 0,
    repeat('3', 64), '66666666-6666-4666-8666-666666666601', 1, 1000)) $$,
  'PT403', 'FORBIDDEN', 'recording against another shop''s session is FORBIDDEN'
);
select throws_ok(
  $$ select public.close_session(jsonb_build_object(
    'id', '99999999-9999-4999-8999-999999999909', 'session_id', '77777777-7777-4777-8777-777777777701',
    'terminal_code', 'C1', 'epoch', 0, 'actor_user_id', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',
    'closed_at', '2026-09-11T20:00:00Z', 'closing_counted_millimes', 0, 'client_z_report', null,
    'payload_hash', repeat('8', 64))) $$,
  'PT403', 'FORBIDDEN', 'closing another shop''s session is FORBIDDEN'
);
select throws_ok(
  $$ select public.z_report('77777777-7777-4777-8777-777777777701') $$,
  'PT403', 'FORBIDDEN', 'the Z-report of another shop''s session is FORBIDDEN'
);

-- Re-registering the terminal supersedes the old device, but replays still return their outcome
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');
select is(
  public.register_terminal('c1') - 'terminal_id' - 'open_session',
  jsonb_build_object('code', 'C1', 'last_seq', 2, 'epoch', 1),
  'registration returns the counter to adopt and bumps the epoch'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select throws_ok(
  $$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888807', 3, '77777777-7777-4777-8777-777777777701', 0,
    repeat('4', 64), '55555555-5555-4555-8555-555555555501', 1, 850)) $$,
  'PT409', 'TERMINAL_SUPERSEDED', 'a record from the superseded device is TERMINAL_SUPERSEDED'
);
select is(
  public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888801', 1, '77777777-7777-4777-8777-777777777701', 0,
    repeat('d', 64), '55555555-5555-4555-8555-555555555501', 2, 850, 'cash', 2000)) ->> 'status',
  'replayed',
  'a replay from the superseded device still returns replayed'
);

-- Voiding a record that can never be accepted keeps numbering gapless
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');
select is(
  public.void_receipt(jsonb_build_object(
    'record', test_helpers.refund('88888888-8888-4888-8888-888888888805', 3, '77777777-7777-4777-8777-777777777701', 0,
      repeat('2', 64), '88888888-8888-4888-8888-888888888801', '55555555-5555-4555-8555-555555555501', 2, 850),
    'error_code', 'VALIDATION_ERROR',
    'reason', 'Refund recorded offline after the unit was already refunded on another till'
  )) ->> 'receipt_number',
  'C1-3',
  'void_receipt consumes the next receipt number'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select is(
  public.record_sale(test_helpers.refund('88888888-8888-4888-8888-888888888805', 3, '77777777-7777-4777-8777-777777777701', 0,
    repeat('2', 64), '88888888-8888-4888-8888-888888888801', '55555555-5555-4555-8555-555555555501', 2, 850)) ->> 'status',
  'voided',
  'resending a voided record returns voided'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');
select is(
  public.void_receipt(jsonb_build_object(
    'record', test_helpers.sale('88888888-8888-4888-8888-888888888801', 1, '77777777-7777-4777-8777-777777777701', 0,
      repeat('d', 64), '55555555-5555-4555-8555-555555555501', 2, 850, 'cash', 2000),
    'error_code', 'NETWORK_ERROR',
    'reason', 'Never acknowledged on the till'
  )),
  jsonb_build_object('sale_id', '88888888-8888-4888-8888-888888888801', 'receipt_number', 'C1-1', 'status', 'recorded'),
  'voiding the same record that reached the ledger returns recorded'
);
select throws_ok(
  $$ select public.void_receipt(jsonb_build_object(
    'record', test_helpers.sale('88888888-8888-4888-8888-888888888801', 1, '77777777-7777-4777-8777-777777777701', 0,
      repeat('e', 64), '55555555-5555-4555-8555-555555555501', 3, 850),
    'error_code', 'NETWORK_ERROR',
    'reason', 'Never acknowledged on the till')) $$,
  'PT409', 'IDEMPOTENCY_CONFLICT', 'voiding another record stored under the same id is IDEMPOTENCY_CONFLICT'
);

-- A unique-key clash on a record id is IDEMPOTENCY_CONFLICT, and nothing of the attempt is kept
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select test_helpers.clash('sale');
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888810', 4,
    '77777777-7777-4777-8777-777777777701', 1, repeat('9', 64), '55555555-5555-4555-8555-555555555501', 1, 850)) $$),
  jsonb_build_object('code', 'PT409', 'message', 'IDEMPOTENCY_CONFLICT', 'detail', jsonb_build_object('id', '88888888-8888-4888-8888-888888888810')),
  'a sale id stored by a concurrent request is IDEMPOTENCY_CONFLICT'
);
select test_helpers.clash('close');
select is(
  test_helpers.error_of($$ select public.close_session(jsonb_build_object(
    'id', '99999999-9999-4999-8999-999999999901', 'session_id', '77777777-7777-4777-8777-777777777701',
    'terminal_code', 'C1', 'epoch', 1, 'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'closed_at', '2026-09-11T20:00:00Z', 'closing_counted_millimes', 50800, 'client_z_report', null,
    'payload_hash', repeat('5', 64))) $$),
  jsonb_build_object('code', 'PT409', 'message', 'IDEMPOTENCY_CONFLICT', 'detail', jsonb_build_object('id', '99999999-9999-4999-8999-999999999901')),
  'a close request id stored by a concurrent request is IDEMPOTENCY_CONFLICT'
);
select test_helpers.clash(null);
select is(
  jsonb_build_object(
    'sales', (select count(*) from public.sales),
    'open_sessions', (select count(*) from public.cash_sessions where closed_at is null),
    'closed_sessions', (select count(*) from public.cash_sessions where closed_at is not null)
  ),
  '{"sales": 2, "open_sessions": 1, "closed_sessions": 0}'::jsonb,
  'the clashing attempts left no rows behind'
);

-- close_session reads session_id at the session step, after the terminal and the epoch
select throws_ok(
  $$ select public.close_session(jsonb_build_object(
    'id', '99999999-9999-4999-8999-999999999905', 'session_id', 'S1',
    'terminal_code', 'T9', 'epoch', 1, 'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'closed_at', '2026-09-11T20:00:00Z', 'closing_counted_millimes', 0, 'client_z_report', null,
    'payload_hash', repeat('7', 64))) $$,
  'PT403', 'FORBIDDEN', 'a close naming a terminal the shop does not have is FORBIDDEN, malformed session id or not'
);
select throws_ok(
  $$ select public.close_session(jsonb_build_object(
    'id', '99999999-9999-4999-8999-999999999906', 'session_id', 'S1',
    'terminal_code', 'C1', 'epoch', 0, 'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'closed_at', '2026-09-11T20:00:00Z', 'closing_counted_millimes', 0, 'client_z_report', null,
    'payload_hash', repeat('8', 64))) $$,
  'PT409', 'TERMINAL_SUPERSEDED', 'a close from a superseded device is TERMINAL_SUPERSEDED, malformed session id or not'
);

-- Closing the session and its Z-report
select is(
  test_helpers.error_of($$ select public.close_session(jsonb_build_object(
    'id', '99999999-9999-4999-8999-999999999902', 'session_id', '77777777-7777-4777-8777-777777777799',
    'terminal_code', 'C1', 'epoch', 1, 'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'closed_at', '2026-09-11T20:00:00Z', 'closing_counted_millimes', 0, 'client_z_report', null,
    'payload_hash', repeat('6', 64))) $$),
  jsonb_build_object('code', 'PT404', 'message', 'NOT_FOUND', 'detail', jsonb_build_object('session_id', '77777777-7777-4777-8777-777777777799')),
  'closing an unknown session is NOT_FOUND with session_id'
);
select is(
  (public.close_session(jsonb_build_object(
    'id', '99999999-9999-4999-8999-999999999901', 'session_id', '77777777-7777-4777-8777-777777777701',
    'terminal_code', 'C1', 'epoch', 1, 'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'closed_at', '2026-09-11T20:00:00Z', 'closing_counted_millimes', 50800, 'client_z_report', null,
    'payload_hash', repeat('5', 64)
  )) -> 'z_report') - 'session_id',
  jsonb_build_object(
    'opening_float_millimes', 50000, 'sales_count', 1, 'refunds_count', 1,
    'gross_millimes', 1700, 'refunds_millimes', 850, 'net_millimes', 850,
    'by_method', jsonb_build_object(
      'cash', jsonb_build_object('sales_millimes', 1700, 'refunds_millimes', 850, 'net_millimes', 850),
      'card', jsonb_build_object('sales_millimes', 0, 'refunds_millimes', 0, 'net_millimes', 0)
    ),
    'expected_cash_millimes', 50850, 'counted_cash_millimes', 50800, 'variance_millimes', -50, 'voids_count', 1
  ),
  'close_session returns the Z-report'
);
select is(
  public.close_session(jsonb_build_object(
    'id', '99999999-9999-4999-8999-999999999901', 'session_id', '77777777-7777-4777-8777-777777777701',
    'terminal_code', 'C1', 'epoch', 1, 'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'closed_at', '2026-09-11T20:00:00Z', 'closing_counted_millimes', 50800, 'client_z_report', null,
    'payload_hash', repeat('5', 64)
  )) ->> 'status',
  'replayed',
  'a replayed close returns replayed'
);
select throws_ok(
  $$ select public.close_session(jsonb_build_object(
    'id', '99999999-9999-4999-8999-999999999903', 'session_id', '77777777-7777-4777-8777-777777777701',
    'terminal_code', 'C1', 'epoch', 0, 'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'closed_at', '2026-09-11T21:00:00Z', 'closing_counted_millimes', 50800, 'client_z_report', null,
    'payload_hash', repeat('a', 64))) $$,
  'PT409', 'TERMINAL_SUPERSEDED', 'a new close from the superseded device is TERMINAL_SUPERSEDED before the session checks'
);
select throws_ok(
  $$ select public.close_session(jsonb_build_object(
    'id', '99999999-9999-4999-8999-999999999904', 'session_id', '77777777-7777-4777-8777-777777777701',
    'terminal_code', 'C1', 'epoch', 1, 'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
    'closed_at', '2026-09-11T21:00:00Z', 'closing_counted_millimes', 50800, 'client_z_report', null,
    'payload_hash', repeat('b', 64))) $$,
  'PT409', 'SESSION_CLOSED', 'a new close of a closed session is SESSION_CLOSED'
);
select test_helpers.clash('open');
select is(
  test_helpers.error_of($$ select public.open_session(jsonb_build_object(
    'id', '77777777-7777-4777-8777-777777777703', 'terminal_code', 'C1', 'epoch', 1,
    'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'opened_at', '2026-09-12T08:00:00Z',
    'opening_float_millimes', 0, 'payload_hash', repeat('c', 64))) $$),
  jsonb_build_object('code', 'PT409', 'message', 'IDEMPOTENCY_CONFLICT', 'detail', jsonb_build_object('id', '77777777-7777-4777-8777-777777777703')),
  'a session id stored by a concurrent request is IDEMPOTENCY_CONFLICT'
);
select test_helpers.clash(null);
select throws_ok(
  $$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888808', 4, '77777777-7777-4777-8777-777777777701', 1,
    repeat('6', 64), '55555555-5555-4555-8555-555555555501', 1, 850)) $$,
  'PT409', 'SESSION_CLOSED', 'a record for a closed session is SESSION_CLOSED'
);
select is(public.z_report('77777777-7777-4777-8777-777777777701') ->> 'variance_millimes', '-50', 'z_report returns the stored report');

-- A closed session is final, even for the database owner
reset role;
select throws_ok(
  $$ update public.cash_sessions set closing_counted_millimes = 50850 where id = '77777777-7777-4777-8777-777777777701' $$,
  'PT409', 'SESSION_CLOSED', 'a closed session cannot be edited'
);
select is(
  (select last_seq from public.terminals where id = '33333333-3333-4333-8333-333333333331'),
  3::bigint,
  'every receipt number up to C1-3 is accounted for'
);

-- Prices stop at one billion dinars, the bound src/ports/catalog.ts reads rows back with
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');
select is(
  public.save_product(jsonb_build_object(
    'name', 'At the cap', 'price_millimes', 1000000000000, 'stock_delta', 0
  )) ->> 'price_millimes',
  '1000000000000',
  'a product at exactly one billion dinars is saved'
);
select is(
  test_helpers.error_of($$ select public.save_product(jsonb_build_object(
    'name', 'Above the cap', 'price_millimes', 1000000000001, 'stock_delta', 0)) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR', 'detail', jsonb_build_object('field', 'price_millimes')),
  'a product one millime above the cap is VALIDATION_ERROR with price_millimes'
);
select public.open_session(jsonb_build_object(
  'id', '77777777-7777-4777-8777-777777777704', 'terminal_code', 'C1', 'epoch', 1,
  'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 'opened_at', '2026-09-12T08:00:00Z',
  'opening_float_millimes', 0, 'payload_hash', repeat('d', 64)
));
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888811', 4,
    '77777777-7777-4777-8777-777777777704', 1, repeat('a', 64), '55555555-5555-4555-8555-555555555501', 1, 1000000000001)) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR', 'detail', jsonb_build_object('line_no', 1)),
  'a sale line one millime above the cap is VALIDATION_ERROR with line_no'
);
select is(
  public.record_sale(test_helpers.sale('88888888-8888-4888-8888-888888888811', 4,
    '77777777-7777-4777-8777-777777777704', 1, repeat('a', 64), '55555555-5555-4555-8555-555555555501', 1, 1000000000000)) ->> 'status',
  'created',
  'a sale line at exactly the cap is recorded'
);
reset role;

-- The ledger is append-only even for its owner - the role migrations run as, which nothing else on
-- this server outranks - unless the transaction turns on pos.ledger_maintenance.
select throws_ok($$ update public.sales set total_millimes = total_millimes $$, 'PT403', 'FORBIDDEN', 'the owner cannot update sales');
select throws_ok(
  $$ delete from public.sale_lines where sale_id = '88888888-8888-4888-8888-888888888804' $$,
  'PT403', 'FORBIDDEN', 'the owner cannot delete sale lines'
);
select throws_ok($$ delete from public.stock_movements $$, 'PT403', 'FORBIDDEN', 'the owner cannot delete stock movements');
select throws_ok($$ truncate public.receipt_voids $$, 'PT403', 'FORBIDDEN', 'the owner cannot truncate receipt voids');
set local pos.ledger_maintenance = 'on';
select lives_ok(
  $$ update public.sales set received_at = received_at where id = '88888888-8888-4888-8888-888888888801' $$,
  'with pos.ledger_maintenance on, the owner can change the ledger'
);
set local pos.ledger_maintenance = 'off';
select throws_ok($$ delete from public.receipt_voids $$, 'PT403', 'FORBIDDEN', 'the owner is refused again once maintenance is off');

select * from finish();
rollback;
