-- The café's schema, for the Symfony server.
--
-- The café ran on Supabase first. This file is its sixteen migrations of that day, converted once,
-- with the three things that were Supabase's made this server's (the originals, and the script that
-- converted them, are in the history of the pos-admin-dashboard repository):
--
--   auth.users   -> public.users, written by this server (Symfony hashes the passwords)
--   auth.uid()   -> private.current_user_id(), read from `app.user_id`, which the API sets on the
--                   connection for the member making the request
--   authenticated/anon/service_role -> cafe_app, the one role the API connects as
--
-- What was left behind: the key-value import of the old app, the nightly demo reset, and the
-- Supabase Realtime publication. Row-level security stays exactly as it was: cafe_app reads only its
-- own shop's rows, and the ledger takes writes through its functions alone.
--
-- Doctrine has run this file on every database this server has had and will not run it again, so
-- nothing is ever added to it or changed in it: a change to the schema is the next migration.

create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'cafe_app') then
    create role cafe_app login password 'cafe_app';
  end if;
end;
$$;

create table public.users (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  password_hash text not null,
  created_at timestamptz not null default now(),
  constraint users_email_not_blank check (length(trim(email)) > 0)
);
create unique index users_email_key on public.users (lower(email));

alter table public.users enable row level security;
revoke all on public.users from public, cafe_app;


-- ---------------------------------------------------------------------------------------------
-- from 20260911000002_private_helpers.sql
-- Helpers shared by every RPC. The private schema is not exposed through the Data API; RPCs run as
-- their owner and call these directly.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to cafe_app;

-- Raises an error from the contract in contracts/errors.md. PostgREST turns SQLSTATE PTxyz into
-- HTTP status xyz and returns { code, message, details, hint }: `message` is the error code,
-- `details` a JSON object, `hint` a sentence for people.
create or replace function private.raise_error(p_code text, p_hint text, p_details jsonb default '{}'::jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_state text := case p_code
    when 'UNAUTHENTICATED' then 'PT401'
    when 'FORBIDDEN' then 'PT403'
    when 'NOT_FOUND' then 'PT404'
    when 'IDEMPOTENCY_CONFLICT' then 'PT409'
    when 'SEQUENCE_GAP' then 'PT409'
    when 'SESSION_CLOSED' then 'PT409'
    when 'SESSION_ALREADY_OPEN' then 'PT409'
    when 'TERMINAL_SUPERSEDED' then 'PT409'
    when 'VALIDATION_ERROR' then 'PT422'
  end;
begin
  if v_state is null then
    raise exception 'raise_error called with unknown code %', p_code;
  end if;
  raise exception using
    errcode = v_state,
    message = p_code,
    detail = coalesce(p_details, '{}'::jsonb)::text,
    hint = p_hint;
end;
$$;

-- Typed readers for RPC payloads. Each raises VALIDATION_ERROR naming the field instead of letting a
-- cast fail with an untyped database error.

create or replace function private.json_text(p jsonb, p_key text, p_required boolean default true)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v jsonb := p -> p_key;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if p_required then
      perform private.raise_error('VALIDATION_ERROR', format('%s is required.', p_key), jsonb_build_object('field', p_key));
    end if;
    return null;
  end if;
  if jsonb_typeof(v) <> 'string' then
    perform private.raise_error('VALIDATION_ERROR', format('%s must be text.', p_key), jsonb_build_object('field', p_key));
  end if;
  return v #>> '{}';
end;
$$;

create or replace function private.json_bigint(p jsonb, p_key text)
returns bigint
language plpgsql
stable
set search_path = ''
as $$
declare
  v jsonb := p -> p_key;
  n numeric;
begin
  if v is null or jsonb_typeof(v) <> 'number' then
    perform private.raise_error('VALIDATION_ERROR', format('%s must be a whole number.', p_key), jsonb_build_object('field', p_key));
  end if;
  n := (v #>> '{}')::numeric;
  if n <> trunc(n) or n < -9007199254740991 or n > 9007199254740991 then
    perform private.raise_error('VALIDATION_ERROR', format('%s must be a whole number.', p_key), jsonb_build_object('field', p_key));
  end if;
  return n::bigint;
end;
$$;

create or replace function private.json_int(p jsonb, p_key text)
returns integer
language plpgsql
stable
set search_path = ''
as $$
declare
  n bigint := private.json_bigint(p, p_key);
begin
  if n < -2147483648 or n > 2147483647 then
    perform private.raise_error('VALIDATION_ERROR', format('%s is out of range.', p_key), jsonb_build_object('field', p_key));
  end if;
  return n::integer;
end;
$$;

create or replace function private.json_uuid(p jsonb, p_key text, p_required boolean default true)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := private.json_text(p, p_key, p_required);
begin
  if v is null then
    return null;
  end if;
  begin
    return v::uuid;
  exception when invalid_text_representation then
    perform private.raise_error('VALIDATION_ERROR', format('%s must be a UUID.', p_key), jsonb_build_object('field', p_key));
  end;
  return null;
end;
$$;

-- Text as a UUID, or null when it is not one. For reading records that may be malformed (a voided
-- record); required payload fields go through json_uuid instead.
create or replace function private.try_uuid(p_value text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  return p_value::uuid;
exception when invalid_text_representation then
  return null;
end;
$$;

create or replace function private.json_timestamptz(p jsonb, p_key text)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := private.json_text(p, p_key);
begin
  begin
    return v::timestamptz;
  exception when invalid_datetime_format or datetime_field_overflow or invalid_text_representation then
    perform private.raise_error('VALIDATION_ERROR', format('%s must be an ISO 8601 timestamp.', p_key), jsonb_build_object('field', p_key));
  end;
  return null;
end;
$$;

-- The client computes payload_hash (SHA-256, lowercase hex) over the canonical payload without the
-- hash itself. The server stores and compares it; it never recomputes it.
create or replace function private.json_hash(p jsonb)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := private.json_text(p, 'payload_hash');
begin
  if v !~ '^[0-9a-f]{64}$' then
    perform private.raise_error('VALIDATION_ERROR', 'payload_hash must be 64 lowercase hex digits.', jsonb_build_object('field', 'payload_hash'));
  end if;
  return v;
end;
$$;

revoke all on all functions in schema private from public;
-- Who is making this request. The API sets `app.user_id` on the connection right after it has
-- checked the token; nothing else can read a row of another member's shop, whatever the code above
-- forgets. Null when the setting is missing, which is what every policy compares against.
create or replace function private.current_user_id()
returns uuid
language sql
stable
set search_path = ''
as $$ select nullif(current_setting('app.user_id', true), '')::uuid $$;


-- ---------------------------------------------------------------------------------------------
-- from 20260911000003_shops_and_profiles.sql
create table public.shops (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  created_at timestamptz not null default now()
);

-- Membership and role. Rows are created by seed.sql locally and by a documented SQL step in hosted
-- projects: never from user_metadata or app_metadata, and never by a signup trigger. A signed-in
-- user without a profile is denied everywhere.
create table public.profiles (
  user_id uuid primary key references public.users (id) on delete cascade,
  shop_id uuid not null references public.shops (id) on delete restrict,
  role text not null check (role in ('admin', 'cashier')),
  display_name text not null default '',
  created_at timestamptz not null default now()
);
create index profiles_shop_id_idx on public.profiles (shop_id);

-- Lookups used by row-level security. security definer so a policy on profiles does not recurse.
create or replace function private.current_shop_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.shop_id from public.profiles p where p.user_id = private.current_user_id()
$$;

create or replace function private.current_app_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p.role from public.profiles p where p.user_id = private.current_user_id()
$$;

-- The first statement of every RPC: no user is UNAUTHENTICATED, no profile or the wrong role is
-- FORBIDDEN.
create or replace function private.require_profile(p_roles text[] default array['admin', 'cashier'])
returns public.profiles
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
begin
  if private.current_user_id() is null then
    perform private.raise_error('UNAUTHENTICATED', 'Sign in to continue.');
  end if;
  select * into v_profile from public.profiles where user_id = private.current_user_id();
  if not found then
    perform private.raise_error('FORBIDDEN', 'This account is not a member of any shop.');
  end if;
  if not (v_profile.role = any (p_roles)) then
    perform private.raise_error('FORBIDDEN', 'Your role cannot do this.', jsonb_build_object('role', v_profile.role));
  end if;
  return v_profile;
end;
$$;

-- Records carry the person who did the work (an offline session may be replayed later under
-- someone else's login) as `actor_user_id`; that person must belong to the same shop. Returns the
-- person's user id.
create or replace function private.require_member(p_shop_id uuid, p jsonb)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.json_uuid(p, 'actor_user_id');
begin
  if not exists (select 1 from public.profiles pr where pr.user_id = v_user_id and pr.shop_id = p_shop_id) then
    perform private.raise_error(
      'FORBIDDEN',
      'The person on this record is not a member of your shop.',
      jsonb_build_object('actor_user_id', v_user_id)
    );
  end if;
  return v_user_id;
end;
$$;

-- The signed-in user's own profile, used by the web app after login to learn its role.
create or replace function public.my_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_email text;
begin
  v_profile := private.require_profile();
  select u.email into v_email from public.users u where u.id = v_profile.user_id;
  return jsonb_build_object(
    'user_id', v_profile.user_id,
    'shop_id', v_profile.shop_id,
    'role', v_profile.role,
    'display_name', v_profile.display_name,
    'email', coalesce(v_email, '')
  );
end;
$$;

revoke all on all functions in schema private from public;
-- ---------------------------------------------------------------------------------------------
-- from 20260911000004_catalog.sql
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default private.current_shop_id() references public.shops (id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  color text not null default '#3b82f6' check (color ~ '^#[0-9a-fA-F]{6}$'),
  legacy_kv_key text unique,
  created_at timestamptz not null default now(),
  unique (id, shop_id)
);
create index categories_shop_id_idx on public.categories (shop_id);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops (id) on delete restrict,
  category_id uuid,
  name text not null check (length(trim(name)) > 0),
  -- Up to one billion dinars: the same bound as MAX_PRICE_MILLIMES in src/ports/catalog.ts, so a
  -- price that is stored here always reads back through the port.
  price_millimes bigint not null check (price_millimes >= 0 and price_millimes <= 1000000000000),
  barcode text check (barcode is null or length(trim(barcode)) > 0),
  description text not null default '',
  image_url text not null default '',
  -- Changed only by private.move_stock, together with an append-only stock_movements row.
  stock integer not null default 0,
  available boolean not null default true,
  -- Products that appear on receipts are never deleted, only archived.
  archived_at timestamptz,
  legacy_kv_key text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, shop_id),
  foreign key (category_id, shop_id) references public.categories (id, shop_id) on delete set null (category_id)
);
create index products_shop_id_idx on public.products (shop_id);
create unique index products_shop_barcode_key on public.products (shop_id, barcode)
  where barcode is not null and archived_at is null;

-- Every stock change, append-only. products.stock always equals the sum of a product's deltas.
create table public.stock_movements (
  id bigint generated always as identity primary key,
  shop_id uuid not null,
  product_id uuid not null,
  delta integer not null check (delta <> 0),
  reason text not null check (reason in ('opening', 'adjustment', 'sale', 'refund')),
  sale_id uuid,
  note text not null default '',
  created_by uuid references public.users (id) on delete restrict,
  created_at timestamptz not null default now(),
  foreign key (product_id, shop_id) references public.products (id, shop_id) on delete restrict
);
create index stock_movements_product_id_idx on public.stock_movements (product_id);
create index stock_movements_sale_id_idx on public.stock_movements (sale_id) where sale_id is not null;

create table public.shop_settings (
  shop_id uuid primary key references public.shops (id) on delete cascade,
  receipt_footer text not null default 'Thank you for your purchase!' check (length(receipt_footer) <= 500),
  updated_at timestamptz not null default now()
);

create or replace function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger shop_settings_touch before update on public.shop_settings
  for each row execute function private.touch_updated_at();

-- The only writer of products.stock.
create or replace function private.move_stock(
  p_shop_id uuid,
  p_product_id uuid,
  p_delta integer,
  p_reason text,
  p_sale_id uuid,
  p_note text,
  p_actor uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stock integer;
begin
  if p_delta <> 0 then
    insert into public.stock_movements (shop_id, product_id, delta, reason, sale_id, note, created_by)
    values (p_shop_id, p_product_id, p_delta, p_reason, p_sale_id, coalesce(p_note, ''), p_actor);
    update public.products set stock = stock + p_delta
    where id = p_product_id and shop_id = p_shop_id
    returning stock into v_stock;
  else
    select stock into v_stock from public.products where id = p_product_id and shop_id = p_shop_id;
  end if;
  return v_stock;
end;
$$;

create or replace function private.product_json(v public.products)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', v.id,
    'name', v.name,
    'price_millimes', v.price_millimes,
    'category_id', v.category_id,
    'category_name', (select c.name from public.categories c where c.id = v.category_id),
    'barcode', coalesce(v.barcode, ''),
    'description', v.description,
    'image_url', v.image_url,
    'stock', v.stock,
    'available', v.available,
    'created_at', v.created_at,
    'updated_at', v.updated_at
  )
$$;

-- Creates (no id) or updates (id) a product. Stock changes only by `stock_delta`, written as an
-- 'opening' movement for a new product or an 'adjustment' for an existing one, in this transaction.
create or replace function public.save_product(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_name text;
  v_price bigint;
  v_category uuid;
  v_barcode text;
  v_description text;
  v_image_url text;
  v_delta integer;
  v_product public.products;
begin
  v_profile := private.require_profile(array['admin']);

  v_id := private.json_uuid(p, 'id', false);
  v_name := trim(private.json_text(p, 'name'));
  v_price := private.json_bigint(p, 'price_millimes');
  v_category := private.json_uuid(p, 'category_id', false);
  v_barcode := nullif(trim(coalesce(private.json_text(p, 'barcode', false), '')), '');
  v_description := coalesce(private.json_text(p, 'description', false), '');
  v_image_url := coalesce(private.json_text(p, 'image_url', false), '');
  v_delta := private.json_int(p, 'stock_delta');

  if v_name = '' then
    perform private.raise_error('VALIDATION_ERROR', 'Product name is required.', jsonb_build_object('field', 'name'));
  end if;
  if v_price < 0 then
    perform private.raise_error('VALIDATION_ERROR', 'Price cannot be negative.', jsonb_build_object('field', 'price_millimes'));
  end if;
  -- One billion dinars, the bound src/ports/catalog.ts reads rows back with.
  if v_price > 1000000000000 then
    perform private.raise_error('VALIDATION_ERROR', 'Price cannot be above one billion dinars.', jsonb_build_object('field', 'price_millimes'));
  end if;
  if v_category is not null and not exists (
    select 1 from public.categories c where c.id = v_category and c.shop_id = v_profile.shop_id
  ) then
    perform private.raise_error('VALIDATION_ERROR', 'The category does not exist.', jsonb_build_object('field', 'category_id'));
  end if;

  begin
    if v_id is null then
      if v_delta < 0 then
        perform private.raise_error('VALIDATION_ERROR', 'A new product cannot start with negative stock.', jsonb_build_object('field', 'stock_delta'));
      end if;
      insert into public.products (shop_id, category_id, name, price_millimes, barcode, description, image_url)
      values (v_profile.shop_id, v_category, v_name, v_price, v_barcode, v_description, v_image_url)
      returning * into v_product;
      perform private.move_stock(v_profile.shop_id, v_product.id, v_delta, 'opening', null, '', v_profile.user_id);
    else
      update public.products
      set category_id = v_category,
          name = v_name,
          price_millimes = v_price,
          barcode = v_barcode,
          description = v_description,
          image_url = v_image_url,
          updated_at = now()
      where id = v_id and shop_id = v_profile.shop_id and archived_at is null
      returning * into v_product;
      if not found then
        perform private.raise_error('NOT_FOUND', 'The product does not exist.', jsonb_build_object('product_id', v_id));
      end if;
      perform private.move_stock(v_profile.shop_id, v_product.id, v_delta, 'adjustment', null, '', v_profile.user_id);
    end if;
  exception when unique_violation then
    perform private.raise_error('VALIDATION_ERROR', 'Another product already uses this barcode.', jsonb_build_object('field', 'barcode'));
  end;

  select * into v_product from public.products where id = v_product.id;
  return private.product_json(v_product);
end;
$$;

-- Deleting a product archives it: sale lines keep pointing at it.
create or replace function public.archive_product(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
begin
  v_profile := private.require_profile(array['admin']);
  update public.products set archived_at = now(), updated_at = now()
  where id = p_product_id and shop_id = v_profile.shop_id and archived_at is null;
  if not found then
    perform private.raise_error('NOT_FOUND', 'The product does not exist.', jsonb_build_object('product_id', p_product_id));
  end if;
end;
$$;

revoke all on all functions in schema private from public;
-- ---------------------------------------------------------------------------------------------
-- from 20260911000005_terminals_and_sessions.sql
create table public.terminals (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops (id) on delete restrict,
  code text not null check (code ~ '^[A-Z0-9]{1,8}$'),
  -- The last receipt number used by this terminal, across sales, refunds and voided receipts.
  last_seq bigint not null default 0 check (last_seq >= 0),
  -- Bumped by every registration. A device holding an older epoch has been replaced.
  epoch integer not null default 0 check (epoch >= 0),
  created_at timestamptz not null default now(),
  unique (shop_id, code),
  unique (id, shop_id)
);

-- A session id is chosen by the device (it may open the session offline). Opening and closing are
-- idempotent: a replayed request with the same payload hash returns the stored outcome.
create table public.cash_sessions (
  id uuid primary key,
  shop_id uuid not null,
  terminal_id uuid not null,
  opened_by uuid not null references public.users (id) on delete restrict,
  open_submitted_by uuid not null references public.users (id) on delete restrict,
  opened_at timestamptz not null,
  open_received_at timestamptz not null default now(),
  opening_float_millimes bigint not null check (opening_float_millimes >= 0),
  open_payload_hash text not null check (open_payload_hash ~ '^[0-9a-f]{64}$'),
  close_request_id uuid unique,
  closed_at timestamptz,
  closed_by uuid references public.users (id) on delete restrict,
  close_submitted_by uuid references public.users (id) on delete restrict,
  close_received_at timestamptz,
  closing_counted_millimes bigint check (closing_counted_millimes >= 0),
  close_payload_hash text check (close_payload_hash ~ '^[0-9a-f]{64}$'),
  -- Set when an admin closes a session whose device lost its local state.
  force_close_reason text,
  server_z_report jsonb,
  client_z_report jsonb,
  unique (id, shop_id),
  foreign key (terminal_id, shop_id) references public.terminals (id, shop_id) on delete restrict,
  constraint cash_sessions_close_fields check (
    (
      closed_at is null and closed_by is null and close_submitted_by is null and close_received_at is null
      and closing_counted_millimes is null and close_payload_hash is null and close_request_id is null
      and force_close_reason is null and server_z_report is null
    )
    or (
      closed_at is not null and closed_by is not null and close_submitted_by is not null
      and close_received_at is not null and server_z_report is not null
      and (
        (force_close_reason is null and closing_counted_millimes is not null and close_payload_hash is not null and close_request_id is not null)
        or (force_close_reason is not null and closing_counted_millimes is null)
      )
    )
  )
);
create unique index cash_sessions_one_open_per_terminal on public.cash_sessions (terminal_id) where closed_at is null;
create index cash_sessions_shop_id_idx on public.cash_sessions (shop_id);

-- A closed session is final.
create or replace function private.reject_closed_session_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.closed_at is not null then
    raise exception using
      errcode = 'PT409',
      message = 'SESSION_CLOSED',
      detail = jsonb_build_object('session_id', old.id)::text,
      hint = 'A closed session cannot change.';
  end if;
  return new;
end;
$$;

create trigger cash_sessions_closed_are_final before update on public.cash_sessions
  for each row execute function private.reject_closed_session_update();

-- Locks the caller's terminal named in the payload. Every RPC that writes for a terminal takes this
-- lock first, before any other read, so concurrent and retried requests for one terminal run one at
-- a time and each later statement sees the committed result of the previous request.
create or replace function private.lock_terminal(p_shop_id uuid, p jsonb)
returns public.terminals
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text := private.json_text(p, 'terminal_code');
  v_terminal public.terminals;
begin
  select * into v_terminal from public.terminals where shop_id = p_shop_id and code = v_code for update;
  if not found then
    perform private.raise_error('FORBIDDEN', 'This terminal is not registered in your shop.', jsonb_build_object('terminal_code', v_code));
  end if;
  return v_terminal;
end;
$$;

create or replace function private.require_epoch(p_terminal public.terminals, p jsonb)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if private.json_int(p, 'epoch') <> p_terminal.epoch then
    perform private.raise_error(
      'TERMINAL_SUPERSEDED',
      'This terminal was registered again on another device. Register this device again.',
      jsonb_build_object('terminal_code', p_terminal.code, 'current_epoch', p_terminal.epoch)
    );
  end if;
end;
$$;

create or replace function private.session_json(v public.cash_sessions)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', v.id,
    'terminal_id', v.terminal_id,
    'terminal_code', (select t.code from public.terminals t where t.id = v.terminal_id),
    'opened_by', v.opened_by,
    'opened_at', v.opened_at,
    'opening_float_millimes', v.opening_float_millimes,
    'closed_at', v.closed_at,
    'closed_by', v.closed_by,
    'closing_counted_millimes', v.closing_counted_millimes,
    'force_close_reason', v.force_close_reason,
    'z_report', v.server_z_report
  )
$$;

-- The Z-report of a session. Documents belong to the session named on them (never grouped by
-- clock time). Refund totals are negative in the ledger and reported here as positive amounts.
--   gross    = sum of sale totals            refunds = -(sum of refund totals)     net = gross - refunds
--   expected_cash = opening float + cash sales - cash refunds
--   variance = counted - expected (null while the session is open)
create or replace function private.compute_z_report(p_session_id uuid, p_counted bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_session public.cash_sessions;
  v_report jsonb;
begin
  select * into v_session from public.cash_sessions where id = p_session_id;

  with totals as (
    select
      count(*) filter (where s.kind = 'sale') as sales_count,
      count(*) filter (where s.kind = 'refund') as refunds_count,
      coalesce(sum(s.total_millimes) filter (where s.kind = 'sale'), 0) as gross,
      coalesce(-sum(s.total_millimes) filter (where s.kind = 'refund'), 0) as refunds,
      coalesce(sum(s.total_millimes) filter (where s.kind = 'sale' and s.payment_method = 'cash'), 0) as cash_sales,
      coalesce(-sum(s.total_millimes) filter (where s.kind = 'refund' and s.payment_method = 'cash'), 0) as cash_refunds,
      coalesce(sum(s.total_millimes) filter (where s.kind = 'sale' and s.payment_method = 'card'), 0) as card_sales,
      coalesce(-sum(s.total_millimes) filter (where s.kind = 'refund' and s.payment_method = 'card'), 0) as card_refunds
    from public.sales s
    where s.session_id = p_session_id
  )
  select jsonb_build_object(
    'session_id', v_session.id,
    'opening_float_millimes', v_session.opening_float_millimes,
    'sales_count', t.sales_count,
    'refunds_count', t.refunds_count,
    'gross_millimes', t.gross,
    'refunds_millimes', t.refunds,
    'net_millimes', t.gross - t.refunds,
    'by_method', jsonb_build_object(
      'cash', jsonb_build_object('sales_millimes', t.cash_sales, 'refunds_millimes', t.cash_refunds, 'net_millimes', t.cash_sales - t.cash_refunds),
      'card', jsonb_build_object('sales_millimes', t.card_sales, 'refunds_millimes', t.card_refunds, 'net_millimes', t.card_sales - t.card_refunds)
    ),
    'expected_cash_millimes', v_session.opening_float_millimes + t.cash_sales - t.cash_refunds,
    'counted_cash_millimes', p_counted,
    'variance_millimes', case
      when p_counted is null then null
      else p_counted - (v_session.opening_float_millimes + t.cash_sales - t.cash_refunds)
    end,
    'voids_count', (select count(*) from public.receipt_voids rv where rv.session_id = p_session_id)
  )
  into v_report
  from totals t;

  return v_report;
end;
$$;

-- Admin-only. Creates the terminal on first use and bumps its epoch on every registration, so the
-- device registered last is the only one whose records are accepted. Returns the counter to adopt
-- and the terminal's open session, if any, which the new device continues.
create or replace function public.register_terminal(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_code text := upper(trim(coalesce(p_code, '')));
  v_terminal public.terminals;
  v_open public.cash_sessions;
begin
  v_profile := private.require_profile(array['admin']);
  if v_code !~ '^[A-Z0-9]{1,8}$' then
    perform private.raise_error('VALIDATION_ERROR', 'A terminal code is 1 to 8 letters or digits.', jsonb_build_object('field', 'code'));
  end if;

  insert into public.terminals as t (shop_id, code)
  values (v_profile.shop_id, v_code)
  on conflict (shop_id, code) do update set epoch = t.epoch + 1
  returning * into v_terminal;

  select * into v_open from public.cash_sessions where terminal_id = v_terminal.id and closed_at is null;

  return jsonb_build_object(
    'terminal_id', v_terminal.id,
    'code', v_terminal.code,
    'last_seq', v_terminal.last_seq,
    'epoch', v_terminal.epoch,
    'open_session', case when v_open.id is null then null else private.session_json(v_open) end
  );
end;
$$;

-- p = { id, terminal_code, epoch, actor_user_id, opened_at, opening_float_millimes, payload_hash }
-- Checks in the order of contracts/errors.md: caller, terminal lock, replay, epoch,
-- SESSION_ALREADY_OPEN, then the actor and the payload.
create or replace function public.open_session(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_terminal public.terminals;
  v_existing public.cash_sessions;
  v_actor uuid;
  v_float bigint;
  v_opened_at timestamptz;
  v_open_id uuid;
  v_constraint text;
begin
  v_profile := private.require_profile();
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  v_terminal := private.lock_terminal(v_profile.shop_id, p);

  select * into v_existing from public.cash_sessions where id = v_id;
  if found then
    if v_existing.shop_id <> v_profile.shop_id then
      perform private.raise_error('FORBIDDEN', 'This session belongs to another shop.');
    end if;
    if v_existing.open_payload_hash <> v_hash then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different session was already opened under this id.', jsonb_build_object('id', v_id));
    end if;
    return jsonb_build_object('session_id', v_id, 'status', 'replayed', 'session', private.session_json(v_existing));
  end if;

  perform private.require_epoch(v_terminal, p);

  select id into v_open_id from public.cash_sessions where terminal_id = v_terminal.id and closed_at is null;
  if v_open_id is not null then
    perform private.raise_error('SESSION_ALREADY_OPEN', 'This terminal already has an open session.', jsonb_build_object('open_session_id', v_open_id));
  end if;

  v_actor := private.require_member(v_profile.shop_id, p);
  v_float := private.json_bigint(p, 'opening_float_millimes');
  if v_float < 0 then
    perform private.raise_error('VALIDATION_ERROR', 'The opening float cannot be negative.', jsonb_build_object('field', 'opening_float_millimes'));
  end if;
  v_opened_at := private.json_timestamptz(p, 'opened_at');

  begin
    insert into public.cash_sessions (id, shop_id, terminal_id, opened_by, open_submitted_by, opened_at, opening_float_millimes, open_payload_hash)
    values (v_id, v_profile.shop_id, v_terminal.id, v_actor, v_profile.user_id, v_opened_at, v_float, v_hash)
    returning * into v_existing;
  exception when unique_violation then
    -- Another terminal stored a session under the same id after the replay check above.
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint in ('cash_sessions_pkey', 'cash_sessions_id_shop_id_key') then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different session was already opened under this id.', jsonb_build_object('id', v_id));
    end if;
    raise;
  end;

  return jsonb_build_object('session_id', v_id, 'status', 'created', 'session', private.session_json(v_existing));
end;
$$;

-- p = { id (the close request), session_id, terminal_code, epoch, actor_user_id, closed_at,
--       closing_counted_millimes, client_z_report, payload_hash }
-- Only the terminal that owns the session can close it, so every record that terminal queued for
-- the session has already been accepted by the time its close arrives. Checks in the order of
-- contracts/errors.md: caller, terminal lock, replay, epoch, session, then the actor and the payload.
create or replace function public.close_session(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_request uuid;
  v_hash text;
  v_terminal public.terminals;
  v_session_id uuid;
  v_session public.cash_sessions;
  v_actor uuid;
  v_counted bigint;
  v_client_report jsonb;
  v_closed_at timestamptz;
  v_report jsonb;
  v_constraint text;
begin
  v_profile := private.require_profile();
  v_request := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  v_terminal := private.lock_terminal(v_profile.shop_id, p);

  select * into v_session from public.cash_sessions where close_request_id = v_request;
  if found then
    if v_session.shop_id <> v_profile.shop_id then
      perform private.raise_error('FORBIDDEN', 'This session belongs to another shop.');
    end if;
    if v_session.close_payload_hash <> v_hash then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different close was already stored under this id.', jsonb_build_object('id', v_request));
    end if;
    return jsonb_build_object('session_id', v_session.id, 'status', 'replayed', 'z_report', v_session.server_z_report);
  end if;

  perform private.require_epoch(v_terminal, p);

  -- Read at the session step, so a session_id that is not a UUID cannot answer before the terminal,
  -- the replay and the epoch (contracts/errors.md, order of checks).
  v_session_id := private.json_uuid(p, 'session_id');
  select * into v_session from public.cash_sessions where id = v_session_id;
  if not found then
    perform private.raise_error('NOT_FOUND', 'The session does not exist.', jsonb_build_object('session_id', v_session_id));
  end if;
  if v_session.shop_id <> v_profile.shop_id or v_session.terminal_id <> v_terminal.id then
    perform private.raise_error('FORBIDDEN', 'Only the terminal that opened a session can close it.', jsonb_build_object('session_id', v_session.id));
  end if;
  if v_session.closed_at is not null then
    perform private.raise_error('SESSION_CLOSED', 'The session is already closed.', jsonb_build_object('session_id', v_session.id));
  end if;

  v_actor := private.require_member(v_profile.shop_id, p);
  v_counted := private.json_bigint(p, 'closing_counted_millimes');
  if v_counted < 0 then
    perform private.raise_error('VALIDATION_ERROR', 'Counted cash cannot be negative.', jsonb_build_object('field', 'closing_counted_millimes'));
  end if;
  v_client_report := p -> 'client_z_report';
  if v_client_report is not null and jsonb_typeof(v_client_report) not in ('object', 'null') then
    perform private.raise_error('VALIDATION_ERROR', 'client_z_report must be an object.', jsonb_build_object('field', 'client_z_report'));
  end if;
  v_closed_at := private.json_timestamptz(p, 'closed_at');

  v_report := private.compute_z_report(v_session.id, v_counted);

  begin
    update public.cash_sessions
    set close_request_id = v_request,
        closed_at = v_closed_at,
        closed_by = v_actor,
        close_submitted_by = v_profile.user_id,
        close_received_at = now(),
        closing_counted_millimes = v_counted,
        close_payload_hash = v_hash,
        server_z_report = v_report,
        client_z_report = nullif(v_client_report, 'null'::jsonb)
    where id = v_session.id;
  exception when unique_violation then
    -- Another terminal stored a close under the same request id after the replay check above.
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'cash_sessions_close_request_id_key' then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different close was already stored under this id.', jsonb_build_object('id', v_request));
    end if;
    raise;
  end;

  return jsonb_build_object('session_id', v_session.id, 'status', 'created', 'z_report', v_report);
end;
$$;

-- Admin-only escape hatch for a session left open by a device that lost its local state (its
-- records then surface as SESSION_ALREADY_OPEN). Counted cash stays unknown.
create or replace function public.force_close_session(p_session_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_session public.cash_sessions;
  v_report jsonb;
begin
  v_profile := private.require_profile(array['admin']);
  if trim(coalesce(p_reason, '')) = '' then
    perform private.raise_error('VALIDATION_ERROR', 'Say why the session is being closed.', jsonb_build_object('field', 'reason'));
  end if;

  select * into v_session from public.cash_sessions where id = p_session_id;
  if not found then
    perform private.raise_error('NOT_FOUND', 'The session does not exist.', jsonb_build_object('session_id', p_session_id));
  end if;
  if v_session.shop_id <> v_profile.shop_id then
    perform private.raise_error('FORBIDDEN', 'This session belongs to another shop.', jsonb_build_object('session_id', p_session_id));
  end if;
  perform 1 from public.terminals where id = v_session.terminal_id for update;
  select * into v_session from public.cash_sessions where id = p_session_id;
  if v_session.closed_at is not null then
    perform private.raise_error('SESSION_CLOSED', 'The session is already closed.', jsonb_build_object('session_id', p_session_id));
  end if;

  v_report := private.compute_z_report(v_session.id, null);
  update public.cash_sessions
  set closed_at = now(),
      closed_by = v_profile.user_id,
      close_submitted_by = v_profile.user_id,
      close_received_at = now(),
      force_close_reason = trim(p_reason),
      server_z_report = v_report
  where id = v_session.id;

  return jsonb_build_object('session_id', v_session.id, 'status', 'created', 'z_report', v_report);
end;
$$;

-- The stored report of a closed session, or the running report of an open one.
create or replace function public.z_report(p_session_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_session public.cash_sessions;
begin
  v_profile := private.require_profile();
  select * into v_session from public.cash_sessions where id = p_session_id;
  if not found then
    perform private.raise_error('NOT_FOUND', 'The session does not exist.', jsonb_build_object('session_id', p_session_id));
  end if;
  if v_session.shop_id <> v_profile.shop_id then
    perform private.raise_error('FORBIDDEN', 'This session belongs to another shop.', jsonb_build_object('session_id', p_session_id));
  end if;
  if v_session.closed_at is not null then
    return v_session.server_z_report;
  end if;
  return private.compute_z_report(v_session.id, null);
end;
$$;

revoke all on all functions in schema private from public;
-- ---------------------------------------------------------------------------------------------
-- from 20260911000006_sales_ledger.sql
-- The sales ledger. Rows are written only by record_sale and never updated or deleted: a refund is
-- a new document with negative quantities and amounts that points at the sale it refunds.
create table public.sales (
  id uuid primary key,
  shop_id uuid not null,
  terminal_id uuid not null,
  session_id uuid not null,
  kind text not null check (kind in ('sale', 'refund')),
  seq bigint not null check (seq > 0),
  receipt_number text not null,
  refunds_sale_id uuid references public.sales (id) on delete restrict,
  payment_method text not null check (payment_method in ('cash', 'card')),
  subtotal_millimes bigint not null,
  discount_millimes bigint not null check (discount_millimes >= 0),
  total_millimes bigint not null,
  tendered_millimes bigint not null,
  change_millimes bigint not null check (change_millimes >= 0),
  epoch integer not null,
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  submitted_by uuid not null references public.users (id) on delete restrict,
  -- Written by the device and not trusted for anything; received_at is the server's clock.
  created_at timestamptz not null,
  received_at timestamptz not null default now(),
  unique (terminal_id, seq),
  unique (id, shop_id),
  foreign key (terminal_id, shop_id) references public.terminals (id, shop_id) on delete restrict,
  foreign key (session_id, shop_id) references public.cash_sessions (id, shop_id) on delete restrict,
  constraint sales_totals check (
    total_millimes = subtotal_millimes - discount_millimes
    and tendered_millimes - change_millimes = total_millimes
  ),
  constraint sales_kind_shape check (
    (kind = 'sale' and refunds_sale_id is null and total_millimes >= 0)
    or (kind = 'refund' and refunds_sale_id is not null and total_millimes <= 0 and discount_millimes = 0 and change_millimes = 0)
  ),
  constraint sales_card_without_change check (payment_method = 'cash' or change_millimes = 0)
);
create index sales_session_id_idx on public.sales (session_id);
create index sales_shop_id_received_at_idx on public.sales (shop_id, received_at desc);
create index sales_refunds_sale_id_idx on public.sales (refunds_sale_id) where refunds_sale_id is not null;

create table public.sale_lines (
  sale_id uuid not null,
  shop_id uuid not null,
  line_no integer not null check (line_no >= 1),
  product_id uuid not null,
  -- What the receipt showed, kept even if the product is renamed later.
  product_name text not null,
  qty integer not null check (qty <> 0),
  -- A product price, so up to one billion dinars like products.price_millimes and
  -- MAX_PRICE_MILLIMES in src/ports/catalog.ts, which reads this column back.
  unit_price_millimes bigint not null check (unit_price_millimes >= 0 and unit_price_millimes <= 1000000000000),
  line_discount_millimes bigint not null check (line_discount_millimes >= 0),
  -- This line's part of the cart discount, allocated at sale time (largest remainder).
  cart_discount_share_millimes bigint not null check (cart_discount_share_millimes >= 0),
  -- qty x unit price less the discounts, so a large enough quantity is legitimately above the price
  -- cap: only the per-unit price is bounded. The same for the discounts and the document totals.
  line_total_millimes bigint not null,
  refunds_line_no integer,
  primary key (sale_id, line_no),
  foreign key (sale_id, shop_id) references public.sales (id, shop_id) on delete restrict,
  foreign key (product_id, shop_id) references public.products (id, shop_id) on delete restrict,
  constraint sale_lines_shape check (
    (
      qty > 0 and refunds_line_no is null
      and line_discount_millimes + cart_discount_share_millimes <= qty * unit_price_millimes
      and line_total_millimes = qty * unit_price_millimes - line_discount_millimes - cart_discount_share_millimes
    )
    or (
      qty < 0 and refunds_line_no is not null
      and line_discount_millimes = 0 and cart_discount_share_millimes = 0 and line_total_millimes <= 0
    )
  )
);
create index sale_lines_product_id_idx on public.sale_lines (product_id);

-- A numbered record that could never be accepted (for example a refund of more than was left,
-- recorded offline), voided by an admin so the terminal's numbering stays gapless and its queue can
-- move on. Every receipt number is either in sales or here, never both.
create table public.receipt_voids (
  id uuid primary key,
  shop_id uuid not null,
  terminal_id uuid not null,
  session_id uuid references public.cash_sessions (id) on delete restrict,
  seq bigint not null check (seq > 0),
  receipt_number text not null,
  payload jsonb not null,
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  error_code text not null check (length(trim(error_code)) > 0),
  reason text not null check (length(trim(reason)) > 0),
  voided_by uuid not null references public.users (id) on delete restrict,
  voided_at timestamptz not null default now(),
  unique (terminal_id, seq),
  foreign key (terminal_id, shop_id) references public.terminals (id, shop_id) on delete restrict
);
create index receipt_voids_session_id_idx on public.receipt_voids (session_id) where session_id is not null;

alter table public.stock_movements
  add constraint stock_movements_sale_id_fkey foreign key (sale_id) references public.sales (id) on delete restrict;

-- p = { id, kind, terminal_code, epoch, seq, session_id, created_at, payload_hash,
--       lines: [{ line_no, product_id, product_name, qty, unit_price_millimes, line_discount_millimes,
--                 cart_discount_share_millimes, line_total_millimes, refunds_line_no? }],
--       subtotal_millimes, discount_millimes, total_millimes,
--       payment: { method, tendered_millimes, change_millimes },
--       refunds_sale_id? }
-- Returns { sale_id, receipt_number, status: 'created' | 'replayed' | 'voided' }.
-- The order of checks is part of the contract (contracts/errors.md); a Spring service implementing
-- POST /api/v1/sales follows the same order in one READ COMMITTED transaction.
create or replace function public.record_sale(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_terminal public.terminals;
  v_found record;
  v_session_id uuid;
  v_session public.cash_sessions;
  v_seq bigint;
  v_receipt text;
  v_kind text;
  v_lines jsonb;
  v_line jsonb;
  v_line_no integer := 0;
  v_product_id uuid;
  v_qty integer;
  v_unit bigint;
  v_line_discount bigint;
  v_share bigint;
  v_line_total bigint;
  v_refunds_line_no integer;
  v_seen_refund_lines integer[] := '{}';
  v_subtotal bigint := 0;
  v_discount bigint := 0;
  v_total bigint := 0;
  v_refunds_sale_id uuid;
  v_original public.sales;
  v_original_line public.sale_lines;
  v_prior_units bigint;
  v_prior_amount bigint;
  v_payment jsonb;
  v_method text;
  v_tendered bigint;
  v_change bigint;
  v_created_at timestamptz;
  v_constraint text;
begin
  -- 1. Who is calling. No session is UNAUTHENTICATED; no shop membership is FORBIDDEN.
  v_profile := private.require_profile();
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  -- 2. Serialise all writes for this terminal before reading anything else.
  v_terminal := private.lock_terminal(v_profile.shop_id, p);

  -- 3. Idempotency: a record already recorded or voided returns its stored outcome.
  select s.shop_id, s.payload_hash, s.receipt_number into v_found from public.sales s where s.id = v_id;
  if found then
    if v_found.shop_id <> v_profile.shop_id then
      perform private.raise_error('FORBIDDEN', 'This record belongs to another shop.');
    end if;
    if v_found.payload_hash <> v_hash then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
    end if;
    return jsonb_build_object('sale_id', v_id, 'receipt_number', v_found.receipt_number, 'status', 'replayed');
  end if;

  select rv.shop_id, rv.payload_hash, rv.receipt_number into v_found from public.receipt_voids rv where rv.id = v_id;
  if found then
    if v_found.shop_id <> v_profile.shop_id then
      perform private.raise_error('FORBIDDEN', 'This record belongs to another shop.');
    end if;
    if v_found.payload_hash <> v_hash then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
    end if;
    return jsonb_build_object('sale_id', v_id, 'receipt_number', v_found.receipt_number, 'status', 'voided');
  end if;

  -- 4. The device holds the current registration.
  perform private.require_epoch(v_terminal, p);

  -- 5. The session exists, is open and belongs to this terminal.
  v_session_id := private.json_uuid(p, 'session_id');
  select * into v_session from public.cash_sessions where id = v_session_id;
  if not found then
    perform private.raise_error('NOT_FOUND', 'The session does not exist.', jsonb_build_object('session_id', v_session_id));
  end if;
  if v_session.shop_id <> v_profile.shop_id or v_session.terminal_id <> v_terminal.id then
    perform private.raise_error('FORBIDDEN', 'The session does not belong to this terminal.', jsonb_build_object('session_id', v_session_id));
  end if;
  if v_session.closed_at is not null then
    perform private.raise_error('SESSION_CLOSED', 'The session was closed before this record arrived.', jsonb_build_object('session_id', v_session_id));
  end if;

  -- 6. Gapless numbering: exactly the next number of this terminal.
  v_seq := private.json_bigint(p, 'seq');
  if v_seq <> v_terminal.last_seq + 1 then
    perform private.raise_error(
      'SEQUENCE_GAP',
      format('Expected receipt %s-%s.', v_terminal.code, v_terminal.last_seq + 1),
      jsonb_build_object('expected_seq', v_terminal.last_seq + 1, 'received_seq', v_seq)
    );
  end if;
  v_receipt := v_terminal.code || '-' || v_seq;

  -- 7. The document: every amount is recomputed from the lines.
  v_kind := private.json_text(p, 'kind');
  if v_kind not in ('sale', 'refund') then
    perform private.raise_error('VALIDATION_ERROR', 'kind must be sale or refund.', jsonb_build_object('field', 'kind'));
  end if;

  v_lines := p -> 'lines';
  if v_lines is null or jsonb_typeof(v_lines) <> 'array' or jsonb_array_length(v_lines) = 0 then
    perform private.raise_error('VALIDATION_ERROR', 'A record needs at least one line.', jsonb_build_object('field', 'lines'));
  end if;

  if v_kind = 'refund' then
    v_refunds_sale_id := private.json_uuid(p, 'refunds_sale_id');
    -- Refunds of one sale can arrive from several terminals: take them one at a time, and sum the
    -- earlier refunds only after holding the lock.
    perform pg_advisory_xact_lock(hashtextextended(v_refunds_sale_id::text, 0));
    select * into v_original from public.sales where id = v_refunds_sale_id and shop_id = v_profile.shop_id;
    if not found then
      perform private.raise_error('NOT_FOUND', 'The sale to refund does not exist.', jsonb_build_object('sale_id', v_refunds_sale_id));
    end if;
    if v_original.kind <> 'sale' then
      perform private.raise_error('VALIDATION_ERROR', 'Only a sale can be refunded, not a refund.', jsonb_build_object('field', 'refunds_sale_id'));
    end if;
  elsif p ? 'refunds_sale_id' and jsonb_typeof(p -> 'refunds_sale_id') <> 'null' then
    perform private.raise_error('VALIDATION_ERROR', 'Only a refund names a sale to refund.', jsonb_build_object('field', 'refunds_sale_id'));
  end if;

  for v_line in select e.value from jsonb_array_elements(v_lines) e
  loop
    v_line_no := v_line_no + 1;
    if jsonb_typeof(v_line) <> 'object' or private.json_int(v_line, 'line_no') <> v_line_no then
      perform private.raise_error('VALIDATION_ERROR', 'Lines must be numbered 1, 2, 3 in order.', jsonb_build_object('field', 'lines'));
    end if;
    v_product_id := private.json_uuid(v_line, 'product_id');
    perform private.json_text(v_line, 'product_name');
    v_qty := private.json_int(v_line, 'qty');
    v_unit := private.json_bigint(v_line, 'unit_price_millimes');
    v_line_discount := private.json_bigint(v_line, 'line_discount_millimes');
    v_share := private.json_bigint(v_line, 'cart_discount_share_millimes');
    v_line_total := private.json_bigint(v_line, 'line_total_millimes');

    -- Archived products can still be sold offline and refunded.
    if not exists (select 1 from public.products pr where pr.id = v_product_id and pr.shop_id = v_profile.shop_id) then
      perform private.raise_error('NOT_FOUND', 'A line names a product that does not exist.', jsonb_build_object('product_id', v_product_id));
    end if;

    -- A unit price is a product price: at most one billion dinars, the bound
    -- src/ports/catalog.ts reads products and sale lines back with. The line total is qty x unit
    -- price, so it is not bounded the same way, and neither are the discounts or the totals.
    if v_unit > 1000000000000 then
      perform private.raise_error('VALIDATION_ERROR', 'A unit price cannot be above one billion dinars.', jsonb_build_object('line_no', v_line_no));
    end if;

    if v_kind = 'sale' then
      if v_line ? 'refunds_line_no' and jsonb_typeof(v_line -> 'refunds_line_no') <> 'null' then
        perform private.raise_error('VALIDATION_ERROR', 'A sale line cannot refund another line.', jsonb_build_object('line_no', v_line_no));
      end if;
      if v_qty < 1 or v_unit < 0 or v_line_discount < 0 or v_share < 0
         or v_line_discount + v_share > v_qty * v_unit
         or v_line_total <> v_qty * v_unit - v_line_discount - v_share then
        perform private.raise_error('VALIDATION_ERROR', 'Line amounts do not add up.', jsonb_build_object('line_no', v_line_no));
      end if;
      v_subtotal := v_subtotal + v_qty * v_unit - v_line_discount;
      v_discount := v_discount + v_share;
    else
      v_refunds_line_no := private.json_int(v_line, 'refunds_line_no');
      if v_refunds_line_no = any (v_seen_refund_lines) then
        perform private.raise_error('VALIDATION_ERROR', 'An original line can appear only once in a refund.', jsonb_build_object('line_no', v_line_no));
      end if;
      v_seen_refund_lines := v_seen_refund_lines || v_refunds_line_no;

      select * into v_original_line from public.sale_lines where sale_id = v_original.id and line_no = v_refunds_line_no;
      if not found then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line names a line that is not on the sale.', jsonb_build_object('line_no', v_line_no));
      end if;
      if v_product_id <> v_original_line.product_id or v_unit <> v_original_line.unit_price_millimes
         or v_line_discount <> 0 or v_share <> 0 or v_qty > -1 or v_line_total > 0 then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line must match its sale line, with a negative quantity and amount.', jsonb_build_object('line_no', v_line_no));
      end if;

      select coalesce(sum(-sl.qty), 0), coalesce(sum(-sl.line_total_millimes), 0)
      into v_prior_units, v_prior_amount
      from public.sale_lines sl
      join public.sales s on s.id = sl.sale_id
      where s.refunds_sale_id = v_original.id and sl.refunds_line_no = v_refunds_line_no;

      -- Units and amount stay within what is left, and the refund that takes a line's last units
      -- pays exactly what is left of it, so the parts of a line always add up to its total.
      if v_prior_units - v_qty > v_original_line.qty
         or v_prior_amount - v_line_total > v_original_line.line_total_millimes then
        perform private.raise_error(
          'VALIDATION_ERROR',
          'The refund is more than what is left to refund on this line.',
          jsonb_build_object(
            'line_no', v_line_no,
            'remaining_qty', v_original_line.qty - v_prior_units,
            'remaining_millimes', v_original_line.line_total_millimes - v_prior_amount
          )
        );
      end if;
      if v_prior_units - v_qty = v_original_line.qty
         and v_prior_amount - v_line_total <> v_original_line.line_total_millimes then
        perform private.raise_error(
          'VALIDATION_ERROR',
          'A refund of the last units of a line pays exactly what is left of it.',
          jsonb_build_object(
            'line_no', v_line_no,
            'remaining_qty', v_original_line.qty - v_prior_units,
            'remaining_millimes', v_original_line.line_total_millimes - v_prior_amount
          )
        );
      end if;
      v_subtotal := v_subtotal + v_line_total;
    end if;
    v_total := v_total + v_line_total;
  end loop;

  if private.json_bigint(p, 'subtotal_millimes') <> v_subtotal
     or private.json_bigint(p, 'discount_millimes') <> v_discount
     or private.json_bigint(p, 'total_millimes') <> v_total then
    perform private.raise_error(
      'VALIDATION_ERROR',
      'The document totals do not match its lines.',
      jsonb_build_object('subtotal_millimes', v_subtotal, 'discount_millimes', v_discount, 'total_millimes', v_total)
    );
  end if;

  -- Payment. Change only exists for cash; a refund pays out exactly its total.
  v_payment := p -> 'payment';
  if v_payment is null or jsonb_typeof(v_payment) <> 'object' then
    perform private.raise_error('VALIDATION_ERROR', 'payment is required.', jsonb_build_object('field', 'payment'));
  end if;
  v_method := private.json_text(v_payment, 'method');
  v_tendered := private.json_bigint(v_payment, 'tendered_millimes');
  v_change := private.json_bigint(v_payment, 'change_millimes');
  if v_method not in ('cash', 'card') then
    perform private.raise_error('VALIDATION_ERROR', 'The payment method must be cash or card.', jsonb_build_object('field', 'payment.method'));
  end if;
  if v_kind = 'refund' or v_method = 'card' then
    if v_tendered <> v_total or v_change <> 0 then
      perform private.raise_error('VALIDATION_ERROR', 'Card payments and refunds are exactly the total, with no change.', jsonb_build_object('field', 'payment'));
    end if;
  elsif v_tendered < v_total or v_change <> v_tendered - v_total then
    perform private.raise_error('VALIDATION_ERROR', 'Change must be the amount tendered minus the total.', jsonb_build_object('field', 'payment'));
  end if;

  v_created_at := private.json_timestamptz(p, 'created_at');

  -- 8. Write. Products are locked in id order so two terminals never deadlock on stock.
  perform 1
  from public.products pr
  where pr.shop_id = v_profile.shop_id
    and pr.id in (select (e.value ->> 'product_id')::uuid from jsonb_array_elements(v_lines) e)
  order by pr.id
  for update;

  begin
    insert into public.sales (
      id, shop_id, terminal_id, session_id, kind, seq, receipt_number, refunds_sale_id, payment_method,
      subtotal_millimes, discount_millimes, total_millimes, tendered_millimes, change_millimes,
      epoch, payload_hash, submitted_by, created_at
    )
    values (
      v_id, v_profile.shop_id, v_terminal.id, v_session.id, v_kind, v_seq, v_receipt, v_refunds_sale_id, v_method,
      v_subtotal, v_discount, v_total, v_tendered, v_change,
      v_terminal.epoch, v_hash, v_profile.user_id, v_created_at
    );
  exception when unique_violation then
    -- Another terminal stored a record under the same id after the idempotency check above.
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint in ('sales_pkey', 'sales_id_shop_id_key') then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
    end if;
    raise;
  end;

  for v_line in select e.value from jsonb_array_elements(v_lines) e
  loop
    v_qty := (v_line ->> 'qty')::integer;
    v_product_id := (v_line ->> 'product_id')::uuid;
    insert into public.sale_lines (
      sale_id, shop_id, line_no, product_id, product_name, qty, unit_price_millimes,
      line_discount_millimes, cart_discount_share_millimes, line_total_millimes, refunds_line_no
    )
    values (
      v_id, v_profile.shop_id, (v_line ->> 'line_no')::integer, v_product_id, v_line ->> 'product_name', v_qty,
      (v_line ->> 'unit_price_millimes')::bigint, (v_line ->> 'line_discount_millimes')::bigint,
      (v_line ->> 'cart_discount_share_millimes')::bigint, (v_line ->> 'line_total_millimes')::bigint,
      (v_line ->> 'refunds_line_no')::integer
    );
    -- A sale takes units out of stock; a refund puts them back. Stock may go negative: a sale that
    -- happened is never refused for stock.
    perform private.move_stock(
      v_profile.shop_id, v_product_id, -v_qty,
      case when v_kind = 'sale' then 'sale' else 'refund' end,
      v_id, '', v_profile.user_id
    );
  end loop;

  update public.terminals set last_seq = v_seq where id = v_terminal.id;

  return jsonb_build_object('sale_id', v_id, 'receipt_number', v_receipt, 'status', 'created');
end;
$$;

-- p = { record: <the numbered record exactly as queued>, error_code, reason }
-- Admin-only and audited. Voids the terminal's next receipt number so the queue behind it can
-- drain. The same record (same id and hash) that did reach the ledger comes back as 'recorded'
-- instead; another record stored under that id is IDEMPOTENCY_CONFLICT.
create or replace function public.void_receipt(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_record jsonb := p -> 'record';
  v_id uuid;
  v_hash text;
  v_reason text;
  v_error_code text;
  v_terminal public.terminals;
  v_found record;
  v_seq bigint;
  v_receipt text;
  v_session_id uuid;
  v_constraint text;
begin
  v_profile := private.require_profile(array['admin']);
  if v_record is null or jsonb_typeof(v_record) <> 'object' then
    perform private.raise_error('VALIDATION_ERROR', 'record is required.', jsonb_build_object('field', 'record'));
  end if;
  v_id := private.json_uuid(v_record, 'id');
  v_hash := private.json_hash(v_record);
  v_error_code := private.json_text(p, 'error_code');
  v_reason := trim(private.json_text(p, 'reason'));
  if v_reason = '' then
    perform private.raise_error('VALIDATION_ERROR', 'Say why this receipt is being voided.', jsonb_build_object('field', 'reason'));
  end if;

  v_terminal := private.lock_terminal(v_profile.shop_id, v_record);

  select s.shop_id, s.payload_hash, s.receipt_number into v_found from public.sales s where s.id = v_id;
  if found then
    if v_found.shop_id <> v_profile.shop_id then
      perform private.raise_error('FORBIDDEN', 'This record belongs to another shop.');
    end if;
    if v_found.payload_hash <> v_hash then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
    end if;
    return jsonb_build_object('sale_id', v_id, 'receipt_number', v_found.receipt_number, 'status', 'recorded');
  end if;

  select rv.shop_id, rv.receipt_number, rv.payload_hash into v_found from public.receipt_voids rv where rv.id = v_id;
  if found then
    if v_found.shop_id <> v_profile.shop_id then
      perform private.raise_error('FORBIDDEN', 'This record belongs to another shop.');
    end if;
    if v_found.payload_hash <> v_hash then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already voided under this id.', jsonb_build_object('id', v_id));
    end if;
    return jsonb_build_object('sale_id', v_id, 'receipt_number', v_found.receipt_number, 'status', 'replayed');
  end if;

  v_seq := private.json_bigint(v_record, 'seq');
  if v_seq <> v_terminal.last_seq + 1 then
    perform private.raise_error(
      'SEQUENCE_GAP',
      format('Receipts are voided in order: the next one is %s-%s.', v_terminal.code, v_terminal.last_seq + 1),
      jsonb_build_object('expected_seq', v_terminal.last_seq + 1, 'received_seq', v_seq)
    );
  end if;
  v_receipt := v_terminal.code || '-' || v_seq;

  -- The record may be malformed (that can be why it is voided): a session id that is not a UUID of
  -- this terminal's sessions leaves the void without a session.
  v_session_id := private.try_uuid(v_record ->> 'session_id');
  select cs.id into v_session_id
  from public.cash_sessions cs
  where cs.id = v_session_id and cs.terminal_id = v_terminal.id;

  begin
    insert into public.receipt_voids (id, shop_id, terminal_id, session_id, seq, receipt_number, payload, payload_hash, error_code, reason, voided_by)
    values (v_id, v_profile.shop_id, v_terminal.id, v_session_id, v_seq, v_receipt, v_record, v_hash, v_error_code, v_reason, v_profile.user_id);
  exception when unique_violation then
    -- Another terminal voided a record under the same id after the checks above.
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'receipt_voids_pkey' then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already voided under this id.', jsonb_build_object('id', v_id));
    end if;
    raise;
  end;

  update public.terminals set last_seq = v_seq where id = v_terminal.id;

  return jsonb_build_object('sale_id', v_id, 'receipt_number', v_receipt, 'status', 'voided');
end;
$$;
-- ---------------------------------------------------------------------------------------------
-- from 20260911000008_rls_and_grants.sql
-- Row-level security and privileges, kept together so they can be reviewed in one place.
--
-- Members of a shop read that shop's rows. The write paths are the security definer RPCs plus three
-- plain catalog edits: add a category, delete a category, change the receipt footer. Sales, sale
-- lines, stock movements, sessions, terminals and voids have no client INSERT, UPDATE or DELETE
-- privilege at all, so nothing but record_sale and friends can change them.
--
-- The ledger (sales, sale_lines, stock_movements, receipt_voids) is append-only for every role: the
-- service role has no INSERT, UPDATE, DELETE or TRUNCATE on it either, and triggers refuse UPDATE,
-- DELETE and TRUNCATE for the roles that keep their privileges (the owner and superusers).

alter table public.shops enable row level security;
alter table public.profiles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.stock_movements enable row level security;
alter table public.shop_settings enable row level security;
alter table public.terminals enable row level security;
alter table public.cash_sessions enable row level security;
alter table public.sales enable row level security;
alter table public.sale_lines enable row level security;
alter table public.receipt_voids enable row level security;

revoke all on
  public.shops, public.profiles, public.categories, public.products, public.stock_movements,
  public.shop_settings, public.terminals, public.cash_sessions, public.sales, public.sale_lines,
  public.receipt_voids
from public, cafe_app;

grant select on
  public.shops, public.profiles, public.categories, public.products, public.stock_movements,
  public.shop_settings, public.terminals, public.cash_sessions, public.sales, public.sale_lines,
  public.receipt_voids
to cafe_app;

grant insert (name, color) on public.categories to cafe_app;
grant delete on public.categories to cafe_app;
grant update (receipt_footer) on public.shop_settings to cafe_app;

revoke all on sequence public.stock_movements_id_seq from public, cafe_app;

-- The service role keeps SELECT (tests and support read the ledger with it) but cannot write it.
revoke insert, update, delete, truncate on
  public.sales, public.sale_lines, public.stock_movements, public.receipt_voids
from public;

-- The last guard, for the roles that keep their privileges on the ledger: the owner (migrations,
-- the SQL editor) and superusers. A row is never updated or deleted and a table is never truncated,
-- unless the transaction first runs
--
--   set local pos.ledger_maintenance = 'on';
--
-- That switch is reserved for the Phase 5 reset of the demo shop, a scheduled job that runs as the
-- owner. It grants nothing by itself: API roles (anon, authenticated, service_role) have no UPDATE,
-- DELETE or TRUNCATE privilege on these tables, so setting it changes nothing for them. It guards
-- against mistakes, not against a superuser, who can still turn triggers off.
create or replace function private.reject_ledger_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('pos.ledger_maintenance', true) = 'on' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    -- UPDATE continues with the new row; the value is ignored for TRUNCATE.
    return new;
  end if;
  raise exception using
    errcode = 'PT403',
    message = 'FORBIDDEN',
    detail = '{}',
    hint = format('The ledger is append-only: rows of %s.%s are never updated, deleted or truncated.', tg_table_schema, tg_table_name);
end;
$$;

create trigger sales_append_only before update or delete on public.sales
  for each row execute function private.reject_ledger_change();
create trigger sales_no_truncate before truncate on public.sales
  for each statement execute function private.reject_ledger_change();

create trigger sale_lines_append_only before update or delete on public.sale_lines
  for each row execute function private.reject_ledger_change();
create trigger sale_lines_no_truncate before truncate on public.sale_lines
  for each statement execute function private.reject_ledger_change();

create trigger stock_movements_append_only before update or delete on public.stock_movements
  for each row execute function private.reject_ledger_change();
create trigger stock_movements_no_truncate before truncate on public.stock_movements
  for each statement execute function private.reject_ledger_change();

create trigger receipt_voids_append_only before update or delete on public.receipt_voids
  for each row execute function private.reject_ledger_change();
create trigger receipt_voids_no_truncate before truncate on public.receipt_voids
  for each statement execute function private.reject_ledger_change();

create policy shops_select on public.shops
  for select to cafe_app
  using (id = (select private.current_shop_id()));

create policy profiles_select on public.profiles
  for select to cafe_app
  using (
    shop_id = (select private.current_shop_id())
    and (user_id = (select private.current_user_id()) or (select private.current_app_role()) = 'admin')
  );

create policy categories_select on public.categories
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy categories_insert on public.categories
  for insert to cafe_app
  with check (shop_id = (select private.current_shop_id()) and (select private.current_app_role()) = 'admin');

create policy categories_delete on public.categories
  for delete to cafe_app
  using (shop_id = (select private.current_shop_id()) and (select private.current_app_role()) = 'admin');

create policy products_select on public.products
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy stock_movements_select on public.stock_movements
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy shop_settings_select on public.shop_settings
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy shop_settings_update on public.shop_settings
  for update to cafe_app
  using (shop_id = (select private.current_shop_id()) and (select private.current_app_role()) = 'admin')
  with check (shop_id = (select private.current_shop_id()));

create policy terminals_select on public.terminals
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy cash_sessions_select on public.cash_sessions
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy sales_select on public.sales
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy sale_lines_select on public.sale_lines
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy receipt_voids_select on public.receipt_voids
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

-- Functions. Postgres grants EXECUTE to PUBLIC by default, so revoke from PUBLIC as well as anon;
-- then members get exactly the RPCs.
revoke all on all functions in schema public from public;
grant execute on function
  public.my_profile(),
  public.save_product(jsonb),
  public.archive_product(uuid),
  public.register_terminal(text),
  public.open_session(jsonb),
  public.close_session(jsonb),
  public.force_close_session(uuid, text),
  public.z_report(uuid),
  public.record_sale(jsonb),
  public.void_receipt(jsonb)
to cafe_app;

-- Functions created later in public by the migration role no longer get Supabase's per-schema
-- EXECUTE grant to anon. PUBLIC's EXECUTE on new functions is a global default, which a per-schema
-- statement cannot take away, so a later migration that adds a function to public must still
-- revoke it from public and anon itself, as the statement above does for today's functions.
alter default privileges in schema public revoke execute on functions from public;

revoke all on all functions in schema private from public;
-- Row-level security policies and the categories.shop_id default call these as the querying user.
grant execute on function private.current_shop_id(), private.current_app_role() to cafe_app;
-- ---------------------------------------------------------------------------------------------
-- from 20260911000010_cafe_schema.sql
-- The café model (docs/spec.md v3): four roles, dining tables, open orders as working state, a
-- kitchen, and payment against order items.
--
-- Migrations 1-9 built a counter-service shop: one role per member, a product with a single `stock`
-- column, and a sale that named products directly. This migration reshapes those tables and adds
-- the three new ones. Nothing here is dropped that a receipt points at: the ledger keeps every row
-- it had, and the columns that moved were renamed, never re-created, so no history is lost.

-- ---------------------------------------------------------------------------------------------
-- Roles. A member holds several: the owner is an admin who also works the counter, so roles is an
-- array and every check asks "does this member hold any of these roles".
alter table public.profiles add column roles text[];
update public.profiles set roles = array[role];
alter table public.profiles
  alter column roles set not null,
  -- cardinality, not array_length: an empty array gives 0 here and null there, and a check
  -- constraint lets null through.
  add constraint profiles_roles_known check (
    cardinality(roles) >= 1 and roles <@ array['admin', 'cashier', 'waiter', 'kitchen']
  );
alter table public.profiles drop column role;

-- Replaces private.current_app_role(): a member can be an admin and something else at once.
create or replace function private.current_roles()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select p.roles from public.profiles p where p.user_id = private.current_user_id()
$$;

create or replace function private.current_is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce('admin' = any (p.roles), false) from public.profiles p where p.user_id = private.current_user_id()
$$;

grant execute on function private.current_roles(), private.current_is_admin() to cafe_app;

-- The policies of migration 20260911000008 that asked for a single role.
drop policy profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to cafe_app
  using (
    shop_id = (select private.current_shop_id())
    and (user_id = (select private.current_user_id()) or (select private.current_is_admin()))
  );

drop policy categories_insert on public.categories;
create policy categories_insert on public.categories
  for insert to cafe_app
  with check (shop_id = (select private.current_shop_id()) and (select private.current_is_admin()));

drop policy categories_delete on public.categories;
create policy categories_delete on public.categories
  for delete to cafe_app
  using (shop_id = (select private.current_shop_id()) and (select private.current_is_admin()));

drop policy shop_settings_update on public.shop_settings;
create policy shop_settings_update on public.shop_settings
  for update to cafe_app
  using (shop_id = (select private.current_shop_id()) and (select private.current_is_admin()))
  with check (shop_id = (select private.current_shop_id()));

drop function private.current_app_role();

-- The first statement of every RPC. A member holding any of p_roles passes.
create or replace function private.require_profile(p_roles text[] default array['admin', 'cashier'])
returns public.profiles
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
begin
  if private.current_user_id() is null then
    perform private.raise_error('UNAUTHENTICATED', 'Sign in to continue.');
  end if;
  select * into v_profile from public.profiles where user_id = private.current_user_id();
  if not found then
    perform private.raise_error('FORBIDDEN', 'This account is not a member of any shop.');
  end if;
  if not (v_profile.roles && p_roles) then
    perform private.raise_error('FORBIDDEN', 'Your role cannot do this.', jsonb_build_object('roles', v_profile.roles));
  end if;
  return v_profile;
end;
$$;

-- Every role signs in, so this one accepts all four; each RPC states its own.
create or replace function public.my_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_email text;
begin
  v_profile := private.require_profile(array['admin', 'cashier', 'waiter', 'kitchen']);
  select u.email into v_email from public.users u where u.id = v_profile.user_id;
  return jsonb_build_object(
    'user_id', v_profile.user_id,
    'shop_id', v_profile.shop_id,
    'roles', to_jsonb(v_profile.roles),
    'display_name', v_profile.display_name,
    'email', coalesce(v_email, '')
  );
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Menu. `available` becomes `is_available` (on the menu right now, a daily toggle) and `stock`
-- becomes `stock_qty`, the maintained cache of the movement log. `track_stock` is new and off by
-- default: most café items are made to order and counting them is noise. Rows that already carry
-- stock keep being counted, so an imported shop behaves exactly as it did yesterday.
alter table public.products rename column available to is_available;
alter table public.products rename column stock to stock_qty;
alter table public.products add column track_stock boolean not null default false;
update public.products set track_stock = true where stock_qty <> 0;

create or replace function private.move_stock(
  p_shop_id uuid,
  p_product_id uuid,
  p_delta integer,
  p_reason text,
  p_sale_id uuid,
  p_note text,
  p_actor uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stock integer;
begin
  if p_delta <> 0 then
    insert into public.stock_movements (shop_id, product_id, delta, reason, sale_id, note, created_by)
    values (p_shop_id, p_product_id, p_delta, p_reason, p_sale_id, coalesce(p_note, ''), p_actor);
    update public.products set stock_qty = stock_qty + p_delta
    where id = p_product_id and shop_id = p_shop_id
    returning stock_qty into v_stock;
  else
    select stock_qty into v_stock from public.products where id = p_product_id and shop_id = p_shop_id;
  end if;
  return v_stock;
end;
$$;

create or replace function private.product_json(v public.products)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', v.id,
    'name', v.name,
    'price_millimes', v.price_millimes,
    'category_id', v.category_id,
    'category_name', (select c.name from public.categories c where c.id = v.category_id),
    'barcode', coalesce(v.barcode, ''),
    'description', v.description,
    'image_url', v.image_url,
    'stock_qty', v.stock_qty,
    'track_stock', v.track_stock,
    'is_available', v.is_available,
    'created_at', v.created_at,
    'updated_at', v.updated_at
  )
$$;

-- Admin-only, and the toggle waiters use too: an item that ran out leaves the menu without anyone
-- touching prices. Availability is not stock: an untracked product is simply on or off.
create or replace function public.set_product_availability(p_product_id uuid, p_is_available boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_product public.products;
begin
  v_profile := private.require_profile(array['admin', 'cashier', 'waiter']);
  update public.products
  set is_available = coalesce(p_is_available, true), updated_at = now()
  where id = p_product_id and shop_id = v_profile.shop_id and archived_at is null
  returning * into v_product;
  if not found then
    perform private.raise_error('NOT_FOUND', 'The product does not exist.', jsonb_build_object('product_id', p_product_id));
  end if;
  return private.product_json(v_product);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Tables, orders and items.
create table public.dining_tables (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default private.current_shop_id() references public.shops (id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, shop_id),
  unique (shop_id, name)
);
create index dining_tables_shop_id_idx on public.dining_tables (shop_id, sort_order);

-- Working state, not the ledger. An order is created lazily by order_item_add when the first item
-- lands on a free table, so two devices adding to the same table never race on creating one; the
-- partial unique index below is what makes "the table's open order" a single row.
create table public.open_orders (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops (id) on delete restrict,
  table_id uuid not null,
  status text not null default 'open' check (status in ('open', 'closed', 'cancelled')),
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_reason text,
  unique (id, shop_id),
  foreign key (table_id, shop_id) references public.dining_tables (id, shop_id) on delete restrict,
  constraint open_orders_closed_fields check (
    (status = 'open' and closed_at is null and closed_reason is null)
    or (status = 'closed' and closed_at is not null and closed_reason is null)
    or (status = 'cancelled' and closed_at is not null and length(trim(coalesce(closed_reason, ''))) > 0)
  )
);
create unique index open_orders_one_open_per_table on public.open_orders (table_id) where status = 'open';
create index open_orders_shop_status_idx on public.open_orders (shop_id, status);

-- One line on a table. The name and the price are copied when the item is added, so a later price
-- change never moves what a guest already ordered. A removed item keeps its row: the admin's report
-- of items removed after they were sent is the point.
--
-- `id` is the add record's own id, so a replayed add answers with the item it already created and a
-- device can show the item under its final id the instant a waiter taps it.
create table public.open_order_items (
  id uuid primary key,
  shop_id uuid not null,
  order_id uuid not null,
  product_id uuid not null,
  name_snapshot text not null,
  unit_price_millimes bigint not null check (unit_price_millimes >= 0 and unit_price_millimes <= 1000000000000),
  qty integer not null check (qty >= 1),
  note text not null default '',
  device_id text not null default '',
  added_by uuid not null references public.users (id) on delete restrict,
  added_at timestamptz not null,
  received_at timestamptz not null default now(),
  sent_at timestamptz,
  prepared_at timestamptz,
  removed_at timestamptz,
  removed_by uuid references public.users (id) on delete restrict,
  removed_reason text,
  paid_sale_id uuid,
  unique (id, shop_id),
  foreign key (order_id, shop_id) references public.open_orders (id, shop_id) on delete restrict,
  foreign key (product_id, shop_id) references public.products (id, shop_id) on delete restrict,
  foreign key (paid_sale_id, shop_id) references public.sales (id, shop_id) on delete restrict,
  constraint open_order_items_removed_fields check (
    (removed_at is null and removed_by is null and removed_reason is null)
    or (removed_at is not null and removed_by is not null and length(trim(coalesce(removed_reason, ''))) > 0)
  ),
  constraint open_order_items_prepared_after_sent check (prepared_at is null or sent_at is not null),
  -- A paid item is never a removed one: record_sale refuses a line that names a removed item.
  constraint open_order_items_paid_is_active check (paid_sale_id is null or removed_at is null)
);
create index open_order_items_order_id_idx on public.open_order_items (order_id);
create index open_order_items_kitchen_idx on public.open_order_items (shop_id, sent_at)
  where sent_at is not null and prepared_at is null and removed_at is null;
create index open_order_items_removed_after_sent_idx on public.open_order_items (shop_id, removed_at)
  where removed_at is not null and sent_at is not null;
create index open_order_items_paid_sale_id_idx on public.open_order_items (paid_sale_id)
  where paid_sale_id is not null;

-- Idempotency for the order and stock RPCs, the same id + payload_hash rule record_sale applies to
-- the ledger: the same id with the same hash replays its stored result, a different hash is a
-- conflict, and another shop's id is never readable.
create table public.order_records (
  id uuid primary key,
  shop_id uuid not null references public.shops (id) on delete restrict,
  kind text not null check (kind in (
    'order_item_add', 'order_item_remove', 'order_send', 'order_item_prepare', 'order_cancel', 'stock_adjustment'
  )),
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  device_id text not null default '',
  submitted_by uuid not null references public.users (id) on delete restrict,
  result jsonb not null,
  created_at timestamptz not null,
  received_at timestamptz not null default now()
);
create index order_records_shop_id_idx on public.order_records (shop_id, received_at desc);

-- ---------------------------------------------------------------------------------------------
-- The ledger learns about tables and order items.
alter table public.sales add column table_id uuid;
alter table public.sales
  add constraint sales_table_id_fkey foreign key (table_id, shop_id)
    references public.dining_tables (id, shop_id) on delete restrict;
-- `discount_millimes` was always the cart discount; the café model says so in the name, because a
-- line now carries a discount of its own.
alter table public.sales rename column discount_millimes to cart_discount_millimes;

-- A line needs an identity of its own: a refund line points at the line it refunds instead of
-- repeating its number, and an order item points at the line that paid it.
alter table public.sale_lines add column id uuid not null default gen_random_uuid();
alter table public.sale_lines add constraint sale_lines_id_key unique (id);
alter table public.sale_lines rename column cart_discount_share_millimes to allocated_discount_millimes;
alter table public.sale_lines add column line_discount_reason text;
alter table public.sale_lines add column open_order_item_id uuid;
alter table public.sale_lines add column refunds_sale_line_id uuid;

-- Old refund rows named a line number. Point them at the line itself before the column goes, so
-- every row written before the café model still reads back the same way. The ledger triggers of
-- migration 20260911000008 refuse an UPDATE without this switch, which is turned off again on the
-- next line: a migration is not always one transaction, so this one is set for the session.
select set_config('pos.ledger_maintenance', 'on', false);
update public.sale_lines l
set refunds_sale_line_id = o.id
from public.sales s
join public.sale_lines o on o.sale_id = s.refunds_sale_id
where s.id = l.sale_id and l.refunds_line_no is not null and o.line_no = l.refunds_line_no;
select set_config('pos.ledger_maintenance', 'off', false);

alter table public.sale_lines drop column refunds_line_no;

alter table public.sale_lines
  add constraint sale_lines_open_order_item_fkey foreign key (open_order_item_id, shop_id)
    references public.open_order_items (id, shop_id) on delete restrict,
  add constraint sale_lines_refunds_sale_line_fkey foreign key (refunds_sale_line_id)
    references public.sale_lines (id) on delete restrict;
-- An order item is paid once and once only.
create unique index sale_lines_open_order_item_key on public.sale_lines (open_order_item_id)
  where open_order_item_id is not null;
create index sale_lines_refunds_sale_line_id_idx on public.sale_lines (refunds_sale_line_id)
  where refunds_sale_line_id is not null;

-- Dropping refunds_line_no took the old shape constraint with it, because it named that column.
alter table public.sale_lines drop constraint if exists sale_lines_shape;
alter table public.sale_lines add constraint sale_lines_shape check (
  (
    qty > 0 and refunds_sale_line_id is null
    and line_discount_millimes + allocated_discount_millimes <= qty * unit_price_millimes
    and line_total_millimes = qty * unit_price_millimes - line_discount_millimes - allocated_discount_millimes
  )
  or (
    qty < 0 and refunds_sale_line_id is not null and open_order_item_id is null
    and line_discount_millimes = 0 and allocated_discount_millimes = 0 and line_total_millimes <= 0
  )
);
-- An offered item or a discounted line always says why. Rows written before the café model carry no
-- line discount at all, so they satisfy this as they stand.
alter table public.sale_lines add constraint sale_lines_discount_reason check (
  line_discount_millimes = 0 or length(trim(coalesce(line_discount_reason, ''))) > 0
);

-- ---------------------------------------------------------------------------------------------
-- Row-level security and privileges, in the shape of migration 20260911000008: members read their
-- shop's rows, the admin edits the table plan, and every other write goes through an RPC.
alter table public.dining_tables enable row level security;
alter table public.open_orders enable row level security;
alter table public.open_order_items enable row level security;
alter table public.order_records enable row level security;

revoke all on public.dining_tables, public.open_orders, public.open_order_items, public.order_records
from public, cafe_app;

grant select on public.dining_tables, public.open_orders, public.open_order_items, public.order_records
to cafe_app;

grant insert (name, sort_order, is_active) on public.dining_tables to cafe_app;
grant update (name, sort_order, is_active) on public.dining_tables to cafe_app;
grant delete on public.dining_tables to cafe_app;

create policy dining_tables_select on public.dining_tables
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy dining_tables_insert on public.dining_tables
  for insert to cafe_app
  with check (shop_id = (select private.current_shop_id()) and (select private.current_is_admin()));

create policy dining_tables_update on public.dining_tables
  for update to cafe_app
  using (shop_id = (select private.current_shop_id()) and (select private.current_is_admin()))
  with check (shop_id = (select private.current_shop_id()));

-- A table an order ever touched is kept by the foreign keys; deleting is for a table plan the admin
-- is still drawing.
create policy dining_tables_delete on public.dining_tables
  for delete to cafe_app
  using (shop_id = (select private.current_shop_id()) and (select private.current_is_admin()));

create policy open_orders_select on public.open_orders
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy open_order_items_select on public.open_order_items
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

create policy order_records_select on public.order_records
  for select to cafe_app
  using (shop_id = (select private.current_shop_id()));

revoke all on function public.my_profile(), public.set_product_availability(uuid, boolean) from public;
grant execute on function public.my_profile(), public.set_product_availability(uuid, boolean) to cafe_app;

-- Live updates (RealtimePort): the waiter, kitchen and caisse screens all follow these four tables.
-- The publication exists only where Supabase Realtime is installed, so this is a no-op elsewhere,
-- and replica identity full makes an update carry the row that changed.
alter table public.dining_tables replica identity full;
alter table public.open_orders replica identity full;
alter table public.open_order_items replica identity full;

revoke all on all functions in schema private from public;
grant execute on function private.current_shop_id(), private.current_roles(), private.current_is_admin() to cafe_app;
-- ---------------------------------------------------------------------------------------------
-- from 20260911000011_order_rpcs.sql
-- The order RPCs of docs/spec.md, the admin's stock adjustment and its removed-after-sent report,
-- and record_sale taught to pay order items.
--
-- Every one of these takes `p jsonb` with a client `id` and `payload_hash` and is SECURITY DEFINER
-- with explicit shop and role checks, exactly like record_sale: no role holds a write policy on any
-- of these tables. They raise with message = <CODE> and a JSON detail (contracts/errors.md).

-- The café codes. Same table as migration 20260911000002, four rows longer.
create or replace function private.raise_error(p_code text, p_hint text, p_details jsonb default '{}'::jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_state text := case p_code
    when 'UNAUTHENTICATED' then 'PT401'
    when 'FORBIDDEN' then 'PT403'
    when 'NOT_FOUND' then 'PT404'
    when 'ITEM_NOT_FOUND' then 'PT404'
    when 'IDEMPOTENCY_CONFLICT' then 'PT409'
    when 'SEQUENCE_GAP' then 'PT409'
    when 'SESSION_CLOSED' then 'PT409'
    when 'SESSION_ALREADY_OPEN' then 'PT409'
    when 'TERMINAL_SUPERSEDED' then 'PT409'
    when 'ORDER_CHANGED' then 'PT409'
    when 'ORDER_CLOSED' then 'PT409'
    when 'TABLE_INACTIVE' then 'PT409'
    when 'VALIDATION_ERROR' then 'PT422'
  end;
begin
  if v_state is null then
    raise exception 'raise_error called with unknown code %', p_code;
  end if;
  raise exception using
    errcode = v_state,
    message = p_code,
    detail = coalesce(p_details, '{}'::jsonb)::text,
    hint = p_hint;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Payload helpers.

-- The first of p_keys the payload actually carries, or null.
create or replace function private.json_first(p jsonb, p_keys text[])
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select p -> k.key
  from unnest(p_keys) with ordinality as k(key, ord)
  where p ? k.key and jsonb_typeof(p -> k.key) <> 'null'
  order by k.ord
  limit 1
$$;

-- A device queues records before it is upgraded, so a payload written by the previous version of
-- the app has to stay readable: this copies a legacy key onto the name the café model uses, and
-- leaves a payload that already carries the new name alone.
create or replace function private.json_alias(p jsonb, p_key text, p_legacy text[])
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p ? p_key and jsonb_typeof(p -> p_key) <> 'null' then p
    when private.json_first(p, p_legacy) is null then p
    else p || jsonb_build_object(p_key, private.json_first(p, p_legacy))
  end
$$;

create or replace function private.json_reason(p jsonb, p_key text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v text := trim(coalesce(private.json_text(p, p_key, false), ''));
begin
  if v = '' then
    perform private.raise_error('VALIDATION_ERROR', format('%s is required.', p_key), jsonb_build_object('field', p_key));
  end if;
  return v;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Idempotency for order and stock records: the same rule record_sale applies to the ledger.

create or replace function private.order_replay(p_shop_id uuid, p_id uuid, p_hash text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_found record;
begin
  select r.shop_id, r.payload_hash, r.result into v_found from public.order_records r where r.id = p_id;
  if not found then
    return null;
  end if;
  if v_found.shop_id <> p_shop_id then
    perform private.raise_error('FORBIDDEN', 'This record belongs to another shop.', jsonb_build_object('id', p_id));
  end if;
  if v_found.payload_hash <> p_hash then
    perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', p_id));
  end if;
  return jsonb_set(v_found.result, '{status}', '"replayed"');
end;
$$;

-- Stores the record and returns its result. A unique clash means another transaction stored the
-- same id after the replay check, which is the same conflict seen a moment later.
create or replace function private.order_record_store(
  p_shop_id uuid, p_id uuid, p_kind text, p_hash text, p jsonb, p_submitted_by uuid, p_result jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- A device stamps its record; a payload that carries no clock of its own is stamped on arrival.
  v_when jsonb := private.json_first(p, array['created_at', 'added_at', 'sent_at']);
begin
  insert into public.order_records (id, shop_id, kind, payload_hash, device_id, submitted_by, result, created_at)
  values (
    p_id, p_shop_id, p_kind, p_hash,
    coalesce(private.json_text(p, 'device_id', false), ''),
    p_submitted_by, p_result,
    coalesce(
      case when v_when is null then null
           else private.json_timestamptz(jsonb_build_object('created_at', v_when), 'created_at') end,
      now()
    )
  );
  return p_result;
exception when unique_violation then
  perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', p_id));
  return null;
end;
$$;

-- The person the record says did the work, checked against the shop like every ledger record. Order
-- records carry no actor of their own (src/ports/orders.ts), so the caller is the default.
create or replace function private.order_actor(p_profile public.profiles, p jsonb)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p ? 'actor_user_id' and jsonb_typeof(p -> 'actor_user_id') <> 'null' then
    return private.require_member(p_profile.shop_id, p);
  end if;
  return p_profile.user_id;
end;
$$;

-- The table named by a record, locked. Locking the table row is what makes lazy order creation
-- safe: two devices adding to the same free table queue here, so the second one sees the order the
-- first one opened instead of racing to create a second.
create or replace function private.lock_table(p_shop_id uuid, p_table_id uuid, p_require_active boolean)
returns public.dining_tables
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table public.dining_tables;
begin
  select * into v_table from public.dining_tables where id = p_table_id and shop_id = p_shop_id for update;
  if not found then
    perform private.raise_error('FORBIDDEN', 'This table is not in your shop.', jsonb_build_object('table_id', p_table_id));
  end if;
  if p_require_active and not v_table.is_active then
    perform private.raise_error('TABLE_INACTIVE', 'This table is not in service.', jsonb_build_object('table_id', p_table_id));
  end if;
  return v_table;
end;
$$;

-- Closes an order that has nothing left to pay. Called after every payment and after a removal:
-- taking the last unpaid item off a table frees it just as paying for it does.
create or replace function private.close_order_if_settled(p_order_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_closed boolean := false;
begin
  update public.open_orders o
  set status = 'closed', closed_at = now()
  where o.id = p_order_id
    and o.status = 'open'
    and exists (select 1 from public.open_order_items i where i.order_id = o.id and i.paid_sale_id is not null)
    and not exists (
      select 1 from public.open_order_items i
      where i.order_id = o.id and i.removed_at is null and i.paid_sale_id is null
    );
  get diagnostics v_closed = row_count;
  return v_closed;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The five order RPCs.

-- p = { id, table_id, product_id, qty, note, added_at, device_id, payload_hash }
-- Finds the table's open order or creates it, snapshots the name and the price, inserts the item.
-- A closed order means the table is free again, so a late add — a waiter's offline event arriving
-- after the caisse paid the table — opens a new order with that item rather than losing it.
-- Returns { status, order_id, item_id }.
create or replace function public.order_item_add(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_replay jsonb;
  v_table public.dining_tables;
  v_product public.products;
  v_order_id uuid;
  v_qty integer;
  v_note text;
  v_added_at timestamptz;
  v_actor uuid;
begin
  v_profile := private.require_profile(array['admin', 'cashier', 'waiter']);
  p := private.json_alias(p, 'added_at', array['created_at']);
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  v_replay := private.order_replay(v_profile.shop_id, v_id, v_hash);
  if v_replay is not null then
    return v_replay;
  end if;

  v_table := private.lock_table(v_profile.shop_id, private.json_uuid(p, 'table_id'), true);

  select * into v_product
  from public.products
  where id = private.json_uuid(p, 'product_id') and shop_id = v_profile.shop_id and archived_at is null;
  if not found then
    perform private.raise_error(
      'NOT_FOUND', 'That product is not on the menu.',
      jsonb_build_object('product_id', private.json_uuid(p, 'product_id'))
    );
  end if;

  v_qty := private.json_int(p, 'qty');
  if v_qty < 1 then
    perform private.raise_error('VALIDATION_ERROR', 'A quantity is at least one.', jsonb_build_object('field', 'qty'));
  end if;
  v_note := coalesce(private.json_text(p, 'note', false), '');
  v_added_at := private.json_timestamptz(p, 'added_at');
  v_actor := private.order_actor(v_profile, p);

  select o.id into v_order_id
  from public.open_orders o
  where o.table_id = v_table.id and o.status = 'open';
  if v_order_id is null then
    insert into public.open_orders (shop_id, table_id, opened_at)
    values (v_profile.shop_id, v_table.id, v_added_at)
    returning id into v_order_id;
  end if;

  begin
    insert into public.open_order_items (
      id, shop_id, order_id, product_id, name_snapshot, unit_price_millimes, qty, note, device_id, added_by, added_at
    )
    values (
      v_id, v_profile.shop_id, v_order_id, v_product.id, v_product.name, v_product.price_millimes, v_qty, v_note,
      coalesce(private.json_text(p, 'device_id', false), ''), v_actor, v_added_at
    );
  exception when unique_violation then
    -- The item id is the record id, so this is the same record arriving twice at once.
    perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
  end;

  return private.order_record_store(
    v_profile.shop_id, v_id, 'order_item_add', v_hash, p, v_profile.user_id,
    jsonb_build_object('status', 'created', 'order_id', v_order_id, 'item_id', v_id)
  );
end;
$$;

-- p = { id, item_id, reason, created_at, device_id, payload_hash }
-- Stamps removed_at and keeps the row: the admin's report of items removed after they were sent is
-- the reason the row stays. Returns { status, order_id, affected }.
create or replace function public.order_item_remove(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_replay jsonb;
  v_item_id uuid;
  v_item public.open_order_items;
  v_order public.open_orders;
  v_reason text;
  v_actor uuid;
  v_affected integer := 0;
begin
  v_profile := private.require_profile(array['admin', 'cashier', 'waiter']);
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  v_replay := private.order_replay(v_profile.shop_id, v_id, v_hash);
  if v_replay is not null then
    return v_replay;
  end if;

  v_reason := private.json_reason(p, 'reason');
  v_item_id := private.json_uuid(p, 'item_id');
  select * into v_item
  from public.open_order_items
  where id = v_item_id and shop_id = v_profile.shop_id
  for update;
  if not found then
    perform private.raise_error('ITEM_NOT_FOUND', 'That item is not on any table.', jsonb_build_object('item_id', v_item_id));
  end if;

  select * into v_order from public.open_orders where id = v_item.order_id;
  if v_item.paid_sale_id is not null then
    perform private.raise_error(
      'ORDER_CHANGED', 'That item has already been paid for.',
      jsonb_build_object('table_id', v_order.table_id, 'item_id', v_item_id)
    );
  end if;
  if v_order.status <> 'open' then
    perform private.raise_error(
      'ORDER_CLOSED', 'That table has no open order any more.',
      jsonb_build_object('table_id', v_order.table_id, 'order_id', v_order.id)
    );
  end if;

  v_actor := private.order_actor(v_profile, p);
  -- Removing an item that is already off the table changes nothing and must never stop a queue.
  if v_item.removed_at is null then
    update public.open_order_items
    set removed_at = now(), removed_by = v_actor, removed_reason = v_reason
    where id = v_item_id;
    v_affected := 1;
    perform private.close_order_if_settled(v_order.id);
  end if;

  return private.order_record_store(
    v_profile.shop_id, v_id, 'order_item_remove', v_hash, p, v_profile.user_id,
    jsonb_build_object('status', 'created', 'order_id', v_order.id, 'affected', v_affected)
  );
end;
$$;

-- p = { id, table_id, sent_at, device_id, payload_hash }
-- One send is one kitchen ticket: every unsent active item of the table's open order gets the same
-- stamp. Returns { status, order_id, affected }.
create or replace function public.order_send(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_replay jsonb;
  v_table public.dining_tables;
  v_order public.open_orders;
  v_sent_at timestamptz;
  v_affected integer;
begin
  v_profile := private.require_profile(array['admin', 'cashier', 'waiter']);
  p := private.json_alias(p, 'sent_at', array['created_at']);
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  v_replay := private.order_replay(v_profile.shop_id, v_id, v_hash);
  if v_replay is not null then
    return v_replay;
  end if;

  v_table := private.lock_table(v_profile.shop_id, private.json_uuid(p, 'table_id'), false);
  select * into v_order from public.open_orders where table_id = v_table.id and status = 'open';
  if not found then
    perform private.raise_error(
      'ORDER_CLOSED', 'That table has no open order any more.',
      jsonb_build_object('table_id', v_table.id)
    );
  end if;

  v_sent_at := private.json_timestamptz(p, 'sent_at');
  update public.open_order_items
  set sent_at = v_sent_at
  where order_id = v_order.id and sent_at is null and removed_at is null;
  get diagnostics v_affected = row_count;

  return private.order_record_store(
    v_profile.shop_id, v_id, 'order_send', v_hash, p, v_profile.user_id,
    jsonb_build_object('status', 'created', 'order_id', v_order.id, 'affected', v_affected)
  );
end;
$$;

-- p = { id, item_id, created_at, device_id, payload_hash }
-- The kitchen marking a ticket line done. Returns { status, order_id, affected }.
create or replace function public.order_item_prepare(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_replay jsonb;
  v_item_id uuid;
  v_item public.open_order_items;
  v_order public.open_orders;
  v_affected integer := 0;
begin
  v_profile := private.require_profile(array['admin', 'kitchen']);
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  v_replay := private.order_replay(v_profile.shop_id, v_id, v_hash);
  if v_replay is not null then
    return v_replay;
  end if;

  v_item_id := private.json_uuid(p, 'item_id');
  select * into v_item
  from public.open_order_items
  where id = v_item_id and shop_id = v_profile.shop_id
  for update;
  if not found then
    perform private.raise_error('ITEM_NOT_FOUND', 'That item is not on any table.', jsonb_build_object('item_id', v_item_id));
  end if;

  select * into v_order from public.open_orders where id = v_item.order_id;
  -- An item the kitchen was never told about, or one taken off the table while it cooked: the
  -- screen is out of date, which is exactly what ORDER_CHANGED means.
  if v_item.sent_at is null or v_item.removed_at is not null then
    perform private.raise_error(
      'ORDER_CHANGED', 'That item is no longer on the kitchen screen.',
      jsonb_build_object('table_id', v_order.table_id, 'item_id', v_item_id)
    );
  end if;

  if v_item.prepared_at is null then
    update public.open_order_items set prepared_at = now() where id = v_item_id;
    v_affected := 1;
  end if;

  return private.order_record_store(
    v_profile.shop_id, v_id, 'order_item_prepare', v_hash, p, v_profile.user_id,
    jsonb_build_object('status', 'created', 'order_id', v_order.id, 'affected', v_affected)
  );
end;
$$;

-- p = { id, table_id, reason, created_at, device_id, payload_hash }
-- Cancels the table's open order. Its active items are stamped removed with the cancel's reason, so
-- a cancel of a sent order still reaches the removed-after-sent report.
-- Returns { status, order_id, affected }.
create or replace function public.order_cancel(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_replay jsonb;
  v_table public.dining_tables;
  v_order public.open_orders;
  v_reason text;
  v_actor uuid;
  v_paid uuid;
  v_affected integer;
begin
  v_profile := private.require_profile(array['admin', 'cashier']);
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  v_replay := private.order_replay(v_profile.shop_id, v_id, v_hash);
  if v_replay is not null then
    return v_replay;
  end if;

  v_reason := private.json_reason(p, 'reason');
  v_table := private.lock_table(v_profile.shop_id, private.json_uuid(p, 'table_id'), false);
  select * into v_order from public.open_orders where table_id = v_table.id and status = 'open';
  if not found then
    perform private.raise_error(
      'ORDER_CLOSED', 'That table has no open order any more.',
      jsonb_build_object('table_id', v_table.id)
    );
  end if;

  select i.id into v_paid from public.open_order_items i where i.order_id = v_order.id and i.paid_sale_id is not null limit 1;
  if v_paid is not null then
    perform private.raise_error(
      'ORDER_CHANGED', 'Part of this order has already been paid for.',
      jsonb_build_object('table_id', v_table.id, 'order_id', v_order.id, 'item_id', v_paid)
    );
  end if;

  v_actor := private.order_actor(v_profile, p);
  update public.open_order_items
  set removed_at = now(), removed_by = v_actor, removed_reason = v_reason
  where order_id = v_order.id and removed_at is null;
  get diagnostics v_affected = row_count;

  update public.open_orders
  set status = 'cancelled', closed_at = now(), closed_reason = v_reason
  where id = v_order.id;

  return private.order_record_store(
    v_profile.shop_id, v_id, 'order_cancel', v_hash, p, v_profile.user_id,
    jsonb_build_object('status', 'created', 'order_id', v_order.id, 'affected', v_affected)
  );
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- p = { id, product_id, qty_delta, reason, created_at, device_id, payload_hash }   (admin)
-- The one manual way products.stock_qty moves. Returns { status, product_id, stock_qty }.
create or replace function public.adjust_stock(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_replay jsonb;
  v_product public.products;
  v_delta integer;
  v_reason text;
  v_actor uuid;
  v_stock integer;
begin
  v_profile := private.require_profile(array['admin']);
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  v_replay := private.order_replay(v_profile.shop_id, v_id, v_hash);
  if v_replay is not null then
    return v_replay;
  end if;

  select * into v_product
  from public.products
  where id = private.json_uuid(p, 'product_id') and shop_id = v_profile.shop_id
  for update;
  if not found then
    perform private.raise_error(
      'NOT_FOUND', 'The product does not exist.',
      jsonb_build_object('product_id', private.json_uuid(p, 'product_id'))
    );
  end if;

  v_delta := private.json_int(p, 'qty_delta');
  if v_delta = 0 then
    perform private.raise_error('VALIDATION_ERROR', 'An adjustment moves stock up or down, never by nothing.', jsonb_build_object('field', 'qty_delta'));
  end if;
  v_reason := private.json_reason(p, 'reason');
  v_actor := private.order_actor(v_profile, p);

  v_stock := private.move_stock(v_profile.shop_id, v_product.id, v_delta, 'adjustment', null, v_reason, v_actor);

  return private.order_record_store(
    v_profile.shop_id, v_id, 'stock_adjustment', v_hash, p, v_profile.user_id,
    jsonb_build_object('status', 'created', 'product_id', v_product.id, 'stock_qty', v_stock)
  );
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Admin report: what was taken off a table after the kitchen had already been told, per waiter.
-- That is the classic waiter fraud, so it is a report and not a footnote. Both ends of the period
-- are required; the rows come back newest first.
create or replace function public.removed_after_sent(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
begin
  v_profile := private.require_profile(array['admin']);
  if p_from is null or p_to is null then
    perform private.raise_error('VALIDATION_ERROR', 'A report is always of a named period.', jsonb_build_object('field', 'from'));
  end if;
  if p_to < p_from then
    perform private.raise_error('VALIDATION_ERROR', 'The period ends before it starts.', jsonb_build_object('field', 'to'));
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'item_id', i.id,
          'table_name', t.name,
          'product_name', i.name_snapshot,
          'qty', i.qty,
          'unit_price_millimes', i.unit_price_millimes,
          'sent_at', i.sent_at,
          'removed_at', i.removed_at,
          'removed_by', i.removed_by,
          'removed_by_name', coalesce(pr.display_name, ''),
          'removed_reason', coalesce(i.removed_reason, '')
        )
        order by i.removed_at desc, i.id
      )
      from public.open_order_items i
      join public.open_orders o on o.id = i.order_id
      join public.dining_tables t on t.id = o.table_id
      left join public.profiles pr on pr.user_id = i.removed_by
      where i.shop_id = v_profile.shop_id
        and i.sent_at is not null
        and i.removed_at is not null
        and i.removed_at >= p_from
        and i.removed_at <= p_to
    ),
    '[]'::jsonb
  );
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- record_sale, step 4 of docs/spec.md: a sale pays for named items of a table's open order.
--
-- p = { id, kind, terminal_code, epoch, seq, session_id, table_id?, created_at, payload_hash,
--       lines: [{ line_no, open_order_item_id?, product_id, product_name, qty, unit_price_millimes,
--                 line_discount_millimes, line_discount_reason?, allocated_discount_millimes,
--                 net_millimes, refunds_sale_line_id? }],
--       cart_discount_millimes, subtotal_millimes?, total_millimes,
--       payment: { method, tendered_millimes, change_millimes }, refunds_sale_id? }
-- Returns { sale_id, receipt_number, status: 'created' | 'replayed' | 'voided' }.
--
-- The order of checks is part of the contract (contracts/errors.md). Everything before step 7 is
-- unchanged from migration 20260911000006: the receipt sequence, the session and the terminal lock
-- behave exactly as they did.
create or replace function public.record_sale(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_terminal public.terminals;
  v_found record;
  v_session_id uuid;
  v_session public.cash_sessions;
  v_seq bigint;
  v_receipt text;
  v_kind text;
  v_lines jsonb;
  v_line jsonb;
  v_line_no integer := 0;
  v_product_id uuid;
  v_qty integer;
  v_unit bigint;
  v_line_discount bigint;
  v_line_reason text;
  v_share bigint;
  v_line_total bigint;
  v_table_id uuid;
  v_item_id uuid;
  v_item public.open_order_items;
  v_order_id uuid;
  v_item_ids uuid[] := '{}';
  v_refunds_line_id uuid;
  v_seen_refund_lines uuid[] := '{}';
  v_subtotal bigint := 0;
  v_discount bigint := 0;
  v_total bigint := 0;
  v_refunds_sale_id uuid;
  v_original public.sales;
  v_original_line public.sale_lines;
  v_prior_units bigint;
  v_prior_amount bigint;
  v_payment jsonb;
  v_method text;
  v_tendered bigint;
  v_change bigint;
  v_created_at timestamptz;
  v_constraint text;
begin
  -- 1. Who is calling. A waiter carries no register: selling is for the caisse and the admin.
  v_profile := private.require_profile(array['admin', 'cashier']);
  p := private.json_alias(p, 'cart_discount_millimes', array['discount_millimes']);
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  -- 2. Serialise all writes for this terminal before reading anything else.
  v_terminal := private.lock_terminal(v_profile.shop_id, p);

  -- 3. Idempotency: a record already recorded or voided returns its stored outcome.
  select s.shop_id, s.payload_hash, s.receipt_number into v_found from public.sales s where s.id = v_id;
  if found then
    if v_found.shop_id <> v_profile.shop_id then
      perform private.raise_error('FORBIDDEN', 'This record belongs to another shop.');
    end if;
    if v_found.payload_hash <> v_hash then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
    end if;
    return jsonb_build_object('sale_id', v_id, 'receipt_number', v_found.receipt_number, 'status', 'replayed');
  end if;

  select rv.shop_id, rv.payload_hash, rv.receipt_number into v_found from public.receipt_voids rv where rv.id = v_id;
  if found then
    if v_found.shop_id <> v_profile.shop_id then
      perform private.raise_error('FORBIDDEN', 'This record belongs to another shop.');
    end if;
    if v_found.payload_hash <> v_hash then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
    end if;
    return jsonb_build_object('sale_id', v_id, 'receipt_number', v_found.receipt_number, 'status', 'voided');
  end if;

  -- 4. The device holds the current registration.
  perform private.require_epoch(v_terminal, p);

  -- 5. The session exists, is open and belongs to this terminal.
  v_session_id := private.json_uuid(p, 'session_id');
  select * into v_session from public.cash_sessions where id = v_session_id;
  if not found then
    perform private.raise_error('NOT_FOUND', 'The session does not exist.', jsonb_build_object('session_id', v_session_id));
  end if;
  if v_session.shop_id <> v_profile.shop_id or v_session.terminal_id <> v_terminal.id then
    perform private.raise_error('FORBIDDEN', 'The session does not belong to this terminal.', jsonb_build_object('session_id', v_session_id));
  end if;
  if v_session.closed_at is not null then
    perform private.raise_error('SESSION_CLOSED', 'The session was closed before this record arrived.', jsonb_build_object('session_id', v_session_id));
  end if;

  -- 6. Gapless numbering: exactly the next number of this terminal.
  v_seq := private.json_bigint(p, 'seq');
  if v_seq <> v_terminal.last_seq + 1 then
    perform private.raise_error(
      'SEQUENCE_GAP',
      format('Expected receipt %s-%s.', v_terminal.code, v_terminal.last_seq + 1),
      jsonb_build_object('expected_seq', v_terminal.last_seq + 1, 'received_seq', v_seq)
    );
  end if;
  v_receipt := v_terminal.code || '-' || v_seq;

  -- 7. The document: every amount is recomputed from the lines.
  v_kind := private.json_text(p, 'kind');
  if v_kind not in ('sale', 'refund') then
    perform private.raise_error('VALIDATION_ERROR', 'kind must be sale or refund.', jsonb_build_object('field', 'kind'));
  end if;

  v_lines := p -> 'lines';
  if v_lines is null or jsonb_typeof(v_lines) <> 'array' or jsonb_array_length(v_lines) = 0 then
    perform private.raise_error('VALIDATION_ERROR', 'A record needs at least one line.', jsonb_build_object('field', 'lines'));
  end if;
  -- Line amounts under the names the café model uses, whatever the device called them.
  select jsonb_agg(
           private.json_alias(
             private.json_alias(e.value, 'allocated_discount_millimes', array['cart_discount_share_millimes']),
             'net_millimes', array['line_total_millimes']
           )
           order by e.ord
         )
  into v_lines
  from jsonb_array_elements(v_lines) with ordinality as e(value, ord);
  p := jsonb_set(p, '{lines}', v_lines);

  if v_kind = 'sale' then
    -- Every line of a sale pays for an item of this table's open order, so the table is part of the
    -- document and not an afterthought.
    v_table_id := private.json_uuid(p, 'table_id');
    if not exists (select 1 from public.dining_tables t where t.id = v_table_id and t.shop_id = v_profile.shop_id) then
      perform private.raise_error('FORBIDDEN', 'This table is not in your shop.', jsonb_build_object('table_id', v_table_id));
    end if;
    select o.id into v_order_id from public.open_orders o where o.table_id = v_table_id and o.status = 'open';
    if v_order_id is null then
      perform private.raise_error(
        'ORDER_CLOSED', 'That table has no open order any more.',
        jsonb_build_object('table_id', v_table_id)
      );
    end if;
  else
    if p ? 'table_id' and jsonb_typeof(p -> 'table_id') <> 'null' then
      perform private.raise_error('VALIDATION_ERROR', 'A refund is not paid at a table.', jsonb_build_object('field', 'table_id'));
    end if;
    v_refunds_sale_id := private.json_uuid(p, 'refunds_sale_id');
    -- Refunds of one sale can arrive from several terminals: take them one at a time, and sum the
    -- earlier refunds only after holding the lock.
    perform pg_advisory_xact_lock(hashtextextended(v_refunds_sale_id::text, 0));
    select * into v_original from public.sales where id = v_refunds_sale_id and shop_id = v_profile.shop_id;
    if not found then
      perform private.raise_error('NOT_FOUND', 'The sale to refund does not exist.', jsonb_build_object('sale_id', v_refunds_sale_id));
    end if;
    if v_original.kind <> 'sale' then
      perform private.raise_error('VALIDATION_ERROR', 'Only a sale can be refunded, not a refund.', jsonb_build_object('field', 'refunds_sale_id'));
    end if;
  end if;

  for v_line in select e.value from jsonb_array_elements(v_lines) e
  loop
    v_line_no := v_line_no + 1;
    if jsonb_typeof(v_line) <> 'object' or private.json_int(v_line, 'line_no') <> v_line_no then
      perform private.raise_error('VALIDATION_ERROR', 'Lines must be numbered 1, 2, 3 in order.', jsonb_build_object('field', 'lines'));
    end if;
    v_product_id := private.json_uuid(v_line, 'product_id');
    perform private.json_text(v_line, 'product_name');
    v_qty := private.json_int(v_line, 'qty');
    v_unit := private.json_bigint(v_line, 'unit_price_millimes');
    v_line_discount := private.json_bigint(v_line, 'line_discount_millimes');
    v_line_reason := nullif(trim(coalesce(private.json_text(v_line, 'line_discount_reason', false), '')), '');
    v_share := private.json_bigint(v_line, 'allocated_discount_millimes');
    v_line_total := private.json_bigint(v_line, 'net_millimes');

    -- Archived products can still be sold offline and refunded.
    if not exists (select 1 from public.products pr where pr.id = v_product_id and pr.shop_id = v_profile.shop_id) then
      perform private.raise_error('NOT_FOUND', 'A line names a product that does not exist.', jsonb_build_object('product_id', v_product_id));
    end if;

    -- A unit price is a product price: at most one billion dinars, the bound
    -- src/ports/catalog.ts reads products and sale lines back with. The line total is qty x unit
    -- price, so it is not bounded the same way, and neither are the discounts or the totals.
    if v_unit > 1000000000000 then
      perform private.raise_error('VALIDATION_ERROR', 'A unit price cannot be above one billion dinars.', jsonb_build_object('line_no', v_line_no));
    end if;

    if v_kind = 'sale' then
      if private.json_first(v_line, array['refunds_sale_line_id', 'refunds_line_no']) is not null then
        perform private.raise_error('VALIDATION_ERROR', 'A sale line cannot refund another line.', jsonb_build_object('line_no', v_line_no));
      end if;

      -- The order item this line pays for. Anything that moved under the terminal — paid, removed,
      -- on another table, or no longer the same product, quantity or price — is ORDER_CHANGED, and
      -- the terminal refreshes the table and pays again.
      v_item_id := private.json_uuid(v_line, 'open_order_item_id');
      if v_item_id = any (v_item_ids) then
        perform private.raise_error('VALIDATION_ERROR', 'An order item can appear on only one line.', jsonb_build_object('line_no', v_line_no));
      end if;
      v_item_ids := v_item_ids || v_item_id;

      select * into v_item
      from public.open_order_items
      where id = v_item_id and shop_id = v_profile.shop_id
      for update;
      if not found or v_item.order_id <> v_order_id or v_item.removed_at is not null or v_item.paid_sale_id is not null
         or v_item.product_id <> v_product_id or v_item.qty <> v_qty or v_item.unit_price_millimes <> v_unit then
        perform private.raise_error(
          'ORDER_CHANGED',
          'This table changed while it was being paid for. Look at it again.',
          jsonb_build_object('table_id', v_table_id, 'item_id', v_item_id, 'line_no', v_line_no)
        );
      end if;

      if v_qty < 1 or v_unit < 0 or v_line_discount < 0 or v_share < 0
         or v_line_discount + v_share > v_qty * v_unit
         or v_line_total <> v_qty * v_unit - v_line_discount - v_share then
        perform private.raise_error('VALIDATION_ERROR', 'Line amounts do not add up.', jsonb_build_object('line_no', v_line_no));
      end if;
      -- An offered item or a discounted line always says why.
      if v_line_discount > 0 and v_line_reason is null then
        perform private.raise_error('VALIDATION_ERROR', 'Say why this line is discounted.', jsonb_build_object('line_no', v_line_no, 'field', 'line_discount_reason'));
      end if;
      v_subtotal := v_subtotal + v_qty * v_unit - v_line_discount;
      v_discount := v_discount + v_share;
    else
      if v_line_reason is not null then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line carries no discount.', jsonb_build_object('line_no', v_line_no));
      end if;
      if private.json_first(v_line, array['open_order_item_id']) is not null then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line pays no order item.', jsonb_build_object('line_no', v_line_no));
      end if;

      -- The line being refunded, by its own id. A payload written before the café model names the
      -- line's number on the original sale instead; both end up at the same row.
      v_refunds_line_id := private.json_uuid(v_line, 'refunds_sale_line_id', false);
      if v_refunds_line_id is null then
        select sl.id into v_refunds_line_id
        from public.sale_lines sl
        where sl.sale_id = v_original.id and sl.line_no = private.json_int(v_line, 'refunds_line_no');
      end if;
      if v_refunds_line_id is null then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line names a line that is not on the sale.', jsonb_build_object('line_no', v_line_no));
      end if;
      if v_refunds_line_id = any (v_seen_refund_lines) then
        perform private.raise_error('VALIDATION_ERROR', 'An original line can appear only once in a refund.', jsonb_build_object('line_no', v_line_no));
      end if;
      v_seen_refund_lines := v_seen_refund_lines || v_refunds_line_id;

      select * into v_original_line from public.sale_lines where id = v_refunds_line_id and sale_id = v_original.id;
      if not found then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line names a line that is not on the sale.', jsonb_build_object('line_no', v_line_no));
      end if;
      if v_product_id <> v_original_line.product_id or v_unit <> v_original_line.unit_price_millimes
         or v_line_discount <> 0 or v_share <> 0 or v_qty > -1 or v_line_total > 0 then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line must match its sale line, with a negative quantity and amount.', jsonb_build_object('line_no', v_line_no));
      end if;

      select coalesce(sum(-sl.qty), 0), coalesce(sum(-sl.line_total_millimes), 0)
      into v_prior_units, v_prior_amount
      from public.sale_lines sl
      join public.sales s on s.id = sl.sale_id
      where s.refunds_sale_id = v_original.id and sl.refunds_sale_line_id = v_refunds_line_id;

      -- Units and amount stay within what is left, and the refund that takes a line's last units
      -- pays exactly what is left of it, so the parts of a line always add up to its total.
      if v_prior_units - v_qty > v_original_line.qty
         or v_prior_amount - v_line_total > v_original_line.line_total_millimes then
        perform private.raise_error(
          'VALIDATION_ERROR',
          'The refund is more than what is left to refund on this line.',
          jsonb_build_object(
            'line_no', v_line_no,
            'remaining_qty', v_original_line.qty - v_prior_units,
            'remaining_millimes', v_original_line.line_total_millimes - v_prior_amount
          )
        );
      end if;
      if v_prior_units - v_qty = v_original_line.qty
         and v_prior_amount - v_line_total <> v_original_line.line_total_millimes then
        perform private.raise_error(
          'VALIDATION_ERROR',
          'A refund of the last units of a line pays exactly what is left of it.',
          jsonb_build_object(
            'line_no', v_line_no,
            'remaining_qty', v_original_line.qty - v_prior_units,
            'remaining_millimes', v_original_line.line_total_millimes - v_prior_amount
          )
        );
      end if;
      v_subtotal := v_subtotal + v_line_total;
      v_line := jsonb_set(v_line, '{refunds_sale_line_id}', to_jsonb(v_refunds_line_id));
      v_lines := jsonb_set(v_lines, array[(v_line_no - 1)::text], v_line);
    end if;
    v_total := v_total + v_line_total;
  end loop;

  -- subtotal_millimes is derived, so a payload that leaves it out is fine; one that states it has
  -- to state the same number the lines add up to.
  if (p ? 'subtotal_millimes' and jsonb_typeof(p -> 'subtotal_millimes') <> 'null'
      and private.json_bigint(p, 'subtotal_millimes') <> v_subtotal)
     or private.json_bigint(p, 'cart_discount_millimes') <> v_discount
     or private.json_bigint(p, 'total_millimes') <> v_total then
    perform private.raise_error(
      'VALIDATION_ERROR',
      'The document totals do not match its lines.',
      jsonb_build_object('subtotal_millimes', v_subtotal, 'cart_discount_millimes', v_discount, 'total_millimes', v_total)
    );
  end if;

  -- Payment. Change only exists for cash; a refund pays out exactly its total.
  v_payment := p -> 'payment';
  if v_payment is null or jsonb_typeof(v_payment) <> 'object' then
    perform private.raise_error('VALIDATION_ERROR', 'payment is required.', jsonb_build_object('field', 'payment'));
  end if;
  v_method := private.json_text(v_payment, 'method');
  v_tendered := private.json_bigint(v_payment, 'tendered_millimes');
  v_change := private.json_bigint(v_payment, 'change_millimes');
  if v_method not in ('cash', 'card') then
    perform private.raise_error('VALIDATION_ERROR', 'The payment method must be cash or card.', jsonb_build_object('field', 'payment.method'));
  end if;
  if v_kind = 'refund' or v_method = 'card' then
    if v_tendered <> v_total or v_change <> 0 then
      perform private.raise_error('VALIDATION_ERROR', 'Card payments and refunds are exactly the total, with no change.', jsonb_build_object('field', 'payment'));
    end if;
  elsif v_tendered < v_total or v_change <> v_tendered - v_total then
    perform private.raise_error('VALIDATION_ERROR', 'Change must be the amount tendered minus the total.', jsonb_build_object('field', 'payment'));
  end if;

  v_created_at := private.json_timestamptz(p, 'created_at');

  -- 8. Write. Products are locked in id order so two terminals never deadlock on stock.
  perform 1
  from public.products pr
  where pr.shop_id = v_profile.shop_id
    and pr.id in (select (e.value ->> 'product_id')::uuid from jsonb_array_elements(v_lines) e)
  order by pr.id
  for update;

  begin
    insert into public.sales (
      id, shop_id, terminal_id, session_id, kind, seq, receipt_number, refunds_sale_id, table_id, payment_method,
      subtotal_millimes, cart_discount_millimes, total_millimes, tendered_millimes, change_millimes,
      epoch, payload_hash, submitted_by, created_at
    )
    values (
      v_id, v_profile.shop_id, v_terminal.id, v_session.id, v_kind, v_seq, v_receipt, v_refunds_sale_id, v_table_id, v_method,
      v_subtotal, v_discount, v_total, v_tendered, v_change,
      v_terminal.epoch, v_hash, v_profile.user_id, v_created_at
    );
  exception when unique_violation then
    -- Another terminal stored a record under the same id after the idempotency check above.
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint in ('sales_pkey', 'sales_id_shop_id_key') then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
    end if;
    raise;
  end;

  for v_line in select e.value from jsonb_array_elements(v_lines) e
  loop
    v_qty := (v_line ->> 'qty')::integer;
    v_product_id := (v_line ->> 'product_id')::uuid;
    insert into public.sale_lines (
      sale_id, shop_id, line_no, product_id, product_name, qty, unit_price_millimes,
      line_discount_millimes, line_discount_reason, allocated_discount_millimes, line_total_millimes,
      open_order_item_id, refunds_sale_line_id
    )
    values (
      v_id, v_profile.shop_id, (v_line ->> 'line_no')::integer, v_product_id, v_line ->> 'product_name', v_qty,
      (v_line ->> 'unit_price_millimes')::bigint, (v_line ->> 'line_discount_millimes')::bigint,
      nullif(trim(coalesce(v_line ->> 'line_discount_reason', '')), ''),
      (v_line ->> 'allocated_discount_millimes')::bigint, (v_line ->> 'net_millimes')::bigint,
      (v_line ->> 'open_order_item_id')::uuid, (v_line ->> 'refunds_sale_line_id')::uuid
    );
    -- A sale takes units out of stock; a refund puts them back, for the products the shop counts.
    -- Stock never blocks a sale and may go negative.
    if (select pr.track_stock from public.products pr where pr.id = v_product_id) then
      perform private.move_stock(
        v_profile.shop_id, v_product_id, -v_qty,
        case when v_kind = 'sale' then 'sale' else 'refund' end,
        v_id, '', v_profile.user_id
      );
    end if;
  end loop;

  -- The items this sale paid for, and the table it leaves behind: an order with nothing unpaid
  -- left on it closes, so a table can be paid in parts and is free when the last part is settled.
  if v_kind = 'sale' then
    update public.open_order_items set paid_sale_id = v_id where id = any (v_item_ids);
    perform private.close_order_if_settled(v_order_id);
  end if;

  update public.terminals set last_seq = v_seq where id = v_terminal.id;

  return jsonb_build_object('sale_id', v_id, 'receipt_number', v_receipt, 'status', 'created');
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Functions created in public after migration 20260911000008 keep PUBLIC's default EXECUTE, which
-- a per-schema default cannot take away: every one of them revokes it for itself.
revoke all on function
  public.order_item_add(jsonb),
  public.order_item_remove(jsonb),
  public.order_send(jsonb),
  public.order_item_prepare(jsonb),
  public.order_cancel(jsonb),
  public.adjust_stock(jsonb),
  public.removed_after_sent(timestamptz, timestamptz)
from public;

grant execute on function
  public.order_item_add(jsonb),
  public.order_item_remove(jsonb),
  public.order_send(jsonb),
  public.order_item_prepare(jsonb),
  public.order_cancel(jsonb),
  public.adjust_stock(jsonb),
  public.removed_after_sent(timestamptz, timestamptz)
to cafe_app;

revoke all on all functions in schema private from public;
grant execute on function private.current_shop_id(), private.current_roles(), private.current_is_admin() to cafe_app;
-- ---------------------------------------------------------------------------------------------
-- from 20260911000013_counter_sales_and_tables.sql
-- Counter sales, and the room as the admin edits it.
--
-- Two things the café model needs that migration 20260911000011 did not give it:
--
-- 1. A sale that sat on no table. `record_sale` required `table_id` on every sale and
--    `open_order_item_id` on every line, so a coffee taken away could not be sold at all. Both are
--    optional in docs/spec.md, and this replaces the function with a version that honours that: a
--    payload with no table pays no order item, a payload with a table pays the items it names on
--    that table, and a line with no item on a table payment is simply a product sold at the counter
--    on the same bill — the guest at table 4 who also buys a packet of cigarettes.
--
--    A mixed bill cannot lose money: only a line that names an item marks one paid, every line is
--    recomputed the same way whether or not it names one, and the order still closes only when it
--    has nothing unpaid left on it. The other direction would: refusing the mixed bill would push
--    the counter line onto a second receipt or, worse, onto nobody's.
--
-- 2. Table management. The room is the admin's, but there was no way to change it: no RPC and no
--    write policy. `save_dining_table` is that way, in the shape `save_product` already has — one
--    function that inserts or updates, admin only, shop-scoped. A table is retired, never deleted,
--    so a sale paid at it keeps its name.

-- ---------------------------------------------------------------------------------------------
-- The room. Plain (not a record with an id and a hash): a table is named by what it is, so sending
-- the same edit twice leaves the same row, and there is nothing for a replay to protect.
create or replace function public.save_dining_table(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_name text;
  v_sort integer;
  v_active boolean;
  v_table public.dining_tables;
begin
  v_profile := private.require_profile(array['admin']);
  v_id := private.json_uuid(p, 'id', false);
  v_name := nullif(trim(private.json_text(p, 'name')), '');
  if v_name is null then
    perform private.raise_error('VALIDATION_ERROR', 'A table needs a name.', jsonb_build_object('field', 'name'));
  end if;
  v_sort := private.json_int(p, 'sort_order');
  if v_sort < 0 then
    perform private.raise_error('VALIDATION_ERROR', 'A table cannot sort before the first one.', jsonb_build_object('field', 'sort_order'));
  end if;
  v_active := coalesce((p ->> 'is_active')::boolean, true);

  if v_id is null then
    insert into public.dining_tables (shop_id, name, sort_order, is_active)
    values (v_profile.shop_id, v_name, v_sort, v_active)
    returning * into v_table;
  else
    update public.dining_tables
    set name = v_name, sort_order = v_sort, is_active = v_active
    where id = v_id and shop_id = v_profile.shop_id
    returning * into v_table;
    if not found then
      perform private.raise_error('NOT_FOUND', 'The table does not exist.', jsonb_build_object('table_id', v_id));
    end if;
  end if;

  return jsonb_build_object(
    'id', v_table.id,
    'name', v_table.name,
    'sort_order', v_table.sort_order,
    'is_active', v_table.is_active
  );
end;
$$;

revoke all on function public.save_dining_table(jsonb) from public;
grant execute on function public.save_dining_table(jsonb) to cafe_app;

-- ---------------------------------------------------------------------------------------------
-- record_sale again, with the table and the order item optional. Everything else is as migration
-- 20260911000011 left it.
create or replace function public.record_sale(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_terminal public.terminals;
  v_found record;
  v_session_id uuid;
  v_session public.cash_sessions;
  v_seq bigint;
  v_receipt text;
  v_kind text;
  v_lines jsonb;
  v_line jsonb;
  v_line_no integer := 0;
  v_product_id uuid;
  v_qty integer;
  v_unit bigint;
  v_line_discount bigint;
  v_line_reason text;
  v_share bigint;
  v_line_total bigint;
  v_table_id uuid;
  v_item_id uuid;
  v_item public.open_order_items;
  v_order_id uuid;
  v_item_ids uuid[] := '{}';
  v_refunds_line_id uuid;
  v_seen_refund_lines uuid[] := '{}';
  v_subtotal bigint := 0;
  v_discount bigint := 0;
  v_total bigint := 0;
  v_refunds_sale_id uuid;
  v_original public.sales;
  v_original_line public.sale_lines;
  v_prior_units bigint;
  v_prior_amount bigint;
  v_payment jsonb;
  v_method text;
  v_tendered bigint;
  v_change bigint;
  v_created_at timestamptz;
  v_constraint text;
begin
  -- 1. Who is calling. A waiter carries no register: selling is for the caisse and the admin.
  v_profile := private.require_profile(array['admin', 'cashier']);
  p := private.json_alias(p, 'cart_discount_millimes', array['discount_millimes']);
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  -- 2. Serialise all writes for this terminal before reading anything else.
  v_terminal := private.lock_terminal(v_profile.shop_id, p);

  -- 3. Idempotency: a record already recorded or voided returns its stored outcome.
  select s.shop_id, s.payload_hash, s.receipt_number into v_found from public.sales s where s.id = v_id;
  if found then
    if v_found.shop_id <> v_profile.shop_id then
      perform private.raise_error('FORBIDDEN', 'This record belongs to another shop.');
    end if;
    if v_found.payload_hash <> v_hash then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
    end if;
    return jsonb_build_object('sale_id', v_id, 'receipt_number', v_found.receipt_number, 'status', 'replayed');
  end if;

  select rv.shop_id, rv.payload_hash, rv.receipt_number into v_found from public.receipt_voids rv where rv.id = v_id;
  if found then
    if v_found.shop_id <> v_profile.shop_id then
      perform private.raise_error('FORBIDDEN', 'This record belongs to another shop.');
    end if;
    if v_found.payload_hash <> v_hash then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
    end if;
    return jsonb_build_object('sale_id', v_id, 'receipt_number', v_found.receipt_number, 'status', 'voided');
  end if;

  -- 4. The device holds the current registration.
  perform private.require_epoch(v_terminal, p);

  -- 5. The session exists, is open and belongs to this terminal.
  v_session_id := private.json_uuid(p, 'session_id');
  select * into v_session from public.cash_sessions where id = v_session_id;
  if not found then
    perform private.raise_error('NOT_FOUND', 'The session does not exist.', jsonb_build_object('session_id', v_session_id));
  end if;
  if v_session.shop_id <> v_profile.shop_id or v_session.terminal_id <> v_terminal.id then
    perform private.raise_error('FORBIDDEN', 'The session does not belong to this terminal.', jsonb_build_object('session_id', v_session_id));
  end if;
  if v_session.closed_at is not null then
    perform private.raise_error('SESSION_CLOSED', 'The session was closed before this record arrived.', jsonb_build_object('session_id', v_session_id));
  end if;

  -- 6. Gapless numbering: exactly the next number of this terminal.
  v_seq := private.json_bigint(p, 'seq');
  if v_seq <> v_terminal.last_seq + 1 then
    perform private.raise_error(
      'SEQUENCE_GAP',
      format('Expected receipt %s-%s.', v_terminal.code, v_terminal.last_seq + 1),
      jsonb_build_object('expected_seq', v_terminal.last_seq + 1, 'received_seq', v_seq)
    );
  end if;
  v_receipt := v_terminal.code || '-' || v_seq;

  -- 7. The document: every amount is recomputed from the lines.
  v_kind := private.json_text(p, 'kind');
  if v_kind not in ('sale', 'refund') then
    perform private.raise_error('VALIDATION_ERROR', 'kind must be sale or refund.', jsonb_build_object('field', 'kind'));
  end if;

  v_lines := p -> 'lines';
  if v_lines is null or jsonb_typeof(v_lines) <> 'array' or jsonb_array_length(v_lines) = 0 then
    perform private.raise_error('VALIDATION_ERROR', 'A record needs at least one line.', jsonb_build_object('field', 'lines'));
  end if;
  -- Line amounts under the names the café model uses, whatever the device called them.
  select jsonb_agg(
           private.json_alias(
             private.json_alias(e.value, 'allocated_discount_millimes', array['cart_discount_share_millimes']),
             'net_millimes', array['line_total_millimes']
           )
           order by e.ord
         )
  into v_lines
  from jsonb_array_elements(v_lines) with ordinality as e(value, ord);
  p := jsonb_set(p, '{lines}', v_lines);

  if v_kind = 'sale' then
    -- A sale that names a table pays for items of that table's open order, so the table is part of
    -- the document and not an afterthought. A sale that names none is a counter sale — a coffee
    -- taken away — and pays no order item at all.
    v_table_id := private.json_uuid(p, 'table_id', false);
    if v_table_id is not null then
      if not exists (select 1 from public.dining_tables t where t.id = v_table_id and t.shop_id = v_profile.shop_id) then
        perform private.raise_error('FORBIDDEN', 'This table is not in your shop.', jsonb_build_object('table_id', v_table_id));
      end if;
      select o.id into v_order_id from public.open_orders o where o.table_id = v_table_id and o.status = 'open';
      if v_order_id is null then
        perform private.raise_error(
          'ORDER_CLOSED', 'That table has no open order any more.',
          jsonb_build_object('table_id', v_table_id)
        );
      end if;
    end if;
  else
    if p ? 'table_id' and jsonb_typeof(p -> 'table_id') <> 'null' then
      perform private.raise_error('VALIDATION_ERROR', 'A refund is not paid at a table.', jsonb_build_object('field', 'table_id'));
    end if;
    v_refunds_sale_id := private.json_uuid(p, 'refunds_sale_id');
    -- Refunds of one sale can arrive from several terminals: take them one at a time, and sum the
    -- earlier refunds only after holding the lock.
    perform pg_advisory_xact_lock(hashtextextended(v_refunds_sale_id::text, 0));
    select * into v_original from public.sales where id = v_refunds_sale_id and shop_id = v_profile.shop_id;
    if not found then
      perform private.raise_error('NOT_FOUND', 'The sale to refund does not exist.', jsonb_build_object('sale_id', v_refunds_sale_id));
    end if;
    if v_original.kind <> 'sale' then
      perform private.raise_error('VALIDATION_ERROR', 'Only a sale can be refunded, not a refund.', jsonb_build_object('field', 'refunds_sale_id'));
    end if;
  end if;

  for v_line in select e.value from jsonb_array_elements(v_lines) e
  loop
    v_line_no := v_line_no + 1;
    if jsonb_typeof(v_line) <> 'object' or private.json_int(v_line, 'line_no') <> v_line_no then
      perform private.raise_error('VALIDATION_ERROR', 'Lines must be numbered 1, 2, 3 in order.', jsonb_build_object('field', 'lines'));
    end if;
    v_product_id := private.json_uuid(v_line, 'product_id');
    perform private.json_text(v_line, 'product_name');
    v_qty := private.json_int(v_line, 'qty');
    v_unit := private.json_bigint(v_line, 'unit_price_millimes');
    v_line_discount := private.json_bigint(v_line, 'line_discount_millimes');
    v_line_reason := nullif(trim(coalesce(private.json_text(v_line, 'line_discount_reason', false), '')), '');
    v_share := private.json_bigint(v_line, 'allocated_discount_millimes');
    v_line_total := private.json_bigint(v_line, 'net_millimes');

    -- Archived products can still be sold offline and refunded.
    if not exists (select 1 from public.products pr where pr.id = v_product_id and pr.shop_id = v_profile.shop_id) then
      perform private.raise_error('NOT_FOUND', 'A line names a product that does not exist.', jsonb_build_object('product_id', v_product_id));
    end if;

    -- A unit price is a product price: at most one billion dinars, the bound
    -- src/ports/catalog.ts reads products and sale lines back with. The line total is qty x unit
    -- price, so it is not bounded the same way, and neither are the discounts or the totals.
    if v_unit > 1000000000000 then
      perform private.raise_error('VALIDATION_ERROR', 'A unit price cannot be above one billion dinars.', jsonb_build_object('line_no', v_line_no));
    end if;

    if v_kind = 'sale' then
      if private.json_first(v_line, array['refunds_sale_line_id', 'refunds_line_no']) is not null then
        perform private.raise_error('VALIDATION_ERROR', 'A sale line cannot refund another line.', jsonb_build_object('line_no', v_line_no));
      end if;

      -- The order item this line pays for, when it pays one. Anything that moved under the terminal
      -- — paid, removed, on another table, or no longer the same product, quantity or price — is
      -- ORDER_CHANGED, and the terminal refreshes the table and pays again.
      --
      -- A line with no item is a product sold across the counter. It is legal on a bill that also
      -- pays a table: the guest at table 4 who buys a packet of cigarettes on the way out is one
      -- payment, and the cigarettes were never on the table. It marks no item paid, so a mixed bill
      -- settles exactly the rows it names and the order closes when nothing unpaid is left.
      v_item_id := private.json_uuid(v_line, 'open_order_item_id', false);
      if v_item_id is not null and v_table_id is null then
        perform private.raise_error(
          'VALIDATION_ERROR', 'A sale that pays a table must name it.',
          jsonb_build_object('line_no', v_line_no, 'field', 'table_id')
        );
      end if;
      if v_item_id is not null then
        if v_item_id = any (v_item_ids) then
          perform private.raise_error('VALIDATION_ERROR', 'An order item can appear on only one line.', jsonb_build_object('line_no', v_line_no));
        end if;
        v_item_ids := v_item_ids || v_item_id;

        select * into v_item
        from public.open_order_items
        where id = v_item_id and shop_id = v_profile.shop_id
        for update;
        if not found or v_item.order_id <> v_order_id or v_item.removed_at is not null or v_item.paid_sale_id is not null
           or v_item.product_id <> v_product_id or v_item.qty <> v_qty or v_item.unit_price_millimes <> v_unit then
          perform private.raise_error(
            'ORDER_CHANGED',
            'This table changed while it was being paid for. Look at it again.',
            jsonb_build_object('table_id', v_table_id, 'item_id', v_item_id, 'line_no', v_line_no)
          );
        end if;
      end if;

      if v_qty < 1 or v_unit < 0 or v_line_discount < 0 or v_share < 0
         or v_line_discount + v_share > v_qty * v_unit
         or v_line_total <> v_qty * v_unit - v_line_discount - v_share then
        perform private.raise_error('VALIDATION_ERROR', 'Line amounts do not add up.', jsonb_build_object('line_no', v_line_no));
      end if;
      -- An offered item or a discounted line always says why.
      if v_line_discount > 0 and v_line_reason is null then
        perform private.raise_error('VALIDATION_ERROR', 'Say why this line is discounted.', jsonb_build_object('line_no', v_line_no, 'field', 'line_discount_reason'));
      end if;
      v_subtotal := v_subtotal + v_qty * v_unit - v_line_discount;
      v_discount := v_discount + v_share;
    else
      if v_line_reason is not null then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line carries no discount.', jsonb_build_object('line_no', v_line_no));
      end if;
      if private.json_first(v_line, array['open_order_item_id']) is not null then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line pays no order item.', jsonb_build_object('line_no', v_line_no));
      end if;

      -- The line being refunded, by its own id. A payload written before the café model names the
      -- line's number on the original sale instead; both end up at the same row.
      v_refunds_line_id := private.json_uuid(v_line, 'refunds_sale_line_id', false);
      if v_refunds_line_id is null then
        select sl.id into v_refunds_line_id
        from public.sale_lines sl
        where sl.sale_id = v_original.id and sl.line_no = private.json_int(v_line, 'refunds_line_no');
      end if;
      if v_refunds_line_id is null then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line names a line that is not on the sale.', jsonb_build_object('line_no', v_line_no));
      end if;
      if v_refunds_line_id = any (v_seen_refund_lines) then
        perform private.raise_error('VALIDATION_ERROR', 'An original line can appear only once in a refund.', jsonb_build_object('line_no', v_line_no));
      end if;
      v_seen_refund_lines := v_seen_refund_lines || v_refunds_line_id;

      select * into v_original_line from public.sale_lines where id = v_refunds_line_id and sale_id = v_original.id;
      if not found then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line names a line that is not on the sale.', jsonb_build_object('line_no', v_line_no));
      end if;
      if v_product_id <> v_original_line.product_id or v_unit <> v_original_line.unit_price_millimes
         or v_line_discount <> 0 or v_share <> 0 or v_qty > -1 or v_line_total > 0 then
        perform private.raise_error('VALIDATION_ERROR', 'A refund line must match its sale line, with a negative quantity and amount.', jsonb_build_object('line_no', v_line_no));
      end if;

      select coalesce(sum(-sl.qty), 0), coalesce(sum(-sl.line_total_millimes), 0)
      into v_prior_units, v_prior_amount
      from public.sale_lines sl
      join public.sales s on s.id = sl.sale_id
      where s.refunds_sale_id = v_original.id and sl.refunds_sale_line_id = v_refunds_line_id;

      -- Units and amount stay within what is left, and the refund that takes a line's last units
      -- pays exactly what is left of it, so the parts of a line always add up to its total.
      if v_prior_units - v_qty > v_original_line.qty
         or v_prior_amount - v_line_total > v_original_line.line_total_millimes then
        perform private.raise_error(
          'VALIDATION_ERROR',
          'The refund is more than what is left to refund on this line.',
          jsonb_build_object(
            'line_no', v_line_no,
            'remaining_qty', v_original_line.qty - v_prior_units,
            'remaining_millimes', v_original_line.line_total_millimes - v_prior_amount
          )
        );
      end if;
      if v_prior_units - v_qty = v_original_line.qty
         and v_prior_amount - v_line_total <> v_original_line.line_total_millimes then
        perform private.raise_error(
          'VALIDATION_ERROR',
          'A refund of the last units of a line pays exactly what is left of it.',
          jsonb_build_object(
            'line_no', v_line_no,
            'remaining_qty', v_original_line.qty - v_prior_units,
            'remaining_millimes', v_original_line.line_total_millimes - v_prior_amount
          )
        );
      end if;
      v_subtotal := v_subtotal + v_line_total;
      v_line := jsonb_set(v_line, '{refunds_sale_line_id}', to_jsonb(v_refunds_line_id));
      v_lines := jsonb_set(v_lines, array[(v_line_no - 1)::text], v_line);
    end if;
    v_total := v_total + v_line_total;
  end loop;

  -- subtotal_millimes is derived, so a payload that leaves it out is fine; one that states it has
  -- to state the same number the lines add up to.
  if (p ? 'subtotal_millimes' and jsonb_typeof(p -> 'subtotal_millimes') <> 'null'
      and private.json_bigint(p, 'subtotal_millimes') <> v_subtotal)
     or private.json_bigint(p, 'cart_discount_millimes') <> v_discount
     or private.json_bigint(p, 'total_millimes') <> v_total then
    perform private.raise_error(
      'VALIDATION_ERROR',
      'The document totals do not match its lines.',
      jsonb_build_object('subtotal_millimes', v_subtotal, 'cart_discount_millimes', v_discount, 'total_millimes', v_total)
    );
  end if;

  -- Payment. Change only exists for cash; a refund pays out exactly its total.
  v_payment := p -> 'payment';
  if v_payment is null or jsonb_typeof(v_payment) <> 'object' then
    perform private.raise_error('VALIDATION_ERROR', 'payment is required.', jsonb_build_object('field', 'payment'));
  end if;
  v_method := private.json_text(v_payment, 'method');
  v_tendered := private.json_bigint(v_payment, 'tendered_millimes');
  v_change := private.json_bigint(v_payment, 'change_millimes');
  if v_method not in ('cash', 'card') then
    perform private.raise_error('VALIDATION_ERROR', 'The payment method must be cash or card.', jsonb_build_object('field', 'payment.method'));
  end if;
  if v_kind = 'refund' or v_method = 'card' then
    if v_tendered <> v_total or v_change <> 0 then
      perform private.raise_error('VALIDATION_ERROR', 'Card payments and refunds are exactly the total, with no change.', jsonb_build_object('field', 'payment'));
    end if;
  elsif v_tendered < v_total or v_change <> v_tendered - v_total then
    perform private.raise_error('VALIDATION_ERROR', 'Change must be the amount tendered minus the total.', jsonb_build_object('field', 'payment'));
  end if;

  v_created_at := private.json_timestamptz(p, 'created_at');

  -- 8. Write. Products are locked in id order so two terminals never deadlock on stock.
  perform 1
  from public.products pr
  where pr.shop_id = v_profile.shop_id
    and pr.id in (select (e.value ->> 'product_id')::uuid from jsonb_array_elements(v_lines) e)
  order by pr.id
  for update;

  begin
    insert into public.sales (
      id, shop_id, terminal_id, session_id, kind, seq, receipt_number, refunds_sale_id, table_id, payment_method,
      subtotal_millimes, cart_discount_millimes, total_millimes, tendered_millimes, change_millimes,
      epoch, payload_hash, submitted_by, created_at
    )
    values (
      v_id, v_profile.shop_id, v_terminal.id, v_session.id, v_kind, v_seq, v_receipt, v_refunds_sale_id, v_table_id, v_method,
      v_subtotal, v_discount, v_total, v_tendered, v_change,
      v_terminal.epoch, v_hash, v_profile.user_id, v_created_at
    );
  exception when unique_violation then
    -- Another terminal stored a record under the same id after the idempotency check above.
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint in ('sales_pkey', 'sales_id_shop_id_key') then
      perform private.raise_error('IDEMPOTENCY_CONFLICT', 'A different record was already stored under this id.', jsonb_build_object('id', v_id));
    end if;
    raise;
  end;

  for v_line in select e.value from jsonb_array_elements(v_lines) e
  loop
    v_qty := (v_line ->> 'qty')::integer;
    v_product_id := (v_line ->> 'product_id')::uuid;
    -- The line keeps the row id the device gave it. A register that sold offline and is refunding
    -- the same receipt has to name the lines it gives back before either record has been stored,
    -- so the row id of a line cannot be the server's to invent. A payload written before the café
    -- model names no id, and the column's default gives it one, as it always did.
    insert into public.sale_lines (
      id, sale_id, shop_id, line_no, product_id, product_name, qty, unit_price_millimes,
      line_discount_millimes, line_discount_reason, allocated_discount_millimes, line_total_millimes,
      open_order_item_id, refunds_sale_line_id
    )
    values (
      coalesce(private.json_uuid(v_line, 'id', false), gen_random_uuid()),
      v_id, v_profile.shop_id, (v_line ->> 'line_no')::integer, v_product_id, v_line ->> 'product_name', v_qty,
      (v_line ->> 'unit_price_millimes')::bigint, (v_line ->> 'line_discount_millimes')::bigint,
      nullif(trim(coalesce(v_line ->> 'line_discount_reason', '')), ''),
      (v_line ->> 'allocated_discount_millimes')::bigint, (v_line ->> 'net_millimes')::bigint,
      (v_line ->> 'open_order_item_id')::uuid, (v_line ->> 'refunds_sale_line_id')::uuid
    );
    -- A sale takes units out of stock; a refund puts them back, for the products the shop counts.
    -- Stock never blocks a sale and may go negative.
    if (select pr.track_stock from public.products pr where pr.id = v_product_id) then
      perform private.move_stock(
        v_profile.shop_id, v_product_id, -v_qty,
        case when v_kind = 'sale' then 'sale' else 'refund' end,
        v_id, '', v_profile.user_id
      );
    end if;
  end loop;

  -- The items this sale paid for, and the table it leaves behind: an order with nothing unpaid
  -- left on it closes, so a table can be paid in parts and is free when the last part is settled.
  -- A counter sale names no items and no order, so both of these touch nothing: the empty array
  -- updates no row and close_order_if_settled(null) finds none. No branch needed to say so.
  if v_kind = 'sale' then
    update public.open_order_items set paid_sale_id = v_id where id = any (v_item_ids);
    perform private.close_order_if_settled(v_order_id);
  end if;

  update public.terminals set last_seq = v_seq where id = v_terminal.id;

  return jsonb_build_object('sale_id', v_id, 'receipt_number', v_receipt, 'status', 'created');
end;
$$;

revoke all on function public.record_sale(jsonb) from public;
grant execute on function public.record_sale(jsonb) to cafe_app;
-- ---------------------------------------------------------------------------------------------
-- from 20260913000014_dining_table_names.sql
-- Two tables of one café cannot share a name.
--
-- dining_tables has held unique (shop_id, name) since migration 20260911000010, but save_dining_table
-- let a clash out as a bare unique_violation, which reaches the app as UNKNOWN: an error the admin's
-- form cannot explain and the error contract (contracts/errors.md) does not allow. This answers it the
-- way save_product answers a barcode already in use — VALIDATION_ERROR naming the field — and changes
-- nothing else about the function migration 20260911000013 wrote.

create or replace function public.save_dining_table(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_name text;
  v_sort integer;
  v_active boolean;
  v_table public.dining_tables;
begin
  v_profile := private.require_profile(array['admin']);
  v_id := private.json_uuid(p, 'id', false);
  v_name := nullif(trim(private.json_text(p, 'name')), '');
  if v_name is null then
    perform private.raise_error('VALIDATION_ERROR', 'A table needs a name.', jsonb_build_object('field', 'name'));
  end if;
  v_sort := private.json_int(p, 'sort_order');
  if v_sort < 0 then
    perform private.raise_error('VALIDATION_ERROR', 'A table cannot sort before the first one.', jsonb_build_object('field', 'sort_order'));
  end if;
  v_active := coalesce((p ->> 'is_active')::boolean, true);

  begin
    if v_id is null then
      insert into public.dining_tables (shop_id, name, sort_order, is_active)
      values (v_profile.shop_id, v_name, v_sort, v_active)
      returning * into v_table;
    else
      update public.dining_tables
      set name = v_name, sort_order = v_sort, is_active = v_active
      where id = v_id and shop_id = v_profile.shop_id
      returning * into v_table;
      if not found then
        perform private.raise_error('NOT_FOUND', 'The table does not exist.', jsonb_build_object('table_id', v_id));
      end if;
    end if;
  exception when unique_violation then
    -- The only unique key a save can break besides the generated id is (shop_id, name).
    perform private.raise_error('VALIDATION_ERROR', 'Another table already has this name.', jsonb_build_object('field', 'name'));
  end;

  return jsonb_build_object(
    'id', v_table.id,
    'name', v_table.name,
    'sort_order', v_table.sort_order,
    'is_active', v_table.is_active
  );
end;
$$;

revoke all on function public.save_dining_table(jsonb) from public;
grant execute on function public.save_dining_table(jsonb) to cafe_app;
-- ---------------------------------------------------------------------------------------------
-- from 20260913000015_removal_submitted_by.sql
-- The login a removal was sent under, beside the person it names.
--
-- An order record names its author (actor_user_id, read by private.order_actor), and the server can
-- only check that the author belongs to the shop: a phone passed from one waiter to the next sends the
-- first one's records under the second one's login, and that is the case the author is for. It also
-- means removed_by is the device's word. order_records.submitted_by has always kept the login each
-- record was sent under, but nothing tied a removed item to its record, so the removed-after-sent
-- report could not show it.
--
-- This stamps that login on the item as a removal or a cancel takes it off, and the report returns it
-- next to the author: an admin sees when a removal names someone other than the login that sent it.
-- An item taken off before this migration has none — who sent it was never written down — and the
-- report says nothing about it. Nothing else about the three functions migration 20260911000011
-- wrote changes.

alter table public.open_order_items
  add column removal_submitted_by uuid references public.users (id) on delete restrict,
  add constraint open_order_items_submitted_is_removed
    check (removal_submitted_by is null or removed_at is not null);

-- ---------------------------------------------------------------------------------------------
-- p = { id, item_id, reason, created_at, device_id, payload_hash, actor_user_id? }
-- Stamps removed_at and keeps the row: the admin's report of items removed after they were sent is
-- the reason the row stays. Returns { status, order_id, affected }.
create or replace function public.order_item_remove(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_replay jsonb;
  v_item_id uuid;
  v_item public.open_order_items;
  v_order public.open_orders;
  v_reason text;
  v_actor uuid;
  v_affected integer := 0;
begin
  v_profile := private.require_profile(array['admin', 'cashier', 'waiter']);
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  v_replay := private.order_replay(v_profile.shop_id, v_id, v_hash);
  if v_replay is not null then
    return v_replay;
  end if;

  v_reason := private.json_reason(p, 'reason');
  v_item_id := private.json_uuid(p, 'item_id');
  select * into v_item
  from public.open_order_items
  where id = v_item_id and shop_id = v_profile.shop_id
  for update;
  if not found then
    perform private.raise_error('ITEM_NOT_FOUND', 'That item is not on any table.', jsonb_build_object('item_id', v_item_id));
  end if;

  select * into v_order from public.open_orders where id = v_item.order_id;
  if v_item.paid_sale_id is not null then
    perform private.raise_error(
      'ORDER_CHANGED', 'That item has already been paid for.',
      jsonb_build_object('table_id', v_order.table_id, 'item_id', v_item_id)
    );
  end if;
  if v_order.status <> 'open' then
    perform private.raise_error(
      'ORDER_CLOSED', 'That table has no open order any more.',
      jsonb_build_object('table_id', v_order.table_id, 'order_id', v_order.id)
    );
  end if;

  v_actor := private.order_actor(v_profile, p);
  -- Removing an item that is already off the table changes nothing and must never stop a queue.
  if v_item.removed_at is null then
    update public.open_order_items
    set removed_at = now(), removed_by = v_actor, removed_reason = v_reason,
        removal_submitted_by = v_profile.user_id
    where id = v_item_id;
    v_affected := 1;
    perform private.close_order_if_settled(v_order.id);
  end if;

  return private.order_record_store(
    v_profile.shop_id, v_id, 'order_item_remove', v_hash, p, v_profile.user_id,
    jsonb_build_object('status', 'created', 'order_id', v_order.id, 'affected', v_affected)
  );
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- p = { id, table_id, reason, created_at, device_id, payload_hash, actor_user_id? }
-- Cancels the table's open order. Its active items are stamped removed with the cancel's reason, so
-- a cancel of a sent order still reaches the removed-after-sent report.
-- Returns { status, order_id, affected }.
create or replace function public.order_cancel(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_hash text;
  v_replay jsonb;
  v_table public.dining_tables;
  v_order public.open_orders;
  v_reason text;
  v_actor uuid;
  v_paid uuid;
  v_affected integer;
begin
  v_profile := private.require_profile(array['admin', 'cashier']);
  v_id := private.json_uuid(p, 'id');
  v_hash := private.json_hash(p);

  v_replay := private.order_replay(v_profile.shop_id, v_id, v_hash);
  if v_replay is not null then
    return v_replay;
  end if;

  v_reason := private.json_reason(p, 'reason');
  v_table := private.lock_table(v_profile.shop_id, private.json_uuid(p, 'table_id'), false);
  select * into v_order from public.open_orders where table_id = v_table.id and status = 'open';
  if not found then
    perform private.raise_error(
      'ORDER_CLOSED', 'That table has no open order any more.',
      jsonb_build_object('table_id', v_table.id)
    );
  end if;

  select i.id into v_paid from public.open_order_items i where i.order_id = v_order.id and i.paid_sale_id is not null limit 1;
  if v_paid is not null then
    perform private.raise_error(
      'ORDER_CHANGED', 'Part of this order has already been paid for.',
      jsonb_build_object('table_id', v_table.id, 'order_id', v_order.id, 'item_id', v_paid)
    );
  end if;

  v_actor := private.order_actor(v_profile, p);
  update public.open_order_items
  set removed_at = now(), removed_by = v_actor, removed_reason = v_reason,
      removal_submitted_by = v_profile.user_id
  where order_id = v_order.id and removed_at is null;
  get diagnostics v_affected = row_count;

  update public.open_orders
  set status = 'cancelled', closed_at = now(), closed_reason = v_reason
  where id = v_order.id;

  return private.order_record_store(
    v_profile.shop_id, v_id, 'order_cancel', v_hash, p, v_profile.user_id,
    jsonb_build_object('status', 'created', 'order_id', v_order.id, 'affected', v_affected)
  );
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Admin report: what was taken off a table after the kitchen had already been told, per waiter.
-- That is the classic waiter fraud, so it is a report and not a footnote. Both ends of the period
-- are required; the rows come back newest first. submitted_by is the login the removal was sent
-- under, null for an item taken off before that was recorded.
create or replace function public.removed_after_sent(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
begin
  v_profile := private.require_profile(array['admin']);
  if p_from is null or p_to is null then
    perform private.raise_error('VALIDATION_ERROR', 'A report is always of a named period.', jsonb_build_object('field', 'from'));
  end if;
  if p_to < p_from then
    perform private.raise_error('VALIDATION_ERROR', 'The period ends before it starts.', jsonb_build_object('field', 'to'));
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'item_id', i.id,
          'table_name', t.name,
          'product_name', i.name_snapshot,
          'qty', i.qty,
          'unit_price_millimes', i.unit_price_millimes,
          'sent_at', i.sent_at,
          'removed_at', i.removed_at,
          'removed_by', i.removed_by,
          'removed_by_name', coalesce(pr.display_name, ''),
          'removed_reason', coalesce(i.removed_reason, ''),
          'submitted_by', i.removal_submitted_by,
          'submitted_by_name', case when i.removal_submitted_by is null then null else coalesce(sp.display_name, '') end
        )
        order by i.removed_at desc, i.id
      )
      from public.open_order_items i
      join public.open_orders o on o.id = i.order_id
      join public.dining_tables t on t.id = o.table_id
      left join public.profiles pr on pr.user_id = i.removed_by
      left join public.profiles sp on sp.user_id = i.removal_submitted_by
      where i.shop_id = v_profile.shop_id
        and i.sent_at is not null
        and i.removed_at is not null
        and i.removed_at >= p_from
        and i.removed_at <= p_to
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function
  public.order_item_remove(jsonb),
  public.order_cancel(jsonb),
  public.removed_after_sent(timestamptz, timestamptz)
from public;

grant execute on function
  public.order_item_remove(jsonb),
  public.order_cancel(jsonb),
  public.removed_after_sent(timestamptz, timestamptz)
to cafe_app;
-- ---------------------------------------------------------------------------------------------
-- from 20260913000016_save_product_cafe_fields.sql
-- save_product writes what the product form sends: whether the dish is on the menu, and whether its
-- stock is counted.
--
-- Migration 20260911000010 gave products `is_available` and `track_stock` and changed product_json to
-- answer them, but save_product kept the shape migration 20260911000004 wrote: it read neither key.
-- A product created from the form was never counted, however the admin set it, so a sale never
-- moved its stock; and an edit could not switch counting on or off. The contract suite on a local
-- stack found it: the memory backend saves both, as src/ports/catalog.ts says.
--
-- A payload that leaves a key out is from a client older than the café model. A new product is then
-- on the menu and not counted, as the columns' defaults have it, and a saved product keeps what it
-- had. Nothing else about the function changes.

-- A boolean field of a payload: null when the payload does not carry it, VALIDATION_ERROR naming the
-- field when it carries anything but true or false.
create or replace function private.json_bool(p jsonb, p_key text)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
begin
  if not (p ? p_key) or jsonb_typeof(p -> p_key) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p -> p_key) <> 'boolean' then
    perform private.raise_error('VALIDATION_ERROR', format('%s must be true or false.', p_key), jsonb_build_object('field', p_key));
  end if;
  return (p -> p_key)::boolean;
end;
$$;

-- Creates (no id) or updates (id) a product. Stock changes only by `stock_delta`, written as an
-- 'opening' movement for a new product or an 'adjustment' for an existing one, in this transaction.
create or replace function public.save_product(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_id uuid;
  v_name text;
  v_price bigint;
  v_category uuid;
  v_barcode text;
  v_description text;
  v_image_url text;
  v_delta integer;
  v_available boolean;
  v_track boolean;
  v_product public.products;
begin
  v_profile := private.require_profile(array['admin']);

  v_id := private.json_uuid(p, 'id', false);
  v_name := trim(private.json_text(p, 'name'));
  v_price := private.json_bigint(p, 'price_millimes');
  v_category := private.json_uuid(p, 'category_id', false);
  v_barcode := nullif(trim(coalesce(private.json_text(p, 'barcode', false), '')), '');
  v_description := coalesce(private.json_text(p, 'description', false), '');
  v_image_url := coalesce(private.json_text(p, 'image_url', false), '');
  v_delta := private.json_int(p, 'stock_delta');
  v_available := private.json_bool(p, 'is_available');
  v_track := private.json_bool(p, 'track_stock');

  if v_name = '' then
    perform private.raise_error('VALIDATION_ERROR', 'Product name is required.', jsonb_build_object('field', 'name'));
  end if;
  if v_price < 0 then
    perform private.raise_error('VALIDATION_ERROR', 'Price cannot be negative.', jsonb_build_object('field', 'price_millimes'));
  end if;
  -- One billion dinars, the bound src/ports/catalog.ts reads rows back with.
  if v_price > 1000000000000 then
    perform private.raise_error('VALIDATION_ERROR', 'Price cannot be above one billion dinars.', jsonb_build_object('field', 'price_millimes'));
  end if;
  if v_category is not null and not exists (
    select 1 from public.categories c where c.id = v_category and c.shop_id = v_profile.shop_id
  ) then
    perform private.raise_error('VALIDATION_ERROR', 'The category does not exist.', jsonb_build_object('field', 'category_id'));
  end if;

  begin
    if v_id is null then
      if v_delta < 0 then
        perform private.raise_error('VALIDATION_ERROR', 'A new product cannot start with negative stock.', jsonb_build_object('field', 'stock_delta'));
      end if;
      insert into public.products (
        shop_id, category_id, name, price_millimes, barcode, description, image_url, is_available, track_stock
      )
      values (
        v_profile.shop_id, v_category, v_name, v_price, v_barcode, v_description, v_image_url,
        coalesce(v_available, true), coalesce(v_track, false)
      )
      returning * into v_product;
      perform private.move_stock(v_profile.shop_id, v_product.id, v_delta, 'opening', null, '', v_profile.user_id);
    else
      update public.products
      set category_id = v_category,
          name = v_name,
          price_millimes = v_price,
          barcode = v_barcode,
          description = v_description,
          image_url = v_image_url,
          is_available = coalesce(v_available, is_available),
          track_stock = coalesce(v_track, track_stock),
          updated_at = now()
      where id = v_id and shop_id = v_profile.shop_id and archived_at is null
      returning * into v_product;
      if not found then
        perform private.raise_error('NOT_FOUND', 'The product does not exist.', jsonb_build_object('product_id', v_id));
      end if;
      perform private.move_stock(v_profile.shop_id, v_product.id, v_delta, 'adjustment', null, '', v_profile.user_id);
    end if;
  exception when unique_violation then
    perform private.raise_error('VALIDATION_ERROR', 'Another product already uses this barcode.', jsonb_build_object('field', 'barcode'));
  end;

  select * into v_product from public.products where id = v_product.id;
  return private.product_json(v_product);
end;
$$;

revoke all on function private.json_bool(jsonb, text) from public;

revoke all on function public.save_product(jsonb) from public;
grant execute on function public.save_product(jsonb) to cafe_app;
-- ---------------------------------------------------------------------------------------------
-- Last, because the grants above revoke every function of the private schema from everyone: the
-- role the API connects as may ask which member it is acting for. It reads a setting that role put
-- there itself, so there is nothing to hide, and a support session can see who a connection is.
grant execute on function private.current_user_id() to cafe_app;

-- The shape of a product on the wire is one function, so a read and a save answer the same thing.
grant execute on function private.product_json(public.products) to cafe_app;
