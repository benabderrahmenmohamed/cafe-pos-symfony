-- Counter sales and table management: migration 20260911000013. A café sells across the counter as
-- well as to tables, and the room itself is something the admin edits.
--
-- What is checked here: a sale that names no table and pays no order item is recorded and numbered;
-- a bill that mixes a table's rows with a counter line settles exactly the rows it names; a line
-- that names an item without naming the table is refused; the room is the admin's, a retired table
-- takes nothing new, and a sale paid at a table that is retired afterwards still names it.
begin;

create schema if not exists extensions;
create extension if not exists pgtap with schema extensions;
-- pgTAP is called by name, and part of each file calls it as the API's own role.
set local search_path = public, extensions;
grant usage on schema extensions to cafe_app;

select plan(30);

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

create function test_helpers.hash(p_seed text)
returns text
language sql
immutable
as $$ select md5(p_seed) || md5('salt' || p_seed) $$;

create function test_helpers.add(p_id uuid, p_table uuid, p_product uuid, p_qty integer, p_device text)
returns jsonb
language sql
as $$
  select public.order_item_add(jsonb_build_object(
    'id', p_id, 'table_id', p_table, 'product_id', p_product, 'qty', p_qty, 'note', '',
    'device_id', p_device, 'added_at', '2026-09-12T12:00:00Z', 'payload_hash', test_helpers.hash(p_id::text)
  ))
$$;

-- A bill of arbitrary lines: p_items names the order item each line pays, or null for a line that
-- pays none. The table is named separately, because a counter sale names no table at all.
create function test_helpers.bill(
  p_id uuid, p_seq bigint, p_session uuid, p_table uuid,
  p_items uuid[], p_products uuid[], p_names text[], p_qtys integer[], p_prices bigint[]
)
returns jsonb
language sql
security definer
as $$
  with lines as (
    select
      ord::integer as line_no,
      -- The row id is the device's to choose, so the bill states one for every line. The app
      -- derives it from the record id and the line number (src/features/sales/records.ts); the
      -- server stores what it is given, so any derivation the test can repeat will do.
      md5(p_id::text || ':' || ord::text)::uuid as line_id,
      p_items[ord] as item_id,
      p_products[ord] as product_id,
      p_names[ord] as product_name,
      p_qtys[ord] as qty,
      p_prices[ord] as unit_price_millimes
    from generate_subscripts(p_products, 1) as ord
  )
  select jsonb_build_object(
    'id', p_id, 'kind', 'sale', 'terminal_code', 'C1', 'epoch', 0, 'seq', p_seq,
    'session_id', p_session, 'table_id', p_table,
    'created_at', '2026-09-12T13:00:00Z', 'payload_hash', test_helpers.hash(p_id::text),
    'lines', (
      select jsonb_agg(
        jsonb_build_object(
          'id', l.line_id,
          'line_no', l.line_no, 'open_order_item_id', l.item_id, 'product_id', l.product_id,
          'product_name', l.product_name, 'qty', l.qty, 'unit_price_millimes', l.unit_price_millimes,
          'line_discount_millimes', 0, 'allocated_discount_millimes', 0,
          'net_millimes', l.qty * l.unit_price_millimes
        )
        order by l.line_no
      )
      from lines l
    ),
    'cart_discount_millimes', 0,
    'total_millimes', (select sum(l.qty * l.unit_price_millimes) from lines l),
    'payment', jsonb_build_object(
      'method', 'cash',
      'tendered_millimes', (select sum(l.qty * l.unit_price_millimes) from lines l),
      'change_millimes', 0
    )
  )
$$;

grant execute on all functions in schema test_helpers to cafe_app;

-- Seed ids
--   admin aaa…1, cashier aaa…2, waiter aaa…3, kitchen aaa…4
--   terminal C1 at epoch 0; tables dddddddd-dddd-4ddd-8ddd-dddddddddd01 … 08
--   Express 55555555-…-555505 (1200, untracked), Eau minérale 50 cl 55555555-…-555501 (850, tracked)

select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select public.open_session(jsonb_build_object(
  'id', '77777777-7777-4777-8777-777777777701', 'terminal_code', 'C1', 'epoch', 0,
  'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'opened_at', '2026-09-12T08:00:00Z',
  'opening_float_millimes', 50000, 'payload_hash', test_helpers.hash('open-1')
));

-- ---------------------------------------------------------------------------------------------
-- A coffee taken away. No table, no order item, and it is still a numbered receipt.
select is(
  public.record_sale(test_helpers.bill(
    '88888888-8888-4888-8888-888888888801', 1, '77777777-7777-4777-8777-777777777701', null,
    array[null]::uuid[], array['55555555-5555-4555-8555-555555555505']::uuid[],
    array['Express'], array[1], array[1200]::bigint[]
  )),
  jsonb_build_object('sale_id', '88888888-8888-4888-8888-888888888801', 'receipt_number', 'C1-1', 'status', 'created'),
  'a counter sale with no table and no order item is recorded under the next receipt number'
);
select is(
  (select table_id from public.sales where id = '88888888-8888-4888-8888-888888888801'),
  null,
  'the counter sale names no table'
);
select is(
  (select count(*)::integer from public.sale_lines where sale_id = '88888888-8888-4888-8888-888888888801' and open_order_item_id is null),
  1,
  'its line pays no order item'
);
-- The device names its own rows, so a register that sold offline can refund the same receipt
-- before either record has reached anyone.
select is(
  (select id from public.sale_lines where sale_id = '88888888-8888-4888-8888-888888888801'),
  md5('88888888-8888-4888-8888-888888888801:1')::uuid,
  'the line is stored under the row id the bill gave it'
);
select is(
  (select count(*)::integer from public.open_orders),
  0,
  'and it opened no order on any table'
);
-- Untracked products keep no stock, so nothing moved.
select is(
  (select count(*)::integer from public.stock_movements where sale_id = '88888888-8888-4888-8888-888888888801'),
  0,
  'an untracked product moves no stock when it is sold'
);

-- A counter sale of something the shop does count takes it out of stock all the same.
select is(
  public.record_sale(test_helpers.bill(
    '88888888-8888-4888-8888-888888888802', 2, '77777777-7777-4777-8777-777777777701', null,
    array[null]::uuid[], array['55555555-5555-4555-8555-555555555501']::uuid[],
    array['Eau minérale 50 cl'], array[2], array[850]::bigint[]
  )) ->> 'status',
  'created',
  'a counter sale of a tracked product is recorded'
);
select is(
  (select sum(delta)::integer from public.stock_movements where sale_id = '88888888-8888-4888-8888-888888888802'),
  -2,
  'and it takes its units out of stock'
);

-- ---------------------------------------------------------------------------------------------
-- A bill that mixes a table's rows with something bought off the counter on the way out.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select test_helpers.add('cccccccc-cccc-4ccc-8ccc-cccccccccc01',
  'dddddddd-dddd-4ddd-8ddd-dddddddddd01', '55555555-5555-4555-8555-555555555505', 1, 'phone-1');
select test_helpers.add('cccccccc-cccc-4ccc-8ccc-cccccccccc02',
  'dddddddd-dddd-4ddd-8ddd-dddddddddd01', '55555555-5555-4555-8555-555555555505', 1, 'phone-1');

select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select is(
  public.record_sale(test_helpers.bill(
    '88888888-8888-4888-8888-888888888803', 3, '77777777-7777-4777-8777-777777777701',
    'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    array['cccccccc-cccc-4ccc-8ccc-cccccccccc01', null]::uuid[],
    array['55555555-5555-4555-8555-555555555505', '55555555-5555-4555-8555-555555555501']::uuid[],
    array['Express', 'Eau minérale 50 cl'], array[1, 1], array[1200, 850]::bigint[]
  )) ->> 'status',
  'created',
  'one bill pays a row of the table and a product bought at the counter'
);
select is(
  (select paid_sale_id from public.open_order_items where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccc01'),
  '88888888-8888-4888-8888-888888888803'::uuid,
  'the row it named is marked paid by that sale'
);
select is(
  (select paid_sale_id from public.open_order_items where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccc02'),
  null,
  'the row it did not name is still unpaid'
);
select is(
  (select status from public.open_orders o join public.open_order_items i on i.order_id = o.id
   where i.id = 'cccccccc-cccc-4ccc-8ccc-cccccccccc02'),
  'open',
  'so the table stays open: it still owes for that row'
);
select is(
  (select count(*)::integer from public.sale_lines
   where sale_id = '88888888-8888-4888-8888-888888888803' and open_order_item_id is null),
  1,
  'the counter line of the mixed bill pays no order item'
);

-- Paying the last row settles the table, counter line or no counter line.
select is(
  public.record_sale(test_helpers.bill(
    '88888888-8888-4888-8888-888888888804', 4, '77777777-7777-4777-8777-777777777701',
    'dddddddd-dddd-4ddd-8ddd-dddddddddd01',
    array['cccccccc-cccc-4ccc-8ccc-cccccccccc02']::uuid[],
    array['55555555-5555-4555-8555-555555555505']::uuid[],
    array['Express'], array[1], array[1200]::bigint[]
  )) ->> 'status',
  'created',
  'the rest of the table is paid'
);
select is(
  (select status from public.open_orders o join public.open_order_items i on i.order_id = o.id
   where i.id = 'cccccccc-cccc-4ccc-8ccc-cccccccccc02'),
  'closed',
  'and the order closes with nothing unpaid left on it'
);

-- ---------------------------------------------------------------------------------------------
-- Naming an item without naming its table would settle a row nobody can see. It is refused.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select test_helpers.add('cccccccc-cccc-4ccc-8ccc-cccccccccc03',
  'dddddddd-dddd-4ddd-8ddd-dddddddddd02', '55555555-5555-4555-8555-555555555505', 1, 'phone-1');
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.bill(
    '88888888-8888-4888-8888-888888888805', 5, '77777777-7777-4777-8777-777777777701', null,
    array['cccccccc-cccc-4ccc-8ccc-cccccccccc03']::uuid[],
    array['55555555-5555-4555-8555-555555555505']::uuid[],
    array['Express'], array[1], array[1200]::bigint[]
  )) $$) -> 'detail',
  jsonb_build_object('line_no', 1, 'field', 'table_id'),
  'a line that pays an order item without naming the table is refused, naming the field'
);
select is(
  (select paid_sale_id from public.open_order_items where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccc03'),
  null,
  'and the row it named is untouched'
);
select is(
  (select last_seq from public.terminals where code = 'C1'),
  4::bigint,
  'the refused bill took no receipt number'
);

-- ---------------------------------------------------------------------------------------------
-- The room is the admin's.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select is(
  test_helpers.error_of($$ select public.save_dining_table(jsonb_build_object(
    'name', 'Terrasse 9', 'sort_order', 9, 'is_active', true)) $$) ->> 'message',
  'FORBIDDEN',
  'a waiter cannot add a table'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');
select is(
  public.save_dining_table(jsonb_build_object('name', '  Terrasse 9  ', 'sort_order', 9, 'is_active', true))
    - 'id',
  jsonb_build_object('name', 'Terrasse 9', 'sort_order', 9, 'is_active', true),
  'an admin adds a table, trimmed'
);
select is(
  test_helpers.error_of($$ select public.save_dining_table(jsonb_build_object(
    'name', '   ', 'sort_order', 9, 'is_active', true)) $$) -> 'detail',
  jsonb_build_object('field', 'name'),
  'a table with no name is refused, naming the field'
);
select is(
  test_helpers.error_of($$ select public.save_dining_table(jsonb_build_object(
    'id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd99', 'name', 'Nowhere', 'sort_order', 1, 'is_active', true)) $$) ->> 'message',
  'NOT_FOUND',
  'editing a table that does not exist is NOT_FOUND'
);

-- Retiring a table keeps it: a sale paid at it still says where it was paid.
select is(
  public.save_dining_table(jsonb_build_object(
    'id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01', 'name', 'Salle 1', 'sort_order', 1, 'is_active', false)),
  jsonb_build_object('id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01', 'name', 'Salle 1', 'sort_order', 1, 'is_active', false),
  'an admin renames and retires a table in one write'
);
select is(
  (select t.name from public.sales s join public.dining_tables t on t.id = s.table_id
   where s.id = '88888888-8888-4888-8888-888888888803'),
  'Salle 1',
  'the sale paid at it still names it, under the name it has now'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3');
select is(
  test_helpers.error_of($$ select test_helpers.add('cccccccc-cccc-4ccc-8ccc-cccccccccc04',
    'dddddddd-dddd-4ddd-8ddd-dddddddddd01', '55555555-5555-4555-8555-555555555505', 1, 'phone-1') $$),
  jsonb_build_object('code', 'PT409', 'message', 'TABLE_INACTIVE',
    'detail', jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01')),
  'a retired table takes nothing new'
);

-- ---------------------------------------------------------------------------------------------
-- The menu of the day belongs to the floor; the stock count does not.
select is(
  public.set_product_availability('55555555-5555-4555-8555-555555555505', false) ->> 'is_available',
  'false',
  'a waiter takes a dish off the menu'
);
select is(
  (select price_millimes from public.products where id = '55555555-5555-4555-8555-555555555505'),
  1200::bigint,
  'and changes nothing else about it'
);
select is(
  test_helpers.error_of($$ select public.adjust_stock(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'product_id', '55555555-5555-4555-8555-555555555501',
    'qty_delta', -3, 'reason', 'Counted', 'payload_hash', test_helpers.hash('adj-1'))) $$) ->> 'message',
  'FORBIDDEN',
  'but a waiter does not correct the stock count'
);
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');
select is(
  public.adjust_stock(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'product_id', '55555555-5555-4555-8555-555555555501',
    'qty_delta', -3, 'reason', 'Counted', 'payload_hash', test_helpers.hash('adj-1'))) ->> 'status',
  'created',
  'an admin does'
);
select is(
  public.adjust_stock(jsonb_build_object(
    'id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'product_id', '55555555-5555-4555-8555-555555555501',
    'qty_delta', -3, 'reason', 'Counted', 'payload_hash', test_helpers.hash('adj-1'))) ->> 'status',
  'replayed',
  'and the same correction arriving twice is counted once'
);

select * from finish();
rollback;
