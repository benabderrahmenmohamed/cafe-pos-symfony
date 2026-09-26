-- Malformed payloads: migration 20260926000017. A table that is neither in service nor retired, a sale
-- line too large to count and a void with a blank error code each reached a cast, an overflow or a
-- column's check, and came back as an error nobody raised: SERVER_ERROR, which a device retries for
-- ever. Each is VALIDATION_ERROR naming the field or the line, and leaves nothing behind.
begin;

create schema if not exists extensions;
create extension if not exists pgtap with schema extensions;
-- pgTAP is called by name, and part of each file calls it as the API's own role.
set local search_path = public, extensions;
grant usage on schema extensions to cafe_app;

select plan(14);

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

-- A counter sale of one line of Express, with the amounts given as they are rather than worked out
-- from each other: what is under test is a line whose amounts a register got wrong. Paid in cash,
-- exactly what the line says it comes to.
create function test_helpers.sale(p_id uuid, p_seq bigint, p_session uuid, p_qty integer, p_unit bigint, p_net bigint)
returns jsonb
language sql
as $$
  select jsonb_build_object(
    'id', p_id, 'kind', 'sale', 'terminal_code', 'C1', 'epoch', 0, 'seq', p_seq,
    'session_id', p_session, 'table_id', null,
    'created_at', '2026-09-26T13:00:00Z', 'payload_hash', test_helpers.hash(p_id::text),
    'lines', jsonb_build_array(jsonb_build_object(
      'id', md5(p_id::text || ':1')::uuid, 'line_no', 1, 'open_order_item_id', null,
      'product_id', '55555555-5555-4555-8555-555555555505', 'product_name', 'Express',
      'qty', p_qty, 'unit_price_millimes', p_unit,
      'line_discount_millimes', 0, 'allocated_discount_millimes', 0, 'net_millimes', p_net
    )),
    'cart_discount_millimes', 0,
    'total_millimes', p_net,
    'payment', jsonb_build_object('method', 'cash', 'tendered_millimes', p_net, 'change_millimes', 0)
  )
$$;

grant execute on all functions in schema test_helpers to cafe_app;

-- Seed ids
--   admin aaa…1, cashier aaa…2; terminal C1 at epoch 0 with no receipt printed yet
--   tables dddddddd-dddd-4ddd-8ddd-dddddddddd01 … 08, all in service
--   Express 55555555-…-555505

-- ---------------------------------------------------------------------------------------------
-- A table is in service or retired: true or false, or left out.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');

select is(
  test_helpers.error_of($$ select public.save_dining_table(jsonb_build_object(
    'name', 'Terrasse 9', 'sort_order', 9, 'is_active', 'maybe')) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('field', 'is_active')),
  'a table neither in service nor retired is VALIDATION_ERROR naming the field'
);
select is(
  test_helpers.error_of($$ select public.save_dining_table(jsonb_build_object(
    'name', 'Terrasse 9', 'sort_order', 9, 'is_active', 'yes')) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('field', 'is_active')),
  'and "yes" is text, not true, though a cast to boolean would have read it as true'
);
select is(
  test_helpers.error_of($$ select public.save_dining_table(jsonb_build_object(
    'id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd08', 'name', 'Comptoir', 'sort_order', 8, 'is_active', 2)) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('field', 'is_active')),
  'an edit is held to the same'
);
select is(
  (select count(*) from public.dining_tables
   where shop_id = '11111111-1111-4111-8111-111111111111' and name = 'Terrasse 9'),
  0::bigint,
  'the refused saves added no table'
);
select is(
  (select is_active from public.dining_tables where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd08'),
  true,
  'and the refused edit left its table in service'
);
select is(
  public.save_dining_table(jsonb_build_object('name', 'Terrasse 9', 'sort_order', 9)) -> 'is_active',
  'true'::jsonb,
  'a save that leaves is_active out still makes a table in service'
);

-- ---------------------------------------------------------------------------------------------
-- A line whose quantity times unit price is more than a bigint holds. The unit price is at the cap,
-- so this is the quantity alone: ten million.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');
select public.open_session(jsonb_build_object(
  'id', '77777777-7777-4777-8777-777777777701', 'terminal_code', 'C1', 'epoch', 0,
  'actor_user_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'opened_at', '2026-09-26T08:00:00Z',
  'opening_float_millimes', 50000, 'payload_hash', test_helpers.hash('open-1')
));

select is(
  test_helpers.error_of($$ select public.record_sale(test_helpers.sale(
    '88888888-8888-4888-8888-888888888801', 1, '77777777-7777-4777-8777-777777777701',
    10000000, 1000000000000, 1200)) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('line_no', 1)),
  'a line too large to count is VALIDATION_ERROR naming the line, not an overflow'
);
-- Well past what an integer holds, and within what a line may come to: it adds up, so it is a sale.
select is(
  public.record_sale(test_helpers.sale(
    '88888888-8888-4888-8888-888888888802', 1, '77777777-7777-4777-8777-777777777701',
    1000, 1000000000000, 1000000000000000)),
  jsonb_build_object('sale_id', '88888888-8888-4888-8888-888888888802', 'receipt_number', 'C1-1', 'status', 'created'),
  'a large line that adds up is recorded, under the number the refused one did not take'
);
select is(
  (select subtotal_millimes from public.sales where id = '88888888-8888-4888-8888-888888888802'),
  1000000000000000::bigint,
  'and its subtotal is the quantity times the unit price'
);

-- ---------------------------------------------------------------------------------------------
-- A void says which error the till was stuck on. The record names a session no terminal has, which
-- is why it can never be recorded.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');

select is(
  test_helpers.error_of($$ select public.void_receipt(jsonb_build_object(
    'record', test_helpers.sale('88888888-8888-4888-8888-888888888803', 2, '77777777-7777-4777-8777-777777777799', 1, 1200, 1200),
    'error_code', '',
    'reason', 'The session was gone when it arrived')) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('field', 'error_code')),
  'a void with a blank error code is VALIDATION_ERROR naming the field'
);
select is(
  test_helpers.error_of($$ select public.void_receipt(jsonb_build_object(
    'record', test_helpers.sale('88888888-8888-4888-8888-888888888803', 2, '77777777-7777-4777-8777-777777777799', 1, 1200, 1200),
    'error_code', '   ',
    'reason', 'The session was gone when it arrived')) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('field', 'error_code')),
  'and so is one of spaces'
);
select is(
  test_helpers.error_of($$ select public.void_receipt(jsonb_build_object(
    'record', test_helpers.sale('88888888-8888-4888-8888-888888888803', 2, '77777777-7777-4777-8777-777777777799', 1, 1200, 1200),
    'reason', 'The session was gone when it arrived')) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('field', 'error_code')),
  'and one with none at all, as it always was'
);
select is(
  public.void_receipt(jsonb_build_object(
    'record', test_helpers.sale('88888888-8888-4888-8888-888888888803', 2, '77777777-7777-4777-8777-777777777799', 1, 1200, 1200),
    'error_code', ' NOT_FOUND ',
    'reason', 'The session was gone when it arrived')) ->> 'receipt_number',
  'C1-2',
  'the refused voids burnt no number: the one that says why burns the next'
);
select is(
  (select error_code from public.receipt_voids where id = '88888888-8888-4888-8888-888888888803'),
  'NOT_FOUND',
  'and it keeps the code trimmed, as it keeps the reason'
);

select * from finish();
rollback;
