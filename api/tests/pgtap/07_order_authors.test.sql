-- Who an order record credits: private.order_actor, migration 20260911000011. A phone passed from one
-- waiter to the next sends the first one's records under the second one's login, so a record names
-- its author as actor_user_id — a member of the caller's shop, stamped as added_by on the item an add
-- creates and as removed_by on what a removal or a cancel takes off. The login that sent a removal is
-- stamped beside it and shown by the report (migration 20260913000015). A record that names nobody was
-- queued before records named their author: its sender is credited.
begin;

create schema if not exists extensions;
create extension if not exists pgtap with schema extensions;
-- pgTAP is called by name, and part of each file calls it as the API's own role.
set local search_path = public, extensions;
grant usage on schema extensions to cafe_app;

select plan(11);

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

create function test_helpers.hash(p_seed text)
returns text
language sql
immutable
as $$ select md5(p_seed) || md5('salt' || p_seed) $$;

-- An order record as src/ports/orders.ts writes it: the fields of its kind inside the envelope, with
-- the author when the record names one.
create function test_helpers.record(p_id uuid, p_actor uuid, p_fields jsonb)
returns jsonb
language sql
as $$
  select jsonb_build_object(
      'id', p_id, 'device_id', 'phone-1', 'created_at', '2026-09-12T12:00:00Z',
      'payload_hash', test_helpers.hash(p_id::text)
    )
    || case when p_actor is null then '{}'::jsonb else jsonb_build_object('actor_user_id', p_actor) end
    || p_fields
$$;

-- What an item removed before migration 20260913000015 looks like: nobody wrote down who sent it.
-- Nobody may write to open_order_items, so these run as the test's own role.
create function test_helpers.forget_sender(p_item uuid)
returns void
language sql
security definer
as $$ update public.open_order_items set removal_submitted_by = null where id = p_item $$;

create function test_helpers.set_sender(p_item uuid, p_user uuid)
returns void
language sql
security definer
as $$ update public.open_order_items set removal_submitted_by = p_user where id = p_item $$;

-- The demo café (php bin/console app:seed-demo): the cashier aaa…2, the waiter aaa…3 and the owner aaa…5, who is
-- an admin and a cashier; the other shop's cashier bbb…2. Terrasse 2 is dddddddd-…-06 and Terrasse 3
-- dddddddd-…-07; the croissant is 55555555-…-10 and the express 55555555-…-05.

-- ---------------------------------------------------------------------------------------------
-- The owner signs in on the phone the waiter was using, and it sends what the waiter did.
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5');
select public.order_item_add(test_helpers.record(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
  jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd06',
    'product_id', '55555555-5555-4555-8555-555555555510', 'qty', 1, 'note', '')
));
select public.order_send(test_helpers.record(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
  jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd06')
));
select public.order_item_remove(test_helpers.record(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
  jsonb_build_object('item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'reason', 'Client parti')
));

select is(
  (select jsonb_build_object('added_by', i.added_by, 'removed_by', i.removed_by)
   from public.open_order_items i where i.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'),
  jsonb_build_object('added_by', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3', 'removed_by', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3'),
  'an item the waiter added and took off is the waiter''s, whoever sent the records'
);
select is(
  (select i.removal_submitted_by from public.open_order_items i where i.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'),
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5'::uuid,
  'and the item keeps the login the removal was sent under'
);

-- A cancel takes what is still on the table off in the name of whoever cancelled.
select public.order_item_add(test_helpers.record(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
  jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd06',
    'product_id', '55555555-5555-4555-8555-555555555505', 'qty', 2, 'note', '')
));
select public.order_send(test_helpers.record(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
  jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd06')
));
select public.order_cancel(test_helpers.record(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee06', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
  jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd06', 'reason', 'Les clients sont partis')
));

-- The period is around now(): removed_at is when the server took the removal.
select is(
  (select jsonb_agg(jsonb_build_object('item', r ->> 'item_id', 'by', r ->> 'removed_by_name',
      'sent', r ->> 'submitted_by_name') order by r ->> 'item_id')
   from jsonb_array_elements(public.removed_after_sent(now() - interval '1 hour', now() + interval '1 hour')) r),
  jsonb_build_array(
    jsonb_build_object('item', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'by', 'Demo Waiter', 'sent', 'Demo Owner'),
    jsonb_build_object('item', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04', 'by', 'Demo Cashier', 'sent', 'Demo Owner')
  ),
  'the report names the waiter who took one item off and the cashier who cancelled the rest, and the owner''s login that sent both'
);

-- An item taken off before the login was recorded: the report names its author and nobody else.
select test_helpers.forget_sender('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01');
select is(
  (select jsonb_build_object('by', r -> 'submitted_by', 'name', r -> 'submitted_by_name')
   from jsonb_array_elements(public.removed_after_sent(now() - interval '1 hour', now() + interval '1 hour')) r
   where r ->> 'item_id' = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'),
  jsonb_build_object('by', 'null'::jsonb, 'name', 'null'::jsonb),
  'a removal nobody recorded the login of is reported with none'
);

-- ---------------------------------------------------------------------------------------------
-- Only a member of the café can be credited, and a record that names nobody is its sender's.
select is(
  test_helpers.error_of($$ select public.order_item_add(test_helpers.record(
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee07', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',
    jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd07',
      'product_id', '55555555-5555-4555-8555-555555555510', 'qty', 1, 'note', ''))) $$),
  jsonb_build_object('code', 'PT403', 'message', 'FORBIDDEN',
    'detail', jsonb_build_object('actor_user_id', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2')),
  'an add in the name of another shop''s member is FORBIDDEN'
);
select is(
  (select count(*) from public.open_orders o where o.table_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd07'),
  0::bigint,
  'and opened no order on the table'
);

select public.order_item_add(test_helpers.record(
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee08', null,
  jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd07',
    'product_id', '55555555-5555-4555-8555-555555555510', 'qty', 1, 'note', '')
));
select is(
  (select i.added_by from public.open_order_items i where i.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee08'),
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5'::uuid,
  'a record that names nobody is credited to whoever sent it'
);

select is(
  test_helpers.error_of($$ select public.order_item_remove(test_helpers.record(
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee09', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',
    jsonb_build_object('item_id', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee08', 'reason', 'Erreur'))) $$) ->> 'message',
  'FORBIDDEN',
  'a removal in the name of another shop''s member is FORBIDDEN'
);
select is(
  test_helpers.error_of($$ select public.order_cancel(test_helpers.record(
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee10', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2',
    jsonb_build_object('table_id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd07', 'reason', 'Erreur'))) $$) ->> 'message',
  'FORBIDDEN',
  'and so is a cancel'
);
select ok(
  (select i.removed_at is null from public.open_order_items i where i.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee08'),
  'and the item is still on the table'
);
select is(
  test_helpers.error_of($$ select test_helpers.set_sender(
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee08', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5') $$) ->> 'code',
  '23514',
  'an item still on the table has no removal to have sent'
);

select * from finish();
rollback;
