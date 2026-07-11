-- Payment integrity: server-owned checkout records, a deduplicated webhook
-- event ledger, and an atomic entitlement-granting function.
--
-- Design goals:
--   * A payment can only grant an entitlement when it matches a checkout
--     record that the backend created for a specific authenticated user.
--   * The first accepted payment transitions the profile to paid exactly once
--     (null-safe), and duplicate deliveries are no-ops.
--   * Verified events for unknown/deleted users are still recorded for
--     reconciliation without a foreign-key failure (claimed_user_id is not an FK).

-- Checkout records the backend creates before redirecting to Dodo. The webhook
-- must find and atomically consume a matching, unexpired record.
create table if not exists public.danotch_checkout_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.danotch_user_profiles (id) on delete cascade,
  dodo_session_id text unique,
  product_id text not null,
  expected_amount integer not null,
  expected_currency text not null,
  expected_quantity integer not null default 1,
  environment text not null,
  status text not null default 'pending', -- pending | consumed | expired
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '1 hour'),
  consumed_at timestamptz
);

create index if not exists danotch_checkout_records_user_idx
  on public.danotch_checkout_records (user_id);
create index if not exists danotch_checkout_records_session_idx
  on public.danotch_checkout_records (dodo_session_id);

-- Deduplicated ledger of verified webhook deliveries. claimed_user_id records the
-- user id carried in the event even when no profile exists, so unknown-profile
-- deliveries are auditable. delivery_id (webhook-id) and payment_id are unique.
create table if not exists public.danotch_payment_events (
  id uuid primary key default gen_random_uuid(),
  delivery_id text unique,
  payment_id text not null unique,
  claimed_user_id text,
  profile_id uuid references public.danotch_user_profiles (id) on delete set null,
  event_type text not null,
  amount integer,
  currency text,
  product_id text,
  outcome text not null, -- granted | duplicate | unknown_profile | rejected
  error text,
  created_at timestamptz not null default now()
);

create index if not exists danotch_payment_events_profile_idx
  on public.danotch_payment_events (profile_id);

-- Atomically consume a checkout record, record the delivery, and grant the
-- entitlement. Returns the outcome so the caller can choose the HTTP response.
-- Outcomes:
--   granted          – first eligible payment; profile is now paid
--   duplicate        – payment_id/delivery already recorded; no mutation
--   unknown_profile  – no matching profile; recorded for reconciliation
--   rejected         – no matching unexpired checkout record for this user
create or replace function public.danotch_record_payment(
  p_delivery_id text,
  p_payment_id text,
  p_claimed_user_id text,
  p_customer_id text,
  p_event_type text,
  p_amount integer,
  p_currency text,
  p_product_id text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid;
  v_checkout public.danotch_checkout_records%rowtype;
  v_outcome text;
begin
  -- Idempotency: a previously recorded payment or delivery is a no-op.
  if exists (
    select 1 from public.danotch_payment_events
    where payment_id = p_payment_id
       or (p_delivery_id is not null and delivery_id = p_delivery_id)
  ) then
    return 'duplicate';
  end if;

  -- Resolve the claimed user to a real profile.
  begin
    v_profile_id := p_claimed_user_id::uuid;
  exception when others then
    v_profile_id := null;
  end;

  if v_profile_id is not null then
    if not exists (select 1 from public.danotch_user_profiles where id = v_profile_id) then
      v_profile_id := null;
    end if;
  end if;

  if v_profile_id is null then
    insert into public.danotch_payment_events
      (delivery_id, payment_id, claimed_user_id, profile_id, event_type, amount, currency, product_id, outcome)
    values
      (p_delivery_id, p_payment_id, p_claimed_user_id, null, p_event_type, p_amount, p_currency, p_product_id, 'unknown_profile');
    return 'unknown_profile';
  end if;

  -- Require a matching, unexpired, unconsumed checkout record for this user.
  select * into v_checkout
  from public.danotch_checkout_records
  where user_id = v_profile_id
    and status = 'pending'
    and expires_at > now()
    and product_id = p_product_id
    and expected_amount = p_amount
    and expected_currency = p_currency
  order by created_at desc
  limit 1
  for update;

  if not found then
    insert into public.danotch_payment_events
      (delivery_id, payment_id, claimed_user_id, profile_id, event_type, amount, currency, product_id, outcome, error)
    values
      (p_delivery_id, p_payment_id, p_claimed_user_id, v_profile_id, p_event_type, p_amount, p_currency, p_product_id, 'rejected',
       'no matching unexpired checkout record');
    return 'rejected';
  end if;

  update public.danotch_checkout_records
  set status = 'consumed', consumed_at = now()
  where id = v_checkout.id;

  -- Grant only if not already paid for a different payment (null-safe first grant).
  update public.danotch_user_profiles
  set
    billing_status = 'paid',
    lifetime_purchased_at = coalesce(lifetime_purchased_at, now()),
    dodo_customer_id = p_customer_id,
    dodo_payment_id = coalesce(dodo_payment_id, p_payment_id)
  where id = v_profile_id;

  v_outcome := 'granted';

  insert into public.danotch_payment_events
    (delivery_id, payment_id, claimed_user_id, profile_id, event_type, amount, currency, product_id, outcome)
  values
    (p_delivery_id, p_payment_id, p_claimed_user_id, v_profile_id, p_event_type, p_amount, p_currency, p_product_id, v_outcome);

  return v_outcome;
end;
$$;

revoke all on function public.danotch_record_payment(text, text, text, text, text, integer, text, text) from public;
