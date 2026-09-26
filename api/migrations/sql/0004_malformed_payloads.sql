-- Three malformed payloads that were answered SERVER_ERROR, and are VALIDATION_ERROR naming the field
-- or the line. Written first as Supabase migration 20260926000017 and converted the way
-- 0001_schema.sql was; a migration of its own rather than more lines in 0001_schema.sql, because
-- Doctrine has already run that one everywhere and a database that has will never run it again.

-- ---------------------------------------------------------------------------------------------
-- from 20260926000017_malformed_payloads.sql
-- Three malformed payloads that were answered SERVER_ERROR, and are VALIDATION_ERROR naming the field
-- or the line.
--
-- These functions read their payloads through the typed readers of migration 20260911000002 and refuse
-- through private.raise_error, so a malformed field is VALIDATION_ERROR naming it. Three places did
-- not, and a malformed payload reached a cast, an integer overflow or a column's check instead: an
-- error nobody raised on purpose, which reaches a device as SERVER_ERROR. contracts/errors.md classes
-- SERVER_ERROR as retriable, so the device sends the same payload again, with backoff, for ever. For a
-- sale or a refund that stops the whole queue: a ledger record can never be discarded, so the register
-- holding one retries it without end and nobody is ever shown the line that is wrong.
--
--   save_dining_table  read is_active with a bare cast. A value Postgres cannot read as a boolean
--                      ("maybe", 2) failed the cast, and one it can ("yes", "off", "1") was taken as
--                      a boolean the contract never sends. It reads it with private.json_bool, as
--                      save_product does since migration 20260913000016: true, false, or absent.
--   record_sale        multiplied the quantity by the unit price in bigint before checking the line.
--                      The price is capped at one billion dinars but the quantity is any integer, and
--                      a large enough pair overflowed. The product is now worked out in numeric, so
--                      it is exact and such a line fails the check it was always going to fail - its
--                      amounts do not add up - naming itself. The quantity is not capped instead: the
--                      memory backend multiplies in BigInt with no cap (src/adapters/memory/sales.ts),
--                      and in numeric every payload gets the answer it gets there.
--   void_receipt       stored error_code without checking it for blankness, which receipt_voids
--                      refuses. It reads it with private.json_reason, as the order records read their
--                      reason: required, trimmed, not blank.
--
-- Nothing else about the three functions changes.

-- save_dining_table as migration 20260913000014 left it, reading is_active through private.json_bool.
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
  v_active := coalesce(private.json_bool(p, 'is_active'), true);

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
-- record_sale as migration 20260911000013 left it, multiplying a line's quantity and unit price in
-- numeric.
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
  v_gross numeric;
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

      -- Quantity times unit price, exactly. Worked out in bigint, a quantity of millions at a price
      -- near the cap above overflowed before the line was checked at all, and a line that does not
      -- add up came back as a server error. Once the check below has passed it is the sum of three
      -- amounts json_bigint bounded, so the subtotal holds it.
      v_gross := v_qty::numeric * v_unit;
      if v_qty < 1 or v_unit < 0 or v_line_discount < 0 or v_share < 0
         or v_line_discount + v_share > v_gross
         or v_line_total <> v_gross - v_line_discount - v_share then
        perform private.raise_error('VALIDATION_ERROR', 'Line amounts do not add up.', jsonb_build_object('line_no', v_line_no));
      end if;
      -- An offered item or a discounted line always says why.
      if v_line_discount > 0 and v_line_reason is null then
        perform private.raise_error('VALIDATION_ERROR', 'Say why this line is discounted.', jsonb_build_object('line_no', v_line_no, 'field', 'line_discount_reason'));
      end if;
      v_subtotal := v_subtotal + v_gross - v_line_discount;
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
-- void_receipt as migration 20260911000006 left it, reading error_code through private.json_reason.
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
  v_error_code := private.json_reason(p, 'error_code');
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

revoke all on function public.void_receipt(jsonb) from public;
grant execute on function public.void_receipt(jsonb) to cafe_app;