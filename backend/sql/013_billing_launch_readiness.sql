-- Launch-ready one-time billing.
--
-- Policy:
--   * one unexpired checkout exists per user/product/environment;
--   * a payment grants lifetime access only when it names the exact internal
--     checkout record and the exact attached Dodo checkout session;
--   * verified full refunds and terminal lost/accepted disputes revoke the
--     currently-backed lifetime entitlement, while preserving purchase history;
--   * a later successful purchase restores lifetime access.

alter table public.danotch_checkout_records
  add column checkout_url text,
  add column idempotency_key text,
  add column attached_at timestamptz;

update public.danotch_checkout_records
set idempotency_key = 'checkout:' || id::text
where idempotency_key is null;

alter table public.danotch_checkout_records
  alter column idempotency_key set not null,
  add constraint danotch_checkout_records_idempotency_key_key unique (idempotency_key);

update public.danotch_checkout_records
set status = 'expired'
where status = 'pending' and expires_at <= now();

with ranked as (
  select id, row_number() over (
    partition by user_id, product_id, environment
    order by created_at desc, id desc
  ) as position
  from public.danotch_checkout_records
  where status = 'pending'
)
update public.danotch_checkout_records checkout
set status = 'expired'
from ranked
where checkout.id = ranked.id and ranked.position > 1;

alter table public.danotch_checkout_records
  drop constraint danotch_checkout_records_status_check,
  add constraint danotch_checkout_records_status_check
    check (status in ('pending', 'active', 'consumed', 'expired'));

create unique index danotch_checkout_records_one_active_idx
  on public.danotch_checkout_records(user_id, product_id, environment)
  where status in ('pending', 'active');

alter table public.danotch_user_profiles
  add column lifetime_revoked_at timestamptz,
  add column lifetime_revocation_reason text;

grant select (lifetime_revoked_at)
  on public.danotch_user_profiles to authenticated;

alter table public.danotch_user_profiles
  drop constraint danotch_user_profiles_billing_status_check,
  add constraint danotch_user_profiles_billing_status_check
    check (billing_status in ('trialing', 'paid', 'expired', 'revoked'));

alter table public.danotch_payment_events
  add column checkout_record_id uuid
    references public.danotch_checkout_records(id) on delete set null,
  add column provider_event_id text;

update public.danotch_payment_events
set provider_event_id = payment_id
where provider_event_id is null;

alter table public.danotch_payment_events
  alter column provider_event_id set not null,
  drop constraint danotch_payment_events_payment_id_key,
  drop constraint danotch_payment_events_outcome_check,
  add constraint danotch_payment_events_outcome_check
    check (outcome in (
      'processing', 'granted', 'duplicate', 'unknown_profile',
      'rejected', 'revoked', 'ignored'
    ));

create unique index danotch_payment_events_semantic_event_uidx
  on public.danotch_payment_events(event_type, provider_event_id);
create index danotch_payment_events_payment_idx
  on public.danotch_payment_events(payment_id);
create index danotch_payment_events_checkout_idx
  on public.danotch_payment_events(checkout_record_id);

create or replace function public.danotch_reserve_checkout(
  p_user_id uuid,
  p_product_id text,
  p_expected_amount integer,
  p_expected_currency text,
  p_expected_quantity integer,
  p_environment text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  checkout public.danotch_checkout_records;
begin
  if p_product_id = ''
    or p_expected_amount <= 0
    or p_expected_quantity <= 0
    or upper(p_expected_currency) !~ '^[A-Z]{3}$'
    or p_environment not in ('test_mode', 'live_mode')
  then
    raise exception 'invalid checkout contract' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.danotch_user_profiles where id = p_user_id
  ) then
    raise exception 'checkout profile not found' using errcode = '23503';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    p_user_id::text || ':' || p_product_id || ':' || p_environment,
    0
  ));

  update public.danotch_checkout_records
  set status = 'expired'
  where user_id = p_user_id
    and product_id = p_product_id
    and environment = p_environment
    and status in ('pending', 'active')
    and expires_at <= now();

  select * into checkout
  from public.danotch_checkout_records
  where user_id = p_user_id
    and product_id = p_product_id
    and environment = p_environment
    and status in ('pending', 'active')
    and expires_at > now()
  order by created_at desc
  limit 1
  for update;

  if found then
    if checkout.expected_amount <> p_expected_amount
      or checkout.expected_currency <> upper(p_expected_currency)
      or checkout.expected_quantity <> p_expected_quantity
    then
      raise exception 'active checkout contract differs from configured contract'
        using errcode = '22023';
    end if;
  else
    insert into public.danotch_checkout_records(
      user_id, product_id, expected_amount, expected_currency,
      expected_quantity, environment, status, idempotency_key
    ) values (
      p_user_id, p_product_id, p_expected_amount, upper(p_expected_currency),
      p_expected_quantity, p_environment, 'pending',
      'checkout:' || gen_random_uuid()::text
    )
    returning * into checkout;
  end if;

  return jsonb_build_object(
    'id', checkout.id,
    'idempotency_key', checkout.idempotency_key,
    'dodo_session_id', checkout.dodo_session_id,
    'checkout_url', checkout.checkout_url,
    'expires_at', checkout.expires_at
  );
end
$$;

create or replace function public.danotch_attach_checkout_session(
  p_checkout_record_id uuid,
  p_idempotency_key text,
  p_dodo_session_id text,
  p_checkout_url text
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  checkout public.danotch_checkout_records;
begin
  if p_dodo_session_id = '' or p_checkout_url = '' then
    return false;
  end if;

  select * into checkout
  from public.danotch_checkout_records
  where id = p_checkout_record_id
  for update;

  if not found
    or checkout.idempotency_key <> p_idempotency_key
    or checkout.status not in ('pending', 'active')
    or checkout.expires_at <= now()
    or (
      checkout.dodo_session_id is not null
      and checkout.dodo_session_id <> p_dodo_session_id
    )
    or (
      checkout.checkout_url is not null
      and checkout.checkout_url <> p_checkout_url
    )
  then
    return false;
  end if;

  update public.danotch_checkout_records
  set dodo_session_id = p_dodo_session_id,
      checkout_url = p_checkout_url,
      status = 'active',
      attached_at = coalesce(attached_at, now())
  where id = p_checkout_record_id;
  return true;
exception
  when unique_violation then
    return false;
end
$$;

drop function public.danotch_record_payment(
  text, text, text, text, text, integer, text, text
);

create function public.danotch_record_payment(
  p_delivery_id text,
  p_payment_id text,
  p_claimed_user_id text,
  p_customer_id text,
  p_event_type text,
  p_amount integer,
  p_currency text,
  p_product_id text,
  p_quantity integer,
  p_checkout_record_id uuid,
  p_dodo_session_id text,
  p_environment text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid;
  checkout public.danotch_checkout_records;
  event_id uuid := gen_random_uuid();
begin
  insert into public.danotch_payment_events(
    id, delivery_id, payment_id, provider_event_id, claimed_user_id,
    event_type, amount, currency, product_id, checkout_record_id, outcome
  ) values (
    event_id, p_delivery_id, p_payment_id, p_payment_id, p_claimed_user_id,
    p_event_type, p_amount, upper(p_currency), p_product_id,
    null, 'processing'
  )
  on conflict do nothing;

  if not found then
    return 'duplicate';
  end if;

  begin
    v_profile_id := p_claimed_user_id::uuid;
  exception when invalid_text_representation then
    v_profile_id := null;
  end;

  if v_profile_id is null or not exists (
    select 1 from public.danotch_user_profiles where id = v_profile_id
  ) then
    update public.danotch_payment_events
    set outcome = 'unknown_profile', error = 'claimed profile does not exist'
    where id = event_id;
    return 'unknown_profile';
  end if;

  select * into checkout
  from public.danotch_checkout_records
  where id = p_checkout_record_id
    and user_id = v_profile_id
    and dodo_session_id = p_dodo_session_id
    and product_id = p_product_id
    and expected_amount = p_amount
    and expected_currency = upper(p_currency)
    and expected_quantity = p_quantity
    and environment = p_environment
    and status = 'active'
    and expires_at > now()
  for update;

  if not found then
    update public.danotch_payment_events
    set outcome = 'rejected', error = 'exact attached checkout record did not match'
    where id = event_id;
    return 'rejected';
  end if;

  update public.danotch_checkout_records
  set status = 'consumed', consumed_at = now()
  where id = checkout.id;

  update public.danotch_user_profiles
  set billing_status = 'paid',
      plan = 'paid',
      lifetime_purchased_at = coalesce(lifetime_purchased_at, now()),
      lifetime_revoked_at = null,
      lifetime_revocation_reason = null,
      dodo_customer_id = p_customer_id,
      dodo_payment_id = p_payment_id
  where id = v_profile_id;

  update public.danotch_payment_events
  set profile_id = v_profile_id,
      outcome = 'granted',
      checkout_record_id = checkout.id
  where id = event_id;
  return 'granted';
end
$$;

create function public.danotch_record_payment_reversal(
  p_delivery_id text,
  p_event_type text,
  p_provider_event_id text,
  p_payment_id text,
  p_amount integer,
  p_currency text,
  p_is_full_refund boolean,
  p_reason text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  original public.danotch_payment_events;
  event_id uuid := gen_random_uuid();
  should_revoke boolean := false;
begin
  insert into public.danotch_payment_events(
    id, delivery_id, payment_id, provider_event_id, claimed_user_id,
    event_type, amount, currency, product_id, outcome
  ) values (
    event_id, p_delivery_id, p_payment_id, p_provider_event_id, null,
    p_event_type, p_amount, upper(p_currency), null, 'processing'
  )
  on conflict do nothing;

  if not found then
    return 'duplicate';
  end if;

  select * into original
  from public.danotch_payment_events
  where payment_id = p_payment_id
    and event_type = 'payment.succeeded'
    and outcome = 'granted'
  order by created_at
  limit 1;

  if not found then
    -- Delivery order is not guaranteed. Roll the event claim back and ask the
    -- provider to retry rather than acknowledging a reversal before its payment.
    raise exception 'granted payment not found for reversal'
      using errcode = '40001';
  end if;

  should_revoke := case
    when p_event_type = 'refund.succeeded' then
      p_is_full_refund
      and (
        p_amount is null
        or (
          p_amount = original.amount
          and upper(p_currency) = original.currency
        )
      )
    when p_event_type in ('dispute.accepted', 'dispute.lost') then true
    else false
  end;

  if not should_revoke then
    update public.danotch_payment_events
    set profile_id = original.profile_id,
        checkout_record_id = original.checkout_record_id,
        product_id = original.product_id,
        outcome = 'ignored',
        error = 'reversal policy did not require revocation'
    where id = event_id;
    return 'ignored';
  end if;

  update public.danotch_user_profiles
  set billing_status = 'revoked',
      plan = 'free',
      lifetime_revoked_at = now(),
      lifetime_revocation_reason = p_event_type || coalesce(': ' || nullif(p_reason, ''), '')
  where id = original.profile_id
    and dodo_payment_id = p_payment_id;

  if not found then
    update public.danotch_payment_events
    set profile_id = original.profile_id,
        checkout_record_id = original.checkout_record_id,
        product_id = original.product_id,
        outcome = 'ignored',
        error = 'payment no longer backs current entitlement'
    where id = event_id;
    return 'ignored';
  end if;

  update public.danotch_payment_events
  set profile_id = original.profile_id,
      claimed_user_id = original.claimed_user_id,
      checkout_record_id = original.checkout_record_id,
      product_id = original.product_id,
      outcome = 'revoked'
  where id = event_id;
  return 'revoked';
end
$$;

revoke all on function public.danotch_reserve_checkout(
  uuid, text, integer, text, integer, text
) from public;
revoke all on function public.danotch_attach_checkout_session(
  uuid, text, text, text
) from public;
revoke all on function public.danotch_record_payment(
  text, text, text, text, text, integer, text, text, integer, uuid, text, text
) from public;
revoke all on function public.danotch_record_payment_reversal(
  text, text, text, text, integer, text, boolean, text
) from public;

grant execute on function public.danotch_reserve_checkout(
  uuid, text, integer, text, integer, text
) to danotch_webhook;
grant execute on function public.danotch_attach_checkout_session(
  uuid, text, text, text
) to danotch_webhook;
grant execute on function public.danotch_record_payment(
  text, text, text, text, text, integer, text, text, integer, uuid, text, text
) to danotch_webhook;
grant execute on function public.danotch_record_payment_reversal(
  text, text, text, text, integer, text, boolean, text
) to danotch_webhook;
