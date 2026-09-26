-- save_product and the café model's product fields: migration 20260913000016. The form sends whether
-- a dish is on the menu and whether its stock is counted, and the product keeps both; a payload from
-- a client that sends neither leaves a new product on the menu and uncounted, and a saved one as it
-- was.
begin;

create schema if not exists extensions;
create extension if not exists pgtap with schema extensions;
-- pgTAP is called by name, and part of each file calls it as the API's own role.
set local search_path = public, extensions;
grant usage on schema extensions to cafe_app;

select plan(7);

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

-- The fields of a product as the form sends them, with `p_extra` on top.
create function test_helpers.product(p_name text, p_extra jsonb)
returns jsonb
language sql
as $$
  select jsonb_build_object(
    'name', p_name, 'price_millimes', 6750, 'category_id', null, 'barcode', '',
    'description', '', 'image_url', '', 'stock_delta', 0
  ) || p_extra
$$;

-- What each save answered, kept by label for the checks after it. Made before the login, by the
-- role running the tests, so it needs no privilege the signed-in role may lack.
create temporary table created (label text primary key, product jsonb) on commit drop;
grant all on created to cafe_app;

-- The demo café's admin (php bin/console app:seed-demo).
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');

insert into created values ('counted', public.save_product(test_helpers.product('Dattes de Tozeur',
  jsonb_build_object('is_available', false, 'track_stock', true, 'stock_delta', 12))));
select is(
  (select jsonb_build_object('is_available', product -> 'is_available', 'track_stock', product -> 'track_stock',
     'stock_qty', product -> 'stock_qty') from created where label = 'counted'),
  jsonb_build_object('is_available', false, 'track_stock', true, 'stock_qty', 12),
  'a new product keeps what the form said: off the menu, counted, with its opening stock'
);

insert into created values ('older client', public.save_product(test_helpers.product('Thé vert', '{}'::jsonb)));
select is(
  (select jsonb_build_object('is_available', product -> 'is_available', 'track_stock', product -> 'track_stock')
   from created where label = 'older client'),
  jsonb_build_object('is_available', true, 'track_stock', false),
  'a payload that says neither makes a product on the menu and not counted'
);

select is(
  public.save_product(test_helpers.product('Dattes de Tozeur', jsonb_build_object(
    'id', (select product ->> 'id' from created where label = 'counted'),
    'is_available', true, 'track_stock', false))) -> 'track_stock',
  'false'::jsonb,
  'an edit switches counting off'
);
select is(
  (select jsonb_build_object('is_available', p.is_available, 'track_stock', p.track_stock, 'stock_qty', p.stock_qty)
   from public.products p where p.id = (select (product ->> 'id')::uuid from created where label = 'counted')),
  jsonb_build_object('is_available', true, 'track_stock', false, 'stock_qty', 12),
  'and puts the dish back on the menu, leaving the stock it had'
);

select is(
  public.save_product(test_helpers.product('Dattes de Tozeur 1 kg', jsonb_build_object(
    'id', (select product ->> 'id' from created where label = 'counted'), 'track_stock', true))) -> 'is_available',
  'true'::jsonb,
  'an edit that leaves a field out keeps what the product had'
);

select is(
  test_helpers.error_of($$ select public.save_product(test_helpers.product('Citronnade',
    jsonb_build_object('track_stock', 'yes'))) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('field', 'track_stock')),
  'a field that is not true or false is VALIDATION_ERROR naming it'
);
select is(
  (select count(*) from public.products where name = 'Citronnade' and track_stock),
  0::bigint,
  'and saves nothing'
);

select * from finish();
rollback;
