-- Table names: migration 20260913000014. Two tables of one café cannot share a name, and a save that
-- would give one the name of another says which field is wrong instead of failing on the constraint.
begin;

create schema if not exists extensions;
create extension if not exists pgtap with schema extensions;
-- pgTAP is called by name, and part of each file calls it as the API's own role.
set local search_path = public, extensions;
grant usage on schema extensions to cafe_app;

select plan(6);

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

-- The demo café's admin. Table 1 is dddddddd-…-01 and Terrasse 1 is dddddddd-…-05 (php bin/console app:seed-demo).
select test_helpers.login('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1');

select is(
  test_helpers.error_of($$ select public.save_dining_table(jsonb_build_object(
    'name', 'Terrasse 1', 'sort_order', 9, 'is_active', true)) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('field', 'name')),
  'a new table cannot take the name of one the café already has'
);
select is(
  test_helpers.error_of($$ select public.save_dining_table(jsonb_build_object(
    'id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd01', 'name', 'Terrasse 1', 'sort_order', 1, 'is_active', true)) $$),
  jsonb_build_object('code', 'PT422', 'message', 'VALIDATION_ERROR',
    'detail', jsonb_build_object('field', 'name')),
  'nor can a table be renamed to it'
);

-- What the refused saves left behind, as the admin reads the room.
select is(
  (select count(*) from public.dining_tables
   where shop_id = '11111111-1111-4111-8111-111111111111' and name = 'Terrasse 1'),
  1::bigint,
  'the refused saves added no second Terrasse 1'
);
select is(
  (select name from public.dining_tables where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd01'),
  'Table 1',
  'and the table that was to be renamed kept its name'
);
select is(
  public.save_dining_table(jsonb_build_object(
    'id', 'dddddddd-dddd-4ddd-8ddd-dddddddddd05', 'name', 'Terrasse 1', 'sort_order', 12, 'is_active', true))
    ->> 'sort_order',
  '12',
  'a table saved under its own name is not in its own way'
);

-- The other shop's admin: names are unique within a café, not across cafés.
select test_helpers.login('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1');
select is(
  public.save_dining_table(jsonb_build_object('name', 'Terrasse 1', 'sort_order', 2, 'is_active', true))
    ->> 'name',
  'Terrasse 1',
  'another café may have a Terrasse 1 of its own'
);

select * from finish();
rollback;
