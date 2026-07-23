-- GENERATED FILE. Run `npm run db:snapshot` after changing ordered migrations.
-- Ordered migrations are authoritative; this self-contained snapshot is derived from them.
-- BEGIN 000_base_schema.sql
-- Authoritative application bootstrap. Supabase projects already provide
-- auth.users; the compatibility table only makes clean PostgreSQL CI databases
-- capable of exercising the same foreign keys.
create extension if not exists pgcrypto;
create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key
);

create table if not exists public.danotch_user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null default '',
  avatar_url text,
  plan text not null default 'free',
  created_at timestamptz not null default now()
);

create table if not exists public.danotch_connected_apps (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  app_type text not null,
  active boolean not null default false,
  composio_conn_id text,
  connected_at timestamptz,
  disconnected_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, app_type)
);

create table if not exists public.danotch_provider_configs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null,
  api_key_encrypted text not null,
  model_id text not null,
  is_active boolean not null default false,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, provider)
);

create table if not exists public.danotch_threads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id)
);

create table if not exists public.danotch_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null,
  content text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint danotch_messages_owned_thread_fk
    foreign key (thread_id, user_id)
    references public.danotch_threads(id, user_id)
    on delete cascade
);

create table if not exists public.danotch_scheduled_tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  prompt text not null,
  task_type text not null default 'scheduled',
  cron text,
  interval_ms bigint,
  target_app text,
  notify_user boolean not null default false,
  enabled boolean not null default true,
  next_run_at timestamptz,
  last_run_at timestamptz,
  run_count integer not null default 0,
  last_result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.danotch_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source text not null,
  source_id uuid,
  title text not null,
  body text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

-- Bring the historical hand-created schema up to the bootstrap contract before
-- later migrations run. These statements are intentionally additive.
alter table public.danotch_user_profiles
  add column if not exists avatar_url text,
  add column if not exists plan text not null default 'free';
alter table public.danotch_scheduled_tasks
  add column if not exists updated_at timestamptz not null default now();
create unique index if not exists danotch_threads_id_user_uidx
  on public.danotch_threads(id, user_id);
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.danotch_messages'::regclass
      and conname = 'danotch_messages_owned_thread_fk'
  ) then
    alter table public.danotch_messages
      add constraint danotch_messages_owned_thread_fk
      foreign key (thread_id, user_id)
      references public.danotch_threads(id, user_id)
      on delete cascade;
  end if;
end
$$;

create index if not exists idx_danotch_connected_apps_user
  on public.danotch_connected_apps(user_id);
create index if not exists idx_danotch_provider_configs_user
  on public.danotch_provider_configs(user_id);
create index if not exists idx_danotch_threads_user
  on public.danotch_threads(user_id);
create index if not exists idx_danotch_messages_thread
  on public.danotch_messages(thread_id);
create index if not exists idx_danotch_messages_user
  on public.danotch_messages(user_id);
create index if not exists idx_danotch_scheduled_tasks_user
  on public.danotch_scheduled_tasks(user_id);
create index if not exists idx_danotch_scheduled_tasks_next_run
  on public.danotch_scheduled_tasks(enabled, next_run_at);
create index if not exists idx_danotch_notifications_user
  on public.danotch_notifications(user_id, created_at desc);
create index if not exists idx_danotch_notifications_unread
  on public.danotch_notifications(user_id, read) where read = false;
-- END 000_base_schema.sql
-- BEGIN 001_billing_entitlements.sql
-- Billing/trial entitlement fields for Perch.
-- Run this once in the Supabase SQL editor for the active project.

alter table public.danotch_user_profiles
  add column if not exists trial_started_at timestamptz,
  add column if not exists trial_ends_at timestamptz,
  add column if not exists lifetime_purchased_at timestamptz,
  add column if not exists billing_status text not null default 'trialing',
  add column if not exists dodo_customer_id text,
  add column if not exists dodo_payment_id text;

update public.danotch_user_profiles
set
  trial_started_at = coalesce(trial_started_at, now()),
  trial_ends_at = coalesce(trial_ends_at, now() + interval '14 days'),
  billing_status = case
    when lifetime_purchased_at is not null then 'paid'
    when coalesce(trial_ends_at, now() + interval '14 days') > now() then 'trialing'
    else 'expired'
  end;

alter table public.danotch_user_profiles
  alter column trial_started_at set default now(),
  alter column trial_ends_at set default (now() + interval '14 days');

create index if not exists danotch_user_profiles_billing_status_idx
  on public.danotch_user_profiles (billing_status);
-- END 001_billing_entitlements.sql
-- BEGIN 002_payment_checkout_and_events.sql
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
-- END 002_payment_checkout_and_events.sql
-- BEGIN 003_connection_requests.sql
-- Durable OAuth connection requests and attempts.
--
-- Connection requests were previously in-memory promises discarded on socket
-- loss. This table lets the app rehydrate a pending request after a restart and
-- resolve it exactly once. connection_attempts binds a specific OAuth attempt to
-- a user+app so the status sync can only activate an account that resulted from
-- that user's own attempt.

create table if not exists public.danotch_connection_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.danotch_user_profiles (id) on delete cascade,
  session_id text,
  app_type text not null,
  display_name text not null,
  reason text,
  status text not null default 'pending', -- pending | approved | denied | expired
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '2 minutes'),
  resolved_at timestamptz
);

create index if not exists danotch_connection_requests_user_idx
  on public.danotch_connection_requests (user_id, status);

create table if not exists public.danotch_connection_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.danotch_user_profiles (id) on delete cascade,
  app_type text not null,
  toolkit_slug text not null,
  state_nonce text not null unique,
  composio_account_id text,
  status text not null default 'pending', -- pending | active | expired | failed
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  activated_at timestamptz
);

create index if not exists danotch_connection_attempts_user_idx
  on public.danotch_connection_attempts (user_id, app_type, status);

-- Atomically move a durable request to a terminal state exactly once.
create or replace function public.danotch_resolve_connection_request(
  p_request_id uuid,
  p_user_id uuid,
  p_status text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated int;
begin
  update public.danotch_connection_requests
  set status = p_status, resolved_at = now()
  where id = p_request_id
    and user_id = p_user_id
    and status = 'pending';
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    return 'noop';
  end if;
  return 'resolved';
end;
$$;

revoke all on function public.danotch_resolve_connection_request(uuid, uuid, text) from public;
-- END 003_connection_requests.sql
-- BEGIN 004_pending_actions.sql
-- Durable pending draft actions.
--
-- Draft "approve/reject" was a decorative UI with no backend contract. This
-- table stores an immutable canonical payload for an allowlisted external
-- action, owned by a user, that executes exactly once on approval. Sensitive
-- content is stored so the user can review it, and must be redacted from logs
-- and non-owner responses at the application layer.

create table if not exists public.danotch_pending_actions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.danotch_user_profiles (id) on delete cascade,
  session_id text,
  action_type text not null,          -- allowlisted composio tool name
  summary text not null,              -- human-readable, non-sensitive
  payload jsonb not null,             -- immutable canonical tool input
  status text not null default 'pending', -- pending | executing | completed | rejected | expired | failed
  idempotency_key text not null,      -- stable key = action id, passed downstream where supported
  result text,
  error text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '1 hour'),
  decided_at timestamptz,
  executed_at timestamptz
);

create index if not exists danotch_pending_actions_user_idx
  on public.danotch_pending_actions (user_id, status);

-- Atomically claim a pending action for execution (pending -> executing) so a
-- duplicate approval cannot start a second execution.
create or replace function public.danotch_claim_pending_action(
  p_action_id uuid,
  p_user_id uuid
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated int;
begin
  update public.danotch_pending_actions
  set status = 'executing', decided_at = now()
  where id = p_action_id
    and user_id = p_user_id
    and status = 'pending'
    and expires_at > now();
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    return 'noop';
  end if;
  return 'claimed';
end;
$$;

revoke all on function public.danotch_claim_pending_action(uuid, uuid) from public;
-- END 004_pending_actions.sql
-- BEGIN 005_rls_and_constraints.sql
-- Tenant boundary and operation-role classification.
--
-- User-readable/user-writable:
--   profiles (read; name/avatar write), provider configs (metadata read; config
--   write), threads/messages (legacy owner CRUD), scheduled task definition
--   fields (owner CRUD), notifications (read/read-state/delete).
-- User-readable/server-authoritative:
--   connected app state, connection requests, pending actions.
-- Server-authoritative:
--   billing/trial/payment fields, checkout/payment ledgers, OAuth attempt state,
--   schedule execution fields, notification creation, action/connection state.

do $$
declare
  role_name text;
begin
  foreach role_name in array array[
    'anon', 'authenticated', 'service_role',
    'danotch_bootstrap', 'danotch_webhook', 'danotch_scheduler',
    'danotch_fencing', 'danotch_reconciler', 'danotch_provider'
  ]
  loop
    if not exists (select 1 from pg_roles where rolname = role_name) then
      execute format('create role %I nologin', role_name);
    end if;
  end loop;
end
$$;

alter role danotch_bootstrap bypassrls;
alter role danotch_webhook bypassrls;
alter role danotch_scheduler bypassrls;
alter role danotch_fencing bypassrls;
alter role danotch_reconciler bypassrls;
alter role danotch_provider bypassrls;

do $$
declare
  role_name text;
begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    foreach role_name in array array[
      'danotch_bootstrap', 'danotch_webhook', 'danotch_scheduler',
      'danotch_fencing', 'danotch_reconciler', 'danotch_provider'
    ]
    loop
      execute format('grant %I to authenticator', role_name);
    end loop;
  end if;
end
$$;

-- Plain PostgreSQL integration tests do not have Supabase's auth.uid().
do $outer$
begin
  if to_regprocedure('auth.uid()') is null then
    execute $fn$
      create function auth.uid() returns uuid
      language sql stable
      set search_path = ''
      as 'select nullif(current_setting(''request.jwt.claim.sub'', true), '''')::uuid'
    $fn$;
  end if;
end
$outer$;

alter table public.danotch_user_profiles
  add constraint danotch_user_profiles_billing_status_check
    check (billing_status in ('trialing', 'paid', 'expired')),
  add constraint danotch_user_profiles_plan_check
    check (plan in ('free', 'paid'));
alter table public.danotch_connected_apps
  add constraint danotch_connected_apps_type_check
    check (app_type in ('gmail', 'googlecalendar', 'googledocs', 'github'));
alter table public.danotch_provider_configs
  add constraint danotch_provider_configs_provider_check
    check (provider in ('anthropic', 'openai', 'openrouter'));
alter table public.danotch_messages
  add constraint danotch_messages_role_check
    check (role in ('user', 'assistant', 'tool', 'connection_request'));
alter table public.danotch_scheduled_tasks
  add constraint danotch_scheduled_tasks_type_check
    check (task_type in ('scheduled', 'poll')),
  add constraint danotch_scheduled_tasks_run_count_check
    check (run_count >= 0),
  add constraint danotch_scheduled_tasks_schedule_check
    check (
      (task_type = 'scheduled' and cron is not null and interval_ms is null)
      or
      (task_type = 'poll' and interval_ms >= 60000 and cron is null)
    );
alter table public.danotch_checkout_records
  add constraint danotch_checkout_records_status_check
    check (status in ('pending', 'consumed', 'expired')),
  add constraint danotch_checkout_records_amount_check
    check (expected_amount >= 0 and expected_quantity > 0);
alter table public.danotch_payment_events
  add constraint danotch_payment_events_outcome_check
    check (outcome in ('granted', 'duplicate', 'unknown_profile', 'rejected'));
alter table public.danotch_connection_requests
  add constraint danotch_connection_requests_status_check
    check (status in ('pending', 'approved', 'denied', 'expired'));
alter table public.danotch_connection_attempts
  add constraint danotch_connection_attempts_status_check
    check (status in ('pending', 'active', 'expired', 'failed'));
alter table public.danotch_pending_actions
  add constraint danotch_pending_actions_status_check
    check (status in ('pending', 'executing', 'completed', 'rejected', 'expired', 'failed'));

create unique index if not exists danotch_provider_configs_one_active_idx
  on public.danotch_provider_configs(user_id) where is_active;
create index if not exists danotch_payment_events_claimed_user_idx
  on public.danotch_payment_events(claimed_user_id);

-- Every owner predicate has a supporting index, including tables introduced by
-- delta migrations.
create index if not exists danotch_checkout_records_owner_idx
  on public.danotch_checkout_records(user_id);
create index if not exists danotch_payment_events_owner_idx
  on public.danotch_payment_events(profile_id);
create index if not exists danotch_connection_requests_owner_idx
  on public.danotch_connection_requests(user_id);
create index if not exists danotch_connection_attempts_owner_idx
  on public.danotch_connection_attempts(user_id);
create index if not exists danotch_pending_actions_owner_idx
  on public.danotch_pending_actions(user_id);

create or replace function public.danotch_reject_owner_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (to_jsonb(old) ->> tg_argv[0]) is distinct from (to_jsonb(new) ->> tg_argv[0]) then
    raise exception 'immutable owner column %', tg_argv[0] using errcode = '42501';
  end if;
  return new;
end
$$;

do $$
declare
  item record;
begin
  for item in
    select * from (values
      ('danotch_user_profiles', 'id'),
      ('danotch_connected_apps', 'user_id'),
      ('danotch_provider_configs', 'user_id'),
      ('danotch_threads', 'user_id'),
      ('danotch_messages', 'user_id'),
      ('danotch_scheduled_tasks', 'user_id'),
      ('danotch_notifications', 'user_id'),
      ('danotch_checkout_records', 'user_id'),
      ('danotch_connection_requests', 'user_id'),
      ('danotch_connection_attempts', 'user_id'),
      ('danotch_pending_actions', 'user_id')
    ) as owners(table_name, column_name)
  loop
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.danotch_reject_owner_change(%L)',
      item.table_name || '_immutable_owner', item.table_name, item.column_name
    );
  end loop;
end
$$;

-- RLS is authoritative even for table owners used by local integration tests.
alter table public.danotch_user_profiles enable row level security;
alter table public.danotch_user_profiles force row level security;
alter table public.danotch_connected_apps enable row level security;
alter table public.danotch_connected_apps force row level security;
alter table public.danotch_provider_configs enable row level security;
alter table public.danotch_provider_configs force row level security;
alter table public.danotch_threads enable row level security;
alter table public.danotch_threads force row level security;
alter table public.danotch_messages enable row level security;
alter table public.danotch_messages force row level security;
alter table public.danotch_scheduled_tasks enable row level security;
alter table public.danotch_scheduled_tasks force row level security;
alter table public.danotch_notifications enable row level security;
alter table public.danotch_notifications force row level security;
alter table public.danotch_checkout_records enable row level security;
alter table public.danotch_checkout_records force row level security;
alter table public.danotch_payment_events enable row level security;
alter table public.danotch_payment_events force row level security;
alter table public.danotch_connection_requests enable row level security;
alter table public.danotch_connection_requests force row level security;
alter table public.danotch_connection_attempts enable row level security;
alter table public.danotch_connection_attempts force row level security;
alter table public.danotch_pending_actions enable row level security;
alter table public.danotch_pending_actions force row level security;

create policy profiles_owner_select on public.danotch_user_profiles
  for select to authenticated using (id = auth.uid());
create policy profiles_owner_update on public.danotch_user_profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy connected_apps_owner_select on public.danotch_connected_apps
  for select to authenticated using (user_id = auth.uid());

create policy provider_configs_owner_select on public.danotch_provider_configs
  for select to authenticated using (user_id = auth.uid());
create policy provider_configs_owner_insert on public.danotch_provider_configs
  for insert to authenticated with check (user_id = auth.uid());
create policy provider_configs_owner_update on public.danotch_provider_configs
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy provider_configs_owner_delete on public.danotch_provider_configs
  for delete to authenticated using (user_id = auth.uid());

create policy threads_owner_select on public.danotch_threads
  for select to authenticated using (user_id = auth.uid());
create policy threads_owner_insert on public.danotch_threads
  for insert to authenticated with check (user_id = auth.uid());
create policy threads_owner_update on public.danotch_threads
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy threads_owner_delete on public.danotch_threads
  for delete to authenticated using (user_id = auth.uid());

create policy messages_owner_select on public.danotch_messages
  for select to authenticated using (user_id = auth.uid());
create policy messages_owner_insert on public.danotch_messages
  for insert to authenticated with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.danotch_threads t
      where t.id = thread_id and t.user_id = auth.uid()
    )
  );
create policy messages_owner_update on public.danotch_messages
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy messages_owner_delete on public.danotch_messages
  for delete to authenticated using (user_id = auth.uid());

create policy scheduled_tasks_owner_select on public.danotch_scheduled_tasks
  for select to authenticated using (user_id = auth.uid());
create policy scheduled_tasks_owner_insert on public.danotch_scheduled_tasks
  for insert to authenticated with check (user_id = auth.uid());
create policy scheduled_tasks_owner_update on public.danotch_scheduled_tasks
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy scheduled_tasks_owner_delete on public.danotch_scheduled_tasks
  for delete to authenticated using (user_id = auth.uid());

create policy notifications_owner_select on public.danotch_notifications
  for select to authenticated using (user_id = auth.uid());
create policy notifications_owner_update on public.danotch_notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notifications_owner_delete on public.danotch_notifications
  for delete to authenticated using (user_id = auth.uid());

create policy checkout_records_owner_select on public.danotch_checkout_records
  for select to authenticated using (user_id = auth.uid());
create policy connection_requests_owner_select on public.danotch_connection_requests
  for select to authenticated using (user_id = auth.uid());
create policy pending_actions_owner_select on public.danotch_pending_actions
  for select to authenticated using (user_id = auth.uid());

revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
grant usage on schema public to authenticated;
grant usage on schema public to danotch_bootstrap, danotch_webhook,
  danotch_scheduler, danotch_fencing, danotch_reconciler, danotch_provider;

grant select (id, email, full_name, avatar_url, plan, created_at,
  trial_started_at, trial_ends_at, lifetime_purchased_at, billing_status)
  on public.danotch_user_profiles to authenticated;
grant update (full_name, avatar_url) on public.danotch_user_profiles to authenticated;

grant select (id, user_id, app_type, active, connected_at, disconnected_at, created_at)
  on public.danotch_connected_apps to authenticated;

grant select (id, user_id, provider, model_id, is_active, verified_at, created_at, updated_at)
  on public.danotch_provider_configs to authenticated;
grant insert (user_id, provider, api_key_encrypted, model_id, is_active, updated_at)
  on public.danotch_provider_configs to authenticated;
grant update (provider, api_key_encrypted, model_id, is_active, updated_at)
  on public.danotch_provider_configs to authenticated;
grant delete on public.danotch_provider_configs to authenticated;

grant select, delete on public.danotch_threads to authenticated;
grant insert (id, user_id, title) on public.danotch_threads to authenticated;
grant update (title, updated_at) on public.danotch_threads to authenticated;
grant select, delete on public.danotch_messages to authenticated;
grant insert (thread_id, user_id, role, content, metadata) on public.danotch_messages to authenticated;
grant update (content, metadata) on public.danotch_messages to authenticated;

grant select, delete on public.danotch_scheduled_tasks to authenticated;
grant insert (user_id, name, prompt, task_type, cron, interval_ms, target_app, notify_user, enabled)
  on public.danotch_scheduled_tasks to authenticated;
grant update (name, prompt, cron, interval_ms, target_app, notify_user, enabled, updated_at)
  on public.danotch_scheduled_tasks to authenticated;

grant select, delete on public.danotch_notifications to authenticated;
grant update (read) on public.danotch_notifications to authenticated;
grant select on public.danotch_checkout_records to authenticated;
grant select on public.danotch_connection_requests to authenticated;
grant select on public.danotch_pending_actions to authenticated;

-- Operation-specific roles. Public request code receives none of these clients.
grant select, insert, update on public.danotch_user_profiles to danotch_bootstrap;
grant select, insert, update on public.danotch_connected_apps to danotch_bootstrap;
grant select, insert, update on public.danotch_checkout_records to danotch_webhook;
grant select, insert on public.danotch_payment_events to danotch_webhook;
grant select, update on public.danotch_user_profiles to danotch_webhook;
grant select, insert, update on public.danotch_scheduled_tasks to danotch_scheduler;
grant select, insert on public.danotch_notifications to danotch_scheduler;
grant select on public.danotch_provider_configs to danotch_scheduler;
grant select on public.danotch_user_profiles to danotch_scheduler;
grant select, insert, update on public.danotch_connection_requests to danotch_fencing;
grant select, insert, update on public.danotch_connection_attempts to danotch_reconciler;
grant select, insert, update on public.danotch_connected_apps to danotch_reconciler;
grant select, insert, update on public.danotch_pending_actions to danotch_reconciler;
grant select on public.danotch_provider_configs to danotch_reconciler;
grant select on public.danotch_provider_configs to danotch_provider;
grant update (verified_at) on public.danotch_provider_configs to danotch_provider;

revoke all on function public.danotch_reject_owner_change() from public;
grant execute on function public.danotch_record_payment(text, text, text, text, text, integer, text, text)
  to danotch_webhook;
grant execute on function public.danotch_resolve_connection_request(uuid, uuid, text)
  to danotch_fencing;
grant execute on function public.danotch_claim_pending_action(uuid, uuid)
  to danotch_reconciler;
-- END 005_rls_and_constraints.sql
-- BEGIN 006_devices_runs_events.sql
-- Durable owner/device run protocol. Ordinary authenticated callers may read
-- their rows but cannot create protocol facts or mutate server-authoritative
-- state. All writes pass through operation-scoped reducers below.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'danotch_runner') then
    create role danotch_runner nologin;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    grant danotch_runner to authenticator;
  end if;
end;
$$;
alter role danotch_runner bypassrls;
grant usage on schema public to danotch_runner;

create table public.danotch_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  public_key text not null,
  status text not null default 'active'
    check (status in ('active', 'revoked')),
  current_fence bigint not null default 0 check (current_fence >= 0),
  next_event_sequence bigint not null default 1 check (next_event_sequence >= 1),
  enrolled_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (id, user_id)
);

create table public.danotch_runs (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid,
  protocol_version integer not null default 1 check (protocol_version = 1),
  idempotency_key text not null,
  state text not null default 'queued' check (state in (
    'queued', 'provider_streaming', 'checkpointed', 'waiting_for_device',
    'cancellation_requested', 'completed', 'failed', 'failed_recoverable',
    'cancelled', 'expired'
  )),
  revision bigint not null default 0 check (revision >= 0),
  input jsonb not null,
  checkpoint jsonb,
  terminal_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  terminal_at timestamptz,
  unique (id, user_id),
  unique (user_id, idempotency_key),
  constraint danotch_runs_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);

create table public.danotch_run_events (
  id uuid primary key,
  run_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid,
  run_sequence bigint not null check (run_sequence >= 1),
  device_sequence bigint,
  protocol_version integer not null default 1 check (protocol_version = 1),
  event_type text not null check (event_type in (
    'run_created', 'provider_stream_started', 'provider_checkpointed',
    'local_action_offered', 'cancellation_requested', 'run_completed',
    'run_failed', 'provider_stream_interrupted', 'run_cancelled', 'run_expired'
  )),
  from_state text,
  to_state text not null,
  payload jsonb not null default '{}'::jsonb,
  checkpoint jsonb,
  created_at timestamptz not null default now(),
  unique (run_id, run_sequence),
  unique (device_id, device_sequence),
  constraint danotch_run_events_owned_run_fk
    foreign key (run_id, user_id)
    references public.danotch_runs(id, user_id)
    on delete cascade,
  constraint danotch_run_events_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);

create table public.danotch_event_acknowledgements (
  id uuid primary key,
  event_id uuid not null references public.danotch_run_events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  device_sequence bigint not null,
  fence bigint not null check (fence >= 0),
  acknowledged_at timestamptz not null default now(),
  unique (event_id, device_id),
  unique (device_id, device_sequence),
  constraint danotch_event_acks_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);

create table public.danotch_local_action_requests (
  id uuid primary key,
  run_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  protocol_version integer not null default 1 check (protocol_version = 1),
  registry_version text not null,
  action_type text not null,
  normalized_parameters jsonb not null,
  parameters_hash text not null check (parameters_hash ~ '^[0-9a-f]{64}$'),
  capabilities jsonb not null,
  image_digest text not null,
  state text not null default 'offered' check (state in (
    'offered', 'approved', 'rejected', 'granted', 'executing',
    'completed', 'failed', 'cancelled', 'expired'
  )),
  offered_at timestamptz not null default now(),
  expires_at timestamptz not null,
  terminal_at timestamptz,
  unique (id, user_id),
  constraint danotch_local_actions_owned_run_fk
    foreign key (run_id, user_id)
    references public.danotch_runs(id, user_id)
    on delete cascade,
  constraint danotch_local_actions_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);

create table public.danotch_action_decisions (
  id uuid primary key,
  action_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  decision text not null check (decision in ('approved', 'rejected')),
  parameters_hash text not null check (parameters_hash ~ '^[0-9a-f]{64}$'),
  fence bigint not null check (fence >= 0),
  decided_at timestamptz not null default now(),
  unique (action_id),
  constraint danotch_action_decisions_owned_action_fk
    foreign key (action_id, user_id)
    references public.danotch_local_action_requests(id, user_id),
  constraint danotch_action_decisions_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);

create table public.danotch_execution_grants (
  id uuid primary key,
  action_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  grant_hash text not null unique check (grant_hash ~ '^[0-9a-f]{64}$'),
  parameters_hash text not null check (parameters_hash ~ '^[0-9a-f]{64}$'),
  capabilities jsonb not null,
  image_digest text not null,
  fence bigint not null check (fence >= 0),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (action_id),
  constraint danotch_execution_grants_owned_action_fk
    foreign key (action_id, user_id)
    references public.danotch_local_action_requests(id, user_id),
  constraint danotch_execution_grants_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);

create table public.danotch_run_cancellations (
  id uuid primary key,
  run_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid,
  reason text,
  requested_at timestamptz not null default now(),
  unique (run_id),
  constraint danotch_run_cancellations_owned_run_fk
    foreign key (run_id, user_id)
    references public.danotch_runs(id, user_id),
  constraint danotch_run_cancellations_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);

create table public.danotch_terminal_results (
  id uuid primary key,
  run_id uuid not null,
  action_id uuid,
  grant_id uuid,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid,
  status text not null check (status in (
    'completed', 'failed', 'failed_recoverable', 'cancelled', 'expired'
  )),
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (run_id),
  unique (action_id),
  constraint danotch_terminal_results_owned_run_fk
    foreign key (run_id, user_id)
    references public.danotch_runs(id, user_id),
  constraint danotch_terminal_results_owned_action_fk
    foreign key (action_id, user_id)
    references public.danotch_local_action_requests(id, user_id),
  foreign key (grant_id) references public.danotch_execution_grants(id),
  constraint danotch_terminal_results_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);

create index danotch_devices_owner_idx on public.danotch_devices(user_id);
create index danotch_runs_owner_idx on public.danotch_runs(user_id);
create index danotch_runs_owner_device_idx on public.danotch_runs(user_id, device_id);
create index danotch_runs_state_idx on public.danotch_runs(state);
create index danotch_run_events_owner_idx on public.danotch_run_events(user_id);
create index danotch_run_events_device_replay_idx
  on public.danotch_run_events(device_id, device_sequence);
create index danotch_event_acks_owner_idx on public.danotch_event_acknowledgements(user_id);
create index danotch_local_actions_owner_idx on public.danotch_local_action_requests(user_id);
create index danotch_local_actions_device_idx
  on public.danotch_local_action_requests(device_id, state);
create index danotch_action_decisions_owner_idx on public.danotch_action_decisions(user_id);
create index danotch_execution_grants_owner_idx on public.danotch_execution_grants(user_id);
create index danotch_run_cancellations_owner_idx on public.danotch_run_cancellations(user_id);
create index danotch_terminal_results_owner_idx on public.danotch_terminal_results(user_id);

do $$
declare
  item record;
begin
  for item in
    select * from (values
      ('danotch_devices', 'user_id'),
      ('danotch_runs', 'user_id'),
      ('danotch_run_events', 'user_id'),
      ('danotch_event_acknowledgements', 'user_id'),
      ('danotch_local_action_requests', 'user_id'),
      ('danotch_action_decisions', 'user_id'),
      ('danotch_execution_grants', 'user_id'),
      ('danotch_run_cancellations', 'user_id'),
      ('danotch_terminal_results', 'user_id')
    ) as owners(table_name, column_name)
  loop
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.danotch_reject_owner_change(%L)',
      item.table_name || '_immutable_owner', item.table_name, item.column_name
    );
  end loop;
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'danotch_devices', 'danotch_runs', 'danotch_run_events',
    'danotch_event_acknowledgements', 'danotch_local_action_requests',
    'danotch_action_decisions', 'danotch_execution_grants',
    'danotch_run_cancellations', 'danotch_terminal_results'
  ]
  loop
    execute format('alter table public.%I enable row level security', table_name);
    execute format('alter table public.%I force row level security', table_name);
    execute format(
      'create policy %I on public.%I for select to authenticated using (user_id = auth.uid())',
      table_name || '_owner_select', table_name
    );
  end loop;
end;
$$;

revoke all on public.danotch_devices, public.danotch_runs,
  public.danotch_run_events, public.danotch_event_acknowledgements,
  public.danotch_local_action_requests, public.danotch_action_decisions,
  public.danotch_execution_grants, public.danotch_run_cancellations,
  public.danotch_terminal_results
  from public, anon, authenticated;

grant select on public.danotch_devices, public.danotch_runs,
  public.danotch_run_events, public.danotch_event_acknowledgements,
  public.danotch_local_action_requests, public.danotch_action_decisions,
  public.danotch_execution_grants, public.danotch_run_cancellations,
  public.danotch_terminal_results
  to authenticated;

grant select, insert, update on public.danotch_devices to danotch_fencing;
grant select on public.danotch_devices to danotch_runner;
grant update (next_event_sequence) on public.danotch_devices to danotch_runner;
grant select, insert, update on public.danotch_runs to danotch_runner;
grant select, insert on public.danotch_run_events to danotch_runner;
grant select, insert on public.danotch_terminal_results to danotch_runner;
grant select, insert, update on public.danotch_local_action_requests to danotch_runner;
grant select, insert, update on public.danotch_execution_grants to danotch_runner;
grant select, insert on public.danotch_run_cancellations to danotch_runner;
grant select, insert on public.danotch_event_acknowledgements to danotch_fencing;
grant select, insert on public.danotch_run_events to danotch_fencing;
grant select, update on public.danotch_runs to danotch_fencing;
grant select, insert on public.danotch_action_decisions to danotch_fencing;
grant select, update on public.danotch_local_action_requests to danotch_fencing;
grant select, update on public.danotch_execution_grants to danotch_fencing;
grant select, insert on public.danotch_run_cancellations to danotch_fencing;
grant select, insert, update on public.danotch_terminal_results to danotch_fencing;
grant select on public.danotch_runs, public.danotch_run_events,
  public.danotch_local_action_requests, public.danotch_execution_grants
  to danotch_reconciler;

create function public.danotch_create_run(
  p_run_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_idempotency_key text,
  p_input jsonb,
  p_protocol_version integer default 1
) returns public.danotch_runs
language plpgsql
security invoker
set search_path = ''
as $$
declare
  created public.danotch_runs;
  next_device_sequence bigint;
begin
  if p_protocol_version <> 1 then
    raise exception 'unsupported protocol version' using errcode = '22023';
  end if;
  if p_device_id is not null and not exists (
    select 1 from public.danotch_devices
    where id = p_device_id and user_id = p_user_id and status = 'active'
  ) then
    raise exception 'device is not active for owner' using errcode = '42501';
  end if;

  insert into public.danotch_runs(
    id, user_id, device_id, protocol_version, idempotency_key, input
  ) values (
    p_run_id, p_user_id, p_device_id, p_protocol_version, p_idempotency_key, p_input
  )
  on conflict (user_id, idempotency_key) do nothing;

  select * into created from public.danotch_runs
  where user_id = p_user_id and idempotency_key = p_idempotency_key;
  if created.device_id is distinct from p_device_id
    or created.input is distinct from p_input
    or created.protocol_version <> p_protocol_version then
    raise exception 'idempotency key reused with different run content'
      using errcode = '23505';
  end if;
  if created.id is distinct from p_run_id then
    return created;
  end if;

  if not exists (select 1 from public.danotch_run_events where id = p_run_id) then
    if p_device_id is not null then
      update public.danotch_devices
      set next_event_sequence = next_event_sequence + 1
      where id = p_device_id and user_id = p_user_id
      returning next_event_sequence - 1 into next_device_sequence;
    end if;
    insert into public.danotch_run_events(
      id, run_id, user_id, device_id, run_sequence, device_sequence,
      event_type, to_state, payload
    ) values (
      p_run_id, p_run_id, p_user_id, p_device_id, 1, next_device_sequence,
      'run_created', 'queued', jsonb_build_object('protocolVersion', p_protocol_version)
    );
  end if;
  return created;
end;
$$;

create function public.danotch_transition_run(
  p_run_id uuid,
  p_user_id uuid,
  p_transition_id uuid,
  p_expected_revision bigint,
  p_target_state text,
  p_event_type text,
  p_payload jsonb default '{}'::jsonb,
  p_checkpoint jsonb default null
) returns public.danotch_runs
language plpgsql
security invoker
set search_path = ''
as $$
declare
  current_run public.danotch_runs;
  next_device_sequence bigint;
  allowed boolean := false;
begin
  select * into current_run from public.danotch_runs
  where id = p_run_id and user_id = p_user_id for update;
  if not found then
    raise exception 'run not found for owner' using errcode = '42501';
  end if;

  if exists (select 1 from public.danotch_run_events where id = p_transition_id) then
    if not exists (
      select 1 from public.danotch_run_events
      where id = p_transition_id and run_id = p_run_id and user_id = p_user_id
        and to_state = p_target_state and event_type = p_event_type
        and payload = coalesce(p_payload, '{}'::jsonb)
        and checkpoint is not distinct from p_checkpoint
    ) then
      raise exception 'transition id reused with different content' using errcode = '23505';
    end if;
    return current_run;
  end if;
  if current_run.revision <> p_expected_revision then
    raise exception 'out-of-order transition: expected %, actual %',
      p_expected_revision, current_run.revision using errcode = '40001';
  end if;
  if current_run.state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired') then
    raise exception 'late transition for terminal run' using errcode = '55000';
  end if;
  if p_target_state is distinct from (case p_event_type
    when 'provider_stream_started' then 'provider_streaming'
    when 'provider_checkpointed' then 'checkpointed'
    when 'local_action_offered' then 'waiting_for_device'
    when 'cancellation_requested' then 'cancellation_requested'
    when 'run_completed' then 'completed'
    when 'run_failed' then 'failed'
    when 'provider_stream_interrupted' then 'failed_recoverable'
    when 'run_cancelled' then 'cancelled'
    when 'run_expired' then 'expired'
    else null
  end) then
    raise exception 'event type does not authorize target state' using errcode = '22023';
  end if;

  allowed := case current_run.state
    when 'queued' then p_target_state in (
      'provider_streaming', 'waiting_for_device', 'cancellation_requested', 'failed'
    )
    when 'provider_streaming' then p_target_state in (
      'checkpointed', 'completed', 'failed', 'failed_recoverable', 'cancellation_requested'
    )
    when 'checkpointed' then p_target_state in (
      'provider_streaming', 'waiting_for_device', 'completed', 'failed', 'cancellation_requested'
    )
    when 'waiting_for_device' then p_target_state in (
      'checkpointed', 'cancellation_requested', 'cancelled', 'expired', 'failed'
    )
    when 'cancellation_requested' then p_target_state in ('cancelled', 'failed')
    else false
  end;
  if not allowed then
    raise exception 'invalid run transition: % -> %', current_run.state, p_target_state
      using errcode = '22023';
  end if;

  if current_run.device_id is not null then
    update public.danotch_devices
    set next_event_sequence = next_event_sequence + 1
    where id = current_run.device_id and user_id = p_user_id
    returning next_event_sequence - 1 into next_device_sequence;
  end if;

  insert into public.danotch_run_events(
    id, run_id, user_id, device_id, run_sequence, device_sequence,
    event_type, from_state, to_state, payload, checkpoint
  ) values (
    p_transition_id, p_run_id, p_user_id, current_run.device_id,
    current_run.revision + 2, next_device_sequence, p_event_type,
    current_run.state, p_target_state, coalesce(p_payload, '{}'::jsonb), p_checkpoint
  );

  update public.danotch_runs set
    state = p_target_state,
    revision = revision + 1,
    checkpoint = case when p_checkpoint is null then checkpoint else p_checkpoint end,
    terminal_code = case
      when p_target_state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired')
        then coalesce(p_payload ->> 'code', p_target_state)
      else terminal_code
    end,
    terminal_at = case
      when p_target_state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired')
        then now()
      else terminal_at
    end,
    updated_at = now()
  where id = p_run_id and user_id = p_user_id
  returning * into current_run;

  if p_target_state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired') then
    insert into public.danotch_terminal_results(
      id, run_id, user_id, device_id, status, result
    ) values (
      p_transition_id, p_run_id, p_user_id, current_run.device_id,
      p_target_state, coalesce(p_payload, '{}'::jsonb)
    )
    on conflict (run_id) do nothing;
  end if;
  return current_run;
end;
$$;

create function public.danotch_recover_interrupted_streams()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  candidate record;
  recovered integer := 0;
begin
  for candidate in
    select id, user_id, revision from public.danotch_runs
    where state = 'provider_streaming'
    for update skip locked
  loop
    perform public.danotch_transition_run(
      candidate.id, candidate.user_id, gen_random_uuid(), candidate.revision,
      'failed_recoverable', 'provider_stream_interrupted',
      jsonb_build_object(
        'code', 'provider_stream_interrupted',
        'retryCreatesNewRun', true
      ), null
    );
    recovered := recovered + 1;
  end loop;
  return recovered;
end;
$$;

create function public.danotch_acknowledge_event(
  p_ack_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_event_id uuid,
  p_device_sequence bigint,
  p_fence bigint
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.danotch_run_events event
    join public.danotch_devices device
      on device.id = event.device_id and device.user_id = event.user_id
    where event.id = p_event_id and event.user_id = p_user_id
      and event.device_id = p_device_id
      and event.device_sequence = p_device_sequence
      and device.status = 'active' and device.current_fence = p_fence
  ) then
    raise exception 'acknowledgement scope, sequence, or fence mismatch'
      using errcode = '42501';
  end if;
  insert into public.danotch_event_acknowledgements(
    id, event_id, user_id, device_id, device_sequence, fence
  ) values (
    p_ack_id, p_event_id, p_user_id, p_device_id, p_device_sequence, p_fence
  )
  on conflict (event_id, device_id) do nothing;
  return 'acknowledged';
end;
$$;

create function public.danotch_decide_local_action(
  p_decision_id uuid,
  p_action_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_decision text,
  p_parameters_hash text,
  p_fence bigint
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  action public.danotch_local_action_requests;
begin
  select * into action from public.danotch_local_action_requests
  where id = p_action_id and user_id = p_user_id and device_id = p_device_id
  for update;
  if not found then
    raise exception 'action not found for owner/device' using errcode = '42501';
  end if;
  if action.parameters_hash <> p_parameters_hash then
    raise exception 'action parameters changed' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.danotch_devices
    where id = p_device_id and user_id = p_user_id
      and status = 'active' and current_fence = p_fence
  ) then
    raise exception 'stale device fence' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'invalid decision' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.danotch_action_decisions where id = p_decision_id
      and action_id = p_action_id and user_id = p_user_id
      and device_id = p_device_id and decision = p_decision
      and parameters_hash = p_parameters_hash and fence = p_fence
  ) then
    return p_decision;
  end if;
  if action.state <> 'offered' or action.expires_at <= now() then
    raise exception 'late action decision' using errcode = '55000';
  end if;

  insert into public.danotch_action_decisions(
    id, action_id, user_id, device_id, decision, parameters_hash, fence
  ) values (
    p_decision_id, p_action_id, p_user_id, p_device_id,
    p_decision, p_parameters_hash, p_fence
  );
  update public.danotch_local_action_requests set
    state = case when p_decision = 'approved' then 'approved' else 'rejected' end,
    terminal_at = case when p_decision = 'rejected' then now() else null end
  where id = p_action_id and user_id = p_user_id;
  return p_decision;
end;
$$;

create function public.danotch_mint_execution_grant(
  p_grant_id uuid,
  p_action_id uuid,
  p_user_id uuid,
  p_grant_hash text,
  p_expires_at timestamptz
) returns public.danotch_execution_grants
language plpgsql
security invoker
set search_path = ''
as $$
declare
  action public.danotch_local_action_requests;
  grant_row public.danotch_execution_grants;
  device_fence bigint;
begin
  select * into action from public.danotch_local_action_requests
  where id = p_action_id and user_id = p_user_id for update;
  if not found or action.state <> 'approved' or action.expires_at <= now() then
    raise exception 'action is not grantable' using errcode = '55000';
  end if;
  select current_fence into device_fence from public.danotch_devices
  where id = action.device_id and user_id = p_user_id and status = 'active';
  if not found then
    raise exception 'device is not active' using errcode = '42501';
  end if;
  if p_expires_at <= now() or p_expires_at > action.expires_at then
    raise exception 'grant expiry exceeds action expiry' using errcode = '22023';
  end if;

  insert into public.danotch_execution_grants(
    id, action_id, user_id, device_id, grant_hash, parameters_hash,
    capabilities, image_digest, fence, expires_at
  ) values (
    p_grant_id, p_action_id, p_user_id, action.device_id, p_grant_hash,
    action.parameters_hash, action.capabilities, action.image_digest,
    device_fence, p_expires_at
  )
  on conflict (action_id) do nothing;
  select * into grant_row from public.danotch_execution_grants
  where action_id = p_action_id and user_id = p_user_id;
  if grant_row.id <> p_grant_id
    or grant_row.grant_hash <> p_grant_hash
    or grant_row.expires_at <> p_expires_at then
    raise exception 'action grant already minted with different content'
      using errcode = '23505';
  end if;
  update public.danotch_local_action_requests set state = 'granted'
  where id = p_action_id and user_id = p_user_id and state = 'approved';
  return grant_row;
end;
$$;

create function public.danotch_consume_execution_grant(
  p_grant_id uuid,
  p_action_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_grant_hash text,
  p_parameters_hash text,
  p_fence bigint
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  consumed timestamptz;
begin
  update public.danotch_execution_grants grant_row set consumed_at = now()
  where grant_row.id = p_grant_id and grant_row.action_id = p_action_id
    and grant_row.user_id = p_user_id and grant_row.device_id = p_device_id
    and grant_row.grant_hash = p_grant_hash
    and grant_row.parameters_hash = p_parameters_hash
    and grant_row.fence = p_fence and grant_row.expires_at > now()
    and grant_row.consumed_at is null
    and exists (
      select 1 from public.danotch_devices device
      where device.id = p_device_id and device.user_id = p_user_id
        and device.status = 'active' and device.current_fence = p_fence
    )
    and exists (
      select 1 from public.danotch_local_action_requests action
      where action.id = p_action_id and action.user_id = p_user_id
        and action.device_id = p_device_id and action.state = 'granted'
        and action.parameters_hash = p_parameters_hash and action.expires_at > now()
    )
  returning consumed_at into consumed;
  if consumed is null then
    raise exception 'grant is invalid, expired, stale, or already consumed'
      using errcode = '55000';
  end if;
  update public.danotch_local_action_requests set state = 'executing'
  where id = p_action_id and user_id = p_user_id and state = 'granted';
  return 'consumed';
end;
$$;

create function public.danotch_cancel_run(
  p_cancellation_id uuid,
  p_run_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_reason text
) returns public.danotch_runs
language plpgsql
security invoker
set search_path = ''
as $$
declare
  current_run public.danotch_runs;
begin
  select * into current_run from public.danotch_runs
  where id = p_run_id and user_id = p_user_id for update;
  if not found or current_run.device_id is distinct from p_device_id then
    raise exception 'run not found for owner/device' using errcode = '42501';
  end if;
  if current_run.state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired') then
    raise exception 'late cancellation for terminal run' using errcode = '55000';
  end if;
  insert into public.danotch_run_cancellations(id, run_id, user_id, device_id, reason)
  values (p_cancellation_id, p_run_id, p_user_id, p_device_id, left(p_reason, 500))
  on conflict (run_id) do nothing;
  return public.danotch_transition_run(
    p_run_id, p_user_id, p_cancellation_id, current_run.revision,
    'cancellation_requested', 'cancellation_requested',
    jsonb_build_object('reason', left(p_reason, 500)), null
  );
end;
$$;

create function public.danotch_record_action_result(
  p_result_id uuid,
  p_action_id uuid,
  p_grant_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_status text,
  p_result jsonb,
  p_fence bigint
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  action public.danotch_local_action_requests;
  run_row public.danotch_runs;
  target_state text;
  event_type text;
begin
  select * into action from public.danotch_local_action_requests
  where id = p_action_id and user_id = p_user_id and device_id = p_device_id
  for update;
  if not found then
    raise exception 'action not found for owner/device' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.danotch_terminal_results
    where id = p_result_id and action_id = p_action_id and grant_id = p_grant_id
      and user_id = p_user_id and device_id = p_device_id and status = p_status
      and result = coalesce(p_result, '{}'::jsonb)
  ) then
    return p_status;
  end if;
  if action.state <> 'executing' then
    raise exception 'late or duplicate action result' using errcode = '55000';
  end if;
  if not exists (
    select 1 from public.danotch_execution_grants grant_row
    join public.danotch_devices device
      on device.id = grant_row.device_id and device.user_id = grant_row.user_id
    where grant_row.id = p_grant_id and grant_row.action_id = p_action_id
      and grant_row.user_id = p_user_id and grant_row.device_id = p_device_id
      and grant_row.consumed_at is not null and grant_row.fence = p_fence
      and device.status = 'active' and device.current_fence = p_fence
  ) then
    raise exception 'result grant or fence mismatch' using errcode = '42501';
  end if;
  if p_status not in ('completed', 'failed', 'cancelled') then
    raise exception 'invalid action result status' using errcode = '22023';
  end if;

  select * into run_row from public.danotch_runs
  where id = action.run_id and user_id = p_user_id for update;
  target_state := p_status;
  event_type := case p_status
    when 'completed' then 'run_completed'
    when 'cancelled' then 'run_cancelled'
    else 'run_failed'
  end;
  perform public.danotch_transition_run(
    run_row.id, p_user_id, p_result_id, run_row.revision,
    target_state, event_type,
    jsonb_build_object('actionId', p_action_id, 'result', coalesce(p_result, '{}'::jsonb)),
    null
  );
  update public.danotch_terminal_results set
    action_id = p_action_id,
    grant_id = p_grant_id,
    result = coalesce(p_result, '{}'::jsonb)
  where id = p_result_id and run_id = run_row.id and user_id = p_user_id;
  update public.danotch_local_action_requests set
    state = p_status,
    terminal_at = now()
  where id = p_action_id and user_id = p_user_id;
  return p_status;
end;
$$;

revoke all on function public.danotch_create_run(uuid, uuid, uuid, text, jsonb, integer) from public;
revoke all on function public.danotch_transition_run(uuid, uuid, uuid, bigint, text, text, jsonb, jsonb) from public;
revoke all on function public.danotch_recover_interrupted_streams() from public;
revoke all on function public.danotch_acknowledge_event(uuid, uuid, uuid, uuid, bigint, bigint) from public;
revoke all on function public.danotch_decide_local_action(uuid, uuid, uuid, uuid, text, text, bigint) from public;
revoke all on function public.danotch_mint_execution_grant(uuid, uuid, uuid, text, timestamptz) from public;
revoke all on function public.danotch_consume_execution_grant(uuid, uuid, uuid, uuid, text, text, bigint) from public;
revoke all on function public.danotch_cancel_run(uuid, uuid, uuid, uuid, text) from public;
revoke all on function public.danotch_record_action_result(uuid, uuid, uuid, uuid, uuid, text, jsonb, bigint) from public;
grant execute on function public.danotch_create_run(uuid, uuid, uuid, text, jsonb, integer)
  to danotch_runner;
grant execute on function public.danotch_transition_run(uuid, uuid, uuid, bigint, text, text, jsonb, jsonb)
  to danotch_runner;
grant execute on function public.danotch_recover_interrupted_streams()
  to danotch_runner;
grant execute on function public.danotch_acknowledge_event(uuid, uuid, uuid, uuid, bigint, bigint)
  to danotch_fencing;
grant execute on function public.danotch_decide_local_action(uuid, uuid, uuid, uuid, text, text, bigint)
  to danotch_fencing;
grant execute on function public.danotch_mint_execution_grant(uuid, uuid, uuid, text, timestamptz)
  to danotch_runner;
grant execute on function public.danotch_consume_execution_grant(uuid, uuid, uuid, uuid, text, text, bigint)
  to danotch_fencing;
grant execute on function public.danotch_cancel_run(uuid, uuid, uuid, uuid, text)
  to danotch_runner, danotch_fencing;
grant execute on function public.danotch_record_action_result(uuid, uuid, uuid, uuid, uuid, text, jsonb, bigint)
  to danotch_fencing;
-- END 006_devices_runs_events.sql
-- BEGIN 007_device_gateway.sql
-- Authenticated device enrollment and one-use fenced WSS upgrade state.
-- Only the danotch_fencing operation role can create or consume these facts.

alter table public.danotch_devices
  add column key_algorithm text not null default 'Ed25519'
    check (key_algorithm = 'Ed25519'),
  add column key_format text not null default 'spki-pem'
    check (key_format = 'spki-pem'),
  add column key_fingerprint text
    check (key_fingerprint is null or key_fingerprint ~ '^[0-9a-f]{64}$'),
  add column replaced_by_device_id uuid references public.danotch_devices(id);

-- No pre-U9 device was authenticated by proof-of-possession. Preserve its
-- audit row but make it unusable rather than silently trusting legacy state.
update public.danotch_devices
set status = 'revoked',
    revoked_at = coalesce(revoked_at, now()),
    current_fence = current_fence + 1
where key_fingerprint is null;

alter table public.danotch_devices
  add constraint danotch_active_device_has_validated_key
  check (status = 'revoked' or key_fingerprint is not null);

create unique index danotch_devices_key_fingerprint_unique
  on public.danotch_devices(key_fingerprint)
  where key_fingerprint is not null;

create table public.danotch_device_challenges (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  purpose text not null check (purpose in ('enrollment', 'ticket')),
  device_id uuid,
  nonce text not null check (nonce ~ '^[A-Za-z0-9_-]{43}$'),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint danotch_device_challenge_scope check (
    (purpose = 'enrollment' and device_id is null)
    or (purpose = 'ticket' and device_id is not null)
  ),
  constraint danotch_device_challenge_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);

create table public.danotch_gateway_tickets (
  ticket_hash text primary key check (ticket_hash ~ '^[0-9a-f]{64}$'),
  ticket_id uuid not null unique,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  protocol_version integer not null check (protocol_version = 1),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint danotch_gateway_ticket_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);

create index danotch_device_challenges_expiry_idx
  on public.danotch_device_challenges(expires_at);
create index danotch_gateway_tickets_device_expiry_idx
  on public.danotch_gateway_tickets(user_id, device_id, expires_at);

alter table public.danotch_device_challenges enable row level security;
alter table public.danotch_device_challenges force row level security;
alter table public.danotch_gateway_tickets enable row level security;
alter table public.danotch_gateway_tickets force row level security;

revoke all on public.danotch_device_challenges, public.danotch_gateway_tickets
  from public, anon, authenticated;
grant select, insert, update, delete
  on public.danotch_device_challenges, public.danotch_gateway_tickets
  to danotch_fencing;
grant update (status, revoked_at, current_fence, replaced_by_device_id)
  on public.danotch_devices to danotch_fencing;

create function public.danotch_create_device_challenge(
  p_id uuid,
  p_user_id uuid,
  p_purpose text,
  p_device_id uuid,
  p_nonce text,
  p_expires_at timestamptz
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_purpose not in ('enrollment', 'ticket')
    or (p_purpose = 'enrollment' and p_device_id is not null)
    or (p_purpose = 'ticket' and p_device_id is null)
    or p_expires_at <= now()
    or p_expires_at > now() + interval '10 minutes' then
    raise exception 'invalid device challenge' using errcode = '22023';
  end if;
  if p_purpose = 'ticket' and not exists (
    select 1 from public.danotch_devices
    where id = p_device_id and user_id = p_user_id and status = 'active'
  ) then
    raise exception 'active device not found for challenge' using errcode = '42501';
  end if;
  insert into public.danotch_device_challenges(
    id, user_id, purpose, device_id, nonce, expires_at
  ) values (
    p_id, p_user_id, p_purpose, p_device_id, p_nonce, p_expires_at
  );
end
$$;

create function public.danotch_get_device_challenge(
  p_id uuid,
  p_user_id uuid
) returns public.danotch_device_challenges
language sql
stable
security invoker
set search_path = ''
as $$
  select challenge
  from public.danotch_device_challenges challenge
  where challenge.id = p_id and challenge.user_id = p_user_id
$$;

create function public.danotch_get_active_device(
  p_user_id uuid,
  p_device_id uuid
) returns public.danotch_devices
language sql
stable
security invoker
set search_path = ''
as $$
  select device
  from public.danotch_devices device
  where device.id = p_device_id and device.user_id = p_user_id
    and device.status = 'active'
$$;

create function public.danotch_enroll_device(
  p_challenge_id uuid,
  p_device_id uuid,
  p_user_id uuid,
  p_display_name text,
  p_public_key text,
  p_key_fingerprint text,
  p_replacement_device_id uuid,
  p_max_devices integer,
  p_now timestamptz
) returns public.danotch_devices
language plpgsql
security invoker
set search_path = ''
as $$
declare
  challenge public.danotch_device_challenges;
  enrolled public.danotch_devices;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));
  select * into challenge from public.danotch_device_challenges
  where id = p_challenge_id and user_id = p_user_id for update;
  if not found or challenge.purpose <> 'enrollment'
    or challenge.device_id is not null or challenge.consumed_at is not null
    or challenge.expires_at <= p_now then
    raise exception 'invalid or consumed enrollment challenge' using errcode = '42501';
  end if;
  if p_max_devices < 1 or p_max_devices > 20
    or length(p_display_name) not between 1 and 80
    or p_key_fingerprint !~ '^[0-9a-f]{64}$'
    or length(p_public_key) > 1000 then
    raise exception 'invalid enrollment parameters' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.danotch_devices
    where key_fingerprint = p_key_fingerprint
  ) then
    raise exception 'device key is already enrolled' using errcode = '23505';
  end if;
  if p_replacement_device_id is null then
    if (
      select count(*) from public.danotch_devices
      where user_id = p_user_id and status = 'active'
    ) >= p_max_devices then
      raise exception 'active device limit reached' using errcode = '54000';
    end if;
  elsif not exists (
    select 1 from public.danotch_devices
    where id = p_replacement_device_id and user_id = p_user_id
      and status = 'active' for update
  ) then
    raise exception 'replacement device is not active for owner' using errcode = '42501';
  end if;

  update public.danotch_device_challenges
  set consumed_at = p_now where id = p_challenge_id;
  insert into public.danotch_devices(
    id, user_id, display_name, public_key, key_algorithm, key_format,
    key_fingerprint, status, current_fence, enrolled_at
  ) values (
    p_device_id, p_user_id, p_display_name, p_public_key, 'Ed25519',
    'spki-pem', p_key_fingerprint, 'active', 0, p_now
  ) returning * into enrolled;

  if p_replacement_device_id is not null then
    update public.danotch_devices set
      status = 'revoked',
      revoked_at = p_now,
      current_fence = current_fence + 1,
      replaced_by_device_id = p_device_id
    where id = p_replacement_device_id and user_id = p_user_id;
    update public.danotch_gateway_tickets set consumed_at = p_now
    where user_id = p_user_id and device_id = p_replacement_device_id
      and consumed_at is null;
  end if;
  return enrolled;
end
$$;

create function public.danotch_create_gateway_ticket(
  p_challenge_id uuid,
  p_ticket_hash text,
  p_ticket_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_protocol_version integer,
  p_expires_at timestamptz,
  p_now timestamptz
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  challenge public.danotch_device_challenges;
begin
  select * into challenge from public.danotch_device_challenges
  where id = p_challenge_id and user_id = p_user_id for update;
  if not found or challenge.purpose <> 'ticket'
    or challenge.device_id <> p_device_id or challenge.consumed_at is not null
    or challenge.expires_at <= p_now then
    raise exception 'invalid or consumed ticket challenge' using errcode = '42501';
  end if;
  if p_protocol_version <> 1 or p_expires_at <= p_now
    or p_expires_at > p_now + interval '2 minutes'
    or not exists (
      select 1 from public.danotch_devices
      where id = p_device_id and user_id = p_user_id and status = 'active'
      for update
    ) then
    raise exception 'invalid ticket scope or expiry' using errcode = '42501';
  end if;
  update public.danotch_device_challenges
  set consumed_at = p_now where id = p_challenge_id;
  insert into public.danotch_gateway_tickets(
    ticket_hash, ticket_id, user_id, device_id, protocol_version, expires_at
  ) values (
    p_ticket_hash, p_ticket_id, p_user_id, p_device_id,
    p_protocol_version, p_expires_at
  );
end
$$;

create function public.danotch_consume_gateway_ticket(
  p_ticket_hash text,
  p_ticket_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_protocol_version integer,
  p_now timestamptz
) returns table(
  user_id uuid,
  device_id uuid,
  protocol_version integer,
  fence bigint,
  ticket_id uuid
)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  claimed public.danotch_gateway_tickets;
  next_fence bigint;
begin
  select * into claimed from public.danotch_gateway_tickets ticket
  where ticket.ticket_hash = p_ticket_hash for update;
  if not found or claimed.ticket_id <> p_ticket_id
    or claimed.user_id <> p_user_id or claimed.device_id <> p_device_id
    or claimed.protocol_version <> p_protocol_version
    or claimed.consumed_at is not null or claimed.expires_at <= p_now then
    raise exception 'ticket is invalid, expired, or consumed' using errcode = '42501';
  end if;
  update public.danotch_devices set current_fence = current_fence + 1
  where id = p_device_id and public.danotch_devices.user_id = p_user_id
    and status = 'active'
  returning current_fence into next_fence;
  if next_fence is null then
    raise exception 'device is revoked or not owned' using errcode = '42501';
  end if;
  update public.danotch_gateway_tickets set consumed_at = p_now
  where ticket_hash = p_ticket_hash;
  return query select p_user_id, p_device_id, p_protocol_version, next_fence, p_ticket_id;
end
$$;

create function public.danotch_revoke_device(
  p_user_id uuid,
  p_device_id uuid,
  p_now timestamptz
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  changed integer;
begin
  update public.danotch_devices set
    status = 'revoked',
    revoked_at = p_now,
    current_fence = current_fence + 1
  where id = p_device_id and user_id = p_user_id and status = 'active';
  get diagnostics changed = row_count;
  update public.danotch_gateway_tickets set consumed_at = p_now
  where user_id = p_user_id and device_id = p_device_id and consumed_at is null;
  return changed = 1;
end
$$;

create function public.danotch_fence_user_devices(
  p_user_id uuid,
  p_now timestamptz
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.danotch_devices
  set current_fence = current_fence + 1
  where user_id = p_user_id;
  update public.danotch_gateway_tickets set consumed_at = p_now
  where user_id = p_user_id and consumed_at is null;
end
$$;

create function public.danotch_assert_device_fence(
  p_user_id uuid,
  p_device_id uuid,
  p_fence bigint
) returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1 from public.danotch_devices
    where id = p_device_id and user_id = p_user_id
      and status = 'active' and current_fence = p_fence
  )
$$;

create function public.danotch_fenced_acknowledge_event(
  p_ack_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_event_id uuid,
  p_device_sequence bigint,
  p_fence bigint
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform 1 from public.danotch_devices
  where id = p_device_id and user_id = p_user_id
    and status = 'active' and current_fence = p_fence
  for update;
  if not found then
    raise exception 'stale device fence' using errcode = '42501';
  end if;
  return public.danotch_acknowledge_event(
    p_ack_id, p_user_id, p_device_id, p_event_id, p_device_sequence, p_fence
  );
end
$$;

create function public.danotch_fenced_decide_local_action(
  p_decision_id uuid,
  p_action_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_decision text,
  p_parameters_hash text,
  p_fence bigint
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform 1 from public.danotch_devices
  where id = p_device_id and user_id = p_user_id
    and status = 'active' and current_fence = p_fence
  for update;
  if not found then
    raise exception 'stale device fence' using errcode = '42501';
  end if;
  return public.danotch_decide_local_action(
    p_decision_id, p_action_id, p_user_id, p_device_id,
    p_decision, p_parameters_hash, p_fence
  );
end
$$;

create function public.danotch_fenced_record_action_result(
  p_result_id uuid,
  p_action_id uuid,
  p_grant_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_status text,
  p_result jsonb,
  p_fence bigint
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform 1 from public.danotch_devices
  where id = p_device_id and user_id = p_user_id
    and status = 'active' and current_fence = p_fence
  for update;
  if not found then
    raise exception 'stale device fence' using errcode = '42501';
  end if;
  return public.danotch_record_action_result(
    p_result_id, p_action_id, p_grant_id, p_user_id, p_device_id,
    p_status, p_result, p_fence
  );
end
$$;

create function public.danotch_fenced_cancel_run(
  p_cancellation_id uuid,
  p_run_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_reason text,
  p_fence bigint
) returns public.danotch_runs
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform 1 from public.danotch_devices
  where id = p_device_id and user_id = p_user_id
    and status = 'active' and current_fence = p_fence
  for update;
  if not found then
    raise exception 'stale device fence' using errcode = '42501';
  end if;
  return public.danotch_cancel_run(
    p_cancellation_id, p_run_id, p_user_id, p_device_id, p_reason
  );
end
$$;

create function public.danotch_fence_connection_logout(
  p_user_id uuid,
  p_device_id uuid,
  p_fence bigint,
  p_now timestamptz
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform 1 from public.danotch_devices
  where id = p_device_id and user_id = p_user_id
    and status = 'active' and current_fence = p_fence
  for update;
  if not found then return false; end if;
  perform public.danotch_fence_user_devices(p_user_id, p_now);
  return true;
end
$$;

revoke all on function public.danotch_create_device_challenge(uuid, uuid, text, uuid, text, timestamptz) from public;
revoke all on function public.danotch_get_device_challenge(uuid, uuid) from public;
revoke all on function public.danotch_get_active_device(uuid, uuid) from public;
revoke all on function public.danotch_enroll_device(uuid, uuid, uuid, text, text, text, uuid, integer, timestamptz) from public;
revoke all on function public.danotch_create_gateway_ticket(uuid, text, uuid, uuid, uuid, integer, timestamptz, timestamptz) from public;
revoke all on function public.danotch_consume_gateway_ticket(text, uuid, uuid, uuid, integer, timestamptz) from public;
revoke all on function public.danotch_revoke_device(uuid, uuid, timestamptz) from public;
revoke all on function public.danotch_fence_user_devices(uuid, timestamptz) from public;
revoke all on function public.danotch_assert_device_fence(uuid, uuid, bigint) from public;
revoke all on function public.danotch_fenced_acknowledge_event(uuid, uuid, uuid, uuid, bigint, bigint) from public;
revoke all on function public.danotch_fenced_decide_local_action(uuid, uuid, uuid, uuid, text, text, bigint) from public;
revoke all on function public.danotch_fenced_record_action_result(uuid, uuid, uuid, uuid, uuid, text, jsonb, bigint) from public;
revoke all on function public.danotch_fenced_cancel_run(uuid, uuid, uuid, uuid, text, bigint) from public;
revoke all on function public.danotch_fence_connection_logout(uuid, uuid, bigint, timestamptz) from public;

grant execute on function public.danotch_create_device_challenge(uuid, uuid, text, uuid, text, timestamptz) to danotch_fencing;
grant execute on function public.danotch_get_device_challenge(uuid, uuid) to danotch_fencing;
grant execute on function public.danotch_get_active_device(uuid, uuid) to danotch_fencing;
grant execute on function public.danotch_enroll_device(uuid, uuid, uuid, text, text, text, uuid, integer, timestamptz) to danotch_fencing;
grant execute on function public.danotch_create_gateway_ticket(uuid, text, uuid, uuid, uuid, integer, timestamptz, timestamptz) to danotch_fencing;
grant execute on function public.danotch_consume_gateway_ticket(text, uuid, uuid, uuid, integer, timestamptz) to danotch_fencing;
grant execute on function public.danotch_revoke_device(uuid, uuid, timestamptz) to danotch_fencing;
grant execute on function public.danotch_fence_user_devices(uuid, timestamptz) to danotch_fencing;
grant execute on function public.danotch_assert_device_fence(uuid, uuid, bigint) to danotch_fencing;
grant execute on function public.danotch_fenced_acknowledge_event(uuid, uuid, uuid, uuid, bigint, bigint) to danotch_fencing;
grant execute on function public.danotch_fenced_decide_local_action(uuid, uuid, uuid, uuid, text, text, bigint) to danotch_fencing;
grant execute on function public.danotch_fenced_record_action_result(uuid, uuid, uuid, uuid, uuid, text, jsonb, bigint) to danotch_fencing;
grant execute on function public.danotch_fenced_cancel_run(uuid, uuid, uuid, uuid, text, bigint) to danotch_fencing;
grant execute on function public.danotch_fence_connection_logout(uuid, uuid, bigint, timestamptz) to danotch_fencing;
-- END 007_device_gateway.sql
-- BEGIN 008_replay_recovery.sql
-- Durable at-least-once device delivery, bounded replay, snapshot recovery,
-- expiring device affinity, and atomic parameter-bound execution grants.

alter table public.danotch_devices
  add column replay_cursor bigint not null default 0 check (replay_cursor >= 0),
  add column replay_cursor_event_id uuid,
  add column replay_updated_at timestamptz;

alter table public.danotch_runs
  add column waiting_expires_at timestamptz;

alter table public.danotch_run_events
  add column transition_id uuid,
  add column retained_until timestamptz not null default (now() + interval '7 days');
update public.danotch_run_events set transition_id = id where transition_id is null;
alter table public.danotch_run_events alter column transition_id set not null;
alter table public.danotch_run_events
  drop constraint danotch_run_events_event_type_check;
alter table public.danotch_run_events
  add constraint danotch_run_events_event_type_check check (event_type in (
    'run_created', 'provider_stream_started', 'provider_checkpointed',
    'local_action_offered', 'execution_grant_issued', 'grant_consumed',
    'cancellation_requested', 'run_completed', 'run_failed',
    'provider_stream_interrupted', 'run_cancelled', 'run_expired'
  ));
create index danotch_run_events_retention_idx
  on public.danotch_run_events(device_id, retained_until);
create unique index danotch_run_events_transition_idx
  on public.danotch_run_events(user_id, transition_id);

create function public.danotch_fill_protocol_event_fields()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.transition_id is null then new.transition_id := new.id; end if;
  if new.retained_until is null then new.retained_until := now() + interval '7 days'; end if;
  return new;
end
$$;
create trigger danotch_run_events_fill_protocol_fields
before insert on public.danotch_run_events
for each row execute function public.danotch_fill_protocol_event_fields();

create function public.danotch_set_waiting_device_expiry()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.state = 'waiting_for_device' and old.state <> 'waiting_for_device'
    and new.waiting_expires_at is null then
    new.waiting_expires_at := now() + interval '15 minutes';
  end if;
  return new;
end
$$;
create trigger danotch_runs_waiting_device_expiry
before update on public.danotch_runs
for each row execute function public.danotch_set_waiting_device_expiry();

create function public.danotch_reject_run_device_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.device_id is distinct from old.device_id then
    raise exception 'initiating device affinity is immutable'
      using errcode = '42501';
  end if;
  return new;
end
$$;
create trigger danotch_runs_immutable_device_affinity
before update on public.danotch_runs
for each row execute function public.danotch_reject_run_device_change();

alter table public.danotch_local_action_requests
  add column action_hash text;
update public.danotch_local_action_requests
set action_hash = encode(digest(
  registry_version || E'\n' || action_type || E'\n' || normalized_parameters::text,
  'sha256'
), 'hex');
alter table public.danotch_local_action_requests
  alter column action_hash set not null,
  add constraint danotch_local_action_action_hash_check
    check (action_hash ~ '^[0-9a-f]{64}$'),
  add constraint danotch_local_action_image_digest_check
    check (image_digest ~ '^sha256:[0-9a-f]{64}$');

create function public.danotch_bind_local_action_hash()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  expected text;
begin
  expected := encode(public.digest(
    new.registry_version || E'\n' || new.action_type || E'\n'
      || new.normalized_parameters::text,
    'sha256'
  ), 'hex');
  if new.action_hash is not null and new.action_hash <> expected then
    raise exception 'local action hash does not match normalized action'
      using errcode = '22023';
  end if;
  new.action_hash := expected;
  return new;
end
$$;
create trigger danotch_local_action_bind_hash
before insert or update of registry_version, action_type, normalized_parameters, action_hash
on public.danotch_local_action_requests
for each row execute function public.danotch_bind_local_action_hash();

alter table public.danotch_execution_grants
  add column action_hash text,
  add column normalized_parameters jsonb,
  add column consumed_transition_id uuid unique,
  add column revoked_at timestamptz;
update public.danotch_execution_grants grant_row set
  action_hash = action.action_hash,
  normalized_parameters = action.normalized_parameters
from public.danotch_local_action_requests action
where action.id = grant_row.action_id;
alter table public.danotch_execution_grants
  alter column action_hash set not null,
  alter column normalized_parameters set not null,
  add constraint danotch_execution_grant_action_hash_check
    check (action_hash ~ '^[0-9a-f]{64}$');

create table public.danotch_protocol_quota_config (
  singleton boolean primary key default true check (singleton),
  max_reconnects_per_minute integer not null check (max_reconnects_per_minute > 0),
  max_reconnects_per_day integer not null check (max_reconnects_per_day > 0),
  max_retained_events_per_device integer not null check (max_retained_events_per_device > 0),
  max_retained_bytes_per_device bigint not null check (max_retained_bytes_per_device > 0),
  reconnect_base_delay_ms integer not null check (reconnect_base_delay_ms > 0),
  reconnect_max_delay_ms integer not null check (reconnect_max_delay_ms >= reconnect_base_delay_ms),
  reconnect_reset_after_ms integer not null check (reconnect_reset_after_ms > 0)
);
insert into public.danotch_protocol_quota_config(
  singleton, max_reconnects_per_minute, max_reconnects_per_day,
  max_retained_events_per_device, max_retained_bytes_per_device,
  reconnect_base_delay_ms, reconnect_max_delay_ms, reconnect_reset_after_ms
) values (true, 30, 1000, 10000, 67108864, 500, 30000, 120000);

create table public.danotch_reconnect_attempts (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  attempted_at timestamptz not null default now(),
  constraint danotch_reconnect_attempt_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
    on delete cascade
);
create index danotch_reconnect_attempts_device_time_idx
  on public.danotch_reconnect_attempts(device_id, attempted_at);
alter table public.danotch_protocol_quota_config enable row level security;
alter table public.danotch_protocol_quota_config force row level security;
alter table public.danotch_reconnect_attempts enable row level security;
alter table public.danotch_reconnect_attempts force row level security;
revoke all on public.danotch_protocol_quota_config, public.danotch_reconnect_attempts
  from public, anon, authenticated;
grant select on public.danotch_protocol_quota_config to danotch_fencing, danotch_runner;
grant select, insert, delete on public.danotch_reconnect_attempts to danotch_fencing;
grant update (replay_cursor, replay_cursor_event_id, replay_updated_at)
  on public.danotch_devices to danotch_fencing;
grant update (waiting_expires_at) on public.danotch_runs to danotch_runner;
grant update (revoked_at, consumed_transition_id)
  on public.danotch_execution_grants to danotch_fencing, danotch_runner;
grant delete on public.danotch_run_events to danotch_fencing, danotch_runner;

create function public.danotch_enforce_device_journal_quota()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  quota public.danotch_protocol_quota_config;
  retained_count bigint;
  retained_bytes bigint;
begin
  if new.device_id is null then return new; end if;
  select * into quota from public.danotch_protocol_quota_config where singleton;
  if not found then
    raise exception 'protocol quota configuration unavailable' using errcode = '55000';
  end if;
  delete from public.danotch_run_events
  where device_id = new.device_id and retained_until <= now();
  select count(*), coalesce(sum(pg_column_size(event_row)), 0)
  into retained_count, retained_bytes
  from public.danotch_run_events event_row
  where event_row.device_id = new.device_id;
  if retained_count >= quota.max_retained_events_per_device
    or retained_bytes + pg_column_size(new) > quota.max_retained_bytes_per_device then
    raise exception 'device journal storage quota exceeded' using errcode = '54000';
  end if;
  return new;
end
$$;
create trigger danotch_run_events_journal_quota
before insert on public.danotch_run_events
for each row execute function public.danotch_enforce_device_journal_quota();

create function public.danotch_revoke_unstarted_grants_on_cancellation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.danotch_execution_grants grant_row set revoked_at = now()
  where grant_row.user_id = new.user_id
    and grant_row.consumed_at is null and grant_row.revoked_at is null
    and grant_row.action_id in (
      select action.id from public.danotch_local_action_requests action
      where action.run_id = new.run_id and action.user_id = new.user_id
    );
  update public.danotch_local_action_requests set
    state = 'cancelled',
    terminal_at = now()
  where run_id = new.run_id and user_id = new.user_id
    and state in ('offered', 'approved', 'granted');
  return new;
end
$$;
create trigger danotch_run_cancellations_revoke_unstarted_grants
after insert on public.danotch_run_cancellations
for each row execute function public.danotch_revoke_unstarted_grants_on_cancellation();

create or replace function public.danotch_acknowledge_event(
  p_ack_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_event_id uuid,
  p_device_sequence bigint,
  p_fence bigint
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  device public.danotch_devices;
  prior public.danotch_event_acknowledgements;
begin
  select * into device from public.danotch_devices
  where id = p_device_id and user_id = p_user_id for update;
  if not found or device.status <> 'active' or device.current_fence <> p_fence then
    raise exception 'acknowledgement fence mismatch' using errcode = '42501';
  end if;
  select * into prior from public.danotch_event_acknowledgements where id = p_ack_id;
  if found then
    if prior.event_id <> p_event_id or prior.user_id <> p_user_id
      or prior.device_id <> p_device_id
      or prior.device_sequence <> p_device_sequence or prior.fence <> p_fence then
      raise exception 'acknowledgement transition id reused with different content'
        using errcode = '23505';
    end if;
    return 'acknowledged';
  end if;
  if p_device_sequence <> device.replay_cursor + 1 then
    raise exception 'acknowledgement must advance the contiguous cursor'
      using errcode = '40001';
  end if;
  if not exists (
    select 1 from public.danotch_run_events
    where id = p_event_id and user_id = p_user_id and device_id = p_device_id
      and device_sequence = p_device_sequence and retained_until > now()
  ) then
    raise exception 'acknowledgement event is not retained for device'
      using errcode = '42501';
  end if;
  insert into public.danotch_event_acknowledgements(
    id, event_id, user_id, device_id, device_sequence, fence
  ) values (
    p_ack_id, p_event_id, p_user_id, p_device_id, p_device_sequence, p_fence
  );
  update public.danotch_devices set
    replay_cursor = p_device_sequence,
    replay_cursor_event_id = p_event_id,
    replay_updated_at = now()
  where id = p_device_id and user_id = p_user_id;
  return 'acknowledged';
end
$$;

create or replace function public.danotch_cancel_run(
  p_cancellation_id uuid,
  p_run_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_reason text
) returns public.danotch_runs
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_run public.danotch_runs;
  prior public.danotch_run_cancellations;
begin
  select * into current_run from public.danotch_runs
  where id = p_run_id and user_id = p_user_id for update;
  if not found or current_run.device_id is distinct from p_device_id then
    raise exception 'run not found for owner/device' using errcode = '42501';
  end if;
  select * into prior from public.danotch_run_cancellations
  where id = p_cancellation_id;
  if found then
    if prior.run_id <> p_run_id or prior.user_id <> p_user_id
      or prior.device_id is distinct from p_device_id
      or coalesce(prior.reason, '') <> left(coalesce(p_reason, ''), 500) then
      raise exception 'cancellation transition id reused with different content'
        using errcode = '23505';
    end if;
    return current_run;
  end if;
  if current_run.state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired') then
    raise exception 'late cancellation for terminal run' using errcode = '55000';
  end if;
  insert into public.danotch_run_cancellations(id, run_id, user_id, device_id, reason)
  values (
    p_cancellation_id, p_run_id, p_user_id, p_device_id,
    left(coalesce(p_reason, ''), 500)
  );
  current_run := public.danotch_transition_run(
    p_run_id, p_user_id, p_cancellation_id, current_run.revision,
    'cancellation_requested', 'cancellation_requested',
    jsonb_build_object('reason', left(coalesce(p_reason, ''), 500)), null
  );
  if current_run.state = 'cancellation_requested' and exists (
    select 1 from public.danotch_local_action_requests
    where run_id = p_run_id and user_id = p_user_id
  ) then
    current_run := public.danotch_transition_run(
      p_run_id, p_user_id, gen_random_uuid(), current_run.revision,
      'cancelled', 'run_cancelled',
      jsonb_build_object('code', 'device_work_cancelled_before_execution'), null
    );
  end if;
  return current_run;
end
$$;

create function public.danotch_prepare_device_replay(
  p_user_id uuid,
  p_device_id uuid,
  p_fence bigint,
  p_limit integer,
  p_attempt_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  device public.danotch_devices;
  quota public.danotch_protocol_quota_config;
  minute_count bigint;
  day_count bigint;
  first_sequence bigint;
  latest_sequence bigint;
  mode text := 'replay';
  snapshot jsonb;
  events jsonb;
  attempt integer;
begin
  if p_limit < 1 or p_limit > 500 then
    raise exception 'invalid replay page limit' using errcode = '22023';
  end if;
  select * into device from public.danotch_devices
  where id = p_device_id and user_id = p_user_id for update;
  if not found or device.status <> 'active' or device.current_fence <> p_fence then
    raise exception 'stale device replay fence' using errcode = '42501';
  end if;
  select * into quota from public.danotch_protocol_quota_config where singleton;
  if not found then
    raise exception 'protocol quota configuration unavailable' using errcode = '55000';
  end if;
  delete from public.danotch_reconnect_attempts
  where attempted_at < now() - interval '1 day';
  select count(*) into minute_count from public.danotch_reconnect_attempts
  where device_id = p_device_id and attempted_at >= now() - interval '1 minute';
  select count(*) into day_count from public.danotch_reconnect_attempts
  where device_id = p_device_id and attempted_at >= now() - interval '1 day';
  if minute_count >= quota.max_reconnects_per_minute
    or day_count >= quota.max_reconnects_per_day then
    raise exception 'distributed reconnect quota exceeded' using errcode = '54000';
  end if;
  insert into public.danotch_reconnect_attempts(id, user_id, device_id)
  values (p_attempt_id, p_user_id, p_device_id);
  attempt := least(minute_count::integer, 30);

  delete from public.danotch_run_events
  where device_id = p_device_id and retained_until <= now();
  select min(device_sequence), max(device_sequence)
  into first_sequence, latest_sequence
  from public.danotch_run_events
  where device_id = p_device_id and retained_until > now();

  if (
    first_sequence is null
    and device.next_event_sequence - 1 > device.replay_cursor
  ) or (
    first_sequence is not null
    and first_sequence > device.replay_cursor + 1
  ) then
    mode := 'snapshot';
    device.replay_cursor := coalesce(latest_sequence, device.next_event_sequence - 1);
    update public.danotch_devices set
      replay_cursor = device.replay_cursor,
      replay_cursor_event_id = null,
      replay_updated_at = now()
    where id = p_device_id and user_id = p_user_id;
    snapshot := jsonb_build_object(
      'deviceId', p_device_id,
      'fence', p_fence,
      'cursor', device.replay_cursor,
      'generatedAt', now(),
      'runs', coalesce((
        select jsonb_agg(to_jsonb(run_row) order by run_row.created_at)
        from public.danotch_runs run_row
        where run_row.user_id = p_user_id and run_row.device_id = p_device_id
          and run_row.state not in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired')
      ), '[]'::jsonb),
      'actions', coalesce((
        select jsonb_agg(to_jsonb(action_row) order by action_row.offered_at)
        from public.danotch_local_action_requests action_row
        where action_row.user_id = p_user_id and action_row.device_id = p_device_id
          and action_row.state not in ('completed', 'failed', 'cancelled', 'expired', 'rejected')
      ), '[]'::jsonb),
      'grants', coalesce((
        select jsonb_agg(
          to_jsonb(grant_row) - 'grant_hash'
          order by grant_row.created_at
        )
        from public.danotch_execution_grants grant_row
        where grant_row.user_id = p_user_id and grant_row.device_id = p_device_id
          and grant_row.consumed_at is null and grant_row.revoked_at is null
          and grant_row.expires_at > now() and grant_row.fence = p_fence
      ), '[]'::jsonb)
    );
  else
    select coalesce(jsonb_agg(to_jsonb(event_row) order by event_row.device_sequence), '[]'::jsonb)
    into events
    from (
      select id, device_sequence, event_type, transition_id, payload, created_at
      from public.danotch_run_events
      where user_id = p_user_id and device_id = p_device_id
        and device_sequence > device.replay_cursor and retained_until > now()
      order by device_sequence
      limit p_limit
    ) event_row;
  end if;
  return jsonb_build_object(
    'mode', mode,
    'cursor', device.replay_cursor,
    'events', coalesce(events, '[]'::jsonb),
    'snapshot', snapshot,
    'reconnect', jsonb_build_object(
      'strategy', 'exponential_full_jitter',
      'baseDelayMs', quota.reconnect_base_delay_ms,
      'maxDelayMs', quota.reconnect_max_delay_ms,
      'attempt', attempt,
      'retryAfterMs', floor(random() * least(
        quota.reconnect_max_delay_ms,
        quota.reconnect_base_delay_ms * power(2, attempt)
      ))::integer,
      'resetAfterMs', quota.reconnect_reset_after_ms
    )
  );
end
$$;

create function public.danotch_fenced_claim_approval_and_mint_grant(
  p_decision_id uuid,
  p_grant_id uuid,
  p_action_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_parameters_hash text,
  p_grant_hash text,
  p_grant_token text,
  p_fence bigint,
  p_expires_at timestamptz
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  action public.danotch_local_action_requests;
  run_row public.danotch_runs;
  existing public.danotch_action_decisions;
  existing_grant public.danotch_execution_grants;
  next_device_sequence bigint;
  next_run_sequence bigint;
  event_id uuid;
  delivery jsonb;
begin
  if p_grant_token !~ '^[A-Za-z0-9_-]{43}$'
    or p_grant_hash !~ '^[0-9a-f]{64}$'
    or encode(public.digest(p_grant_token, 'sha256'), 'hex') <> p_grant_hash then
    raise exception 'grant token and digest do not match'
      using errcode = '22023';
  end if;
  select * into action from public.danotch_local_action_requests
  where id = p_action_id and user_id = p_user_id and device_id = p_device_id
  for update;
  if not found then
    raise exception 'action not found for owner/device' using errcode = '42501';
  end if;
  select * into run_row from public.danotch_runs
  where id = action.run_id and user_id = p_user_id and device_id = p_device_id
  for update;
  if not found or run_row.state <> 'waiting_for_device'
    or run_row.waiting_expires_at <= now()
    or exists (select 1 from public.danotch_run_cancellations where run_id = run_row.id) then
    raise exception 'run is cancelled, expired, or not waiting for initiating device'
      using errcode = '55000';
  end if;
  perform 1 from public.danotch_devices
  where id = p_device_id and user_id = p_user_id
    and status = 'active' and current_fence = p_fence
  for update;
  if not found then
    raise exception 'stale or revoked device fence' using errcode = '42501';
  end if;
  if action.parameters_hash <> p_parameters_hash
    or action.state not in ('offered', 'granted')
    or action.expires_at <= now()
    or p_expires_at <= now() or p_expires_at > action.expires_at then
    raise exception 'action is not grantable with these parameters or expiry'
      using errcode = '55000';
  end if;

  select * into existing from public.danotch_action_decisions where id = p_decision_id;
  if found then
    if existing.action_id <> p_action_id or existing.user_id <> p_user_id
      or existing.device_id <> p_device_id or existing.decision <> 'approved'
      or existing.parameters_hash <> p_parameters_hash or existing.fence <> p_fence then
      raise exception 'approval transition id reused with different content'
        using errcode = '23505';
    end if;
    select * into existing_grant from public.danotch_execution_grants
    where action_id = p_action_id and user_id = p_user_id;
    select payload into delivery from public.danotch_run_events
    where id = existing_grant.id and user_id = p_user_id;
    return delivery;
  end if;

  insert into public.danotch_action_decisions(
    id, action_id, user_id, device_id, decision, parameters_hash, fence
  ) values (
    p_decision_id, p_action_id, p_user_id, p_device_id,
    'approved', p_parameters_hash, p_fence
  );
  insert into public.danotch_execution_grants(
    id, action_id, user_id, device_id, grant_hash, action_hash,
    parameters_hash, normalized_parameters, capabilities, image_digest,
    fence, expires_at
  ) values (
    p_grant_id, p_action_id, p_user_id, p_device_id, p_grant_hash,
    action.action_hash, action.parameters_hash, action.normalized_parameters,
    action.capabilities, action.image_digest, p_fence, p_expires_at
  );
  update public.danotch_local_action_requests set state = 'granted'
  where id = p_action_id and user_id = p_user_id and state = 'offered';
  update public.danotch_devices set next_event_sequence = next_event_sequence + 1
  where id = p_device_id and user_id = p_user_id
  returning next_event_sequence - 1 into next_device_sequence;
  select coalesce(max(run_sequence), 0) + 1 into next_run_sequence
  from public.danotch_run_events where run_id = run_row.id;
  event_id := p_grant_id;
  delivery := jsonb_build_object(
    'event_id', event_id,
    'sequence', next_device_sequence,
    'grant_id', p_grant_id,
    'action_id', p_action_id,
    'grant_token', p_grant_token,
    'action_hash', action.action_hash,
    'parameters_hash', action.parameters_hash,
    'normalized_parameters', action.normalized_parameters,
    'capabilities', action.capabilities,
    'image_digest', action.image_digest,
    'device_id', p_device_id,
    'fence', p_fence,
    'expires_at', p_expires_at,
    'transition_id', p_decision_id
  );
  insert into public.danotch_run_events(
    id, transition_id, run_id, user_id, device_id, run_sequence,
    device_sequence, event_type, from_state, to_state, payload
  ) values (
    event_id, p_decision_id, run_row.id, p_user_id, p_device_id,
    next_run_sequence, next_device_sequence, 'execution_grant_issued',
    run_row.state, run_row.state, delivery
  );
  return delivery;
end
$$;

create function public.danotch_fenced_consume_execution_grant(
  p_consumption_id uuid,
  p_grant_id uuid,
  p_action_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_grant_hash text,
  p_action_hash text,
  p_parameters_hash text,
  p_normalized_parameters jsonb,
  p_capabilities jsonb,
  p_image_digest text,
  p_fence bigint
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  changed integer;
  existing public.danotch_execution_grants;
begin
  select * into existing from public.danotch_execution_grants
  where id = p_grant_id and action_id = p_action_id and user_id = p_user_id
    and device_id = p_device_id
  for update;
  if found and existing.consumed_transition_id is not null then
    if existing.consumed_transition_id = p_consumption_id
      and existing.grant_hash = p_grant_hash
      and existing.action_hash = p_action_hash
      and existing.parameters_hash = p_parameters_hash
      and existing.normalized_parameters = p_normalized_parameters
      and existing.capabilities = p_capabilities
      and existing.image_digest = p_image_digest
      and existing.fence = p_fence then
      return 'consumed';
    end if;
    raise exception 'grant was already consumed by another transition'
      using errcode = '55000';
  end if;
  update public.danotch_execution_grants grant_row set
    consumed_at = now(),
    consumed_transition_id = p_consumption_id
  where grant_row.id = p_grant_id and grant_row.action_id = p_action_id
    and grant_row.user_id = p_user_id and grant_row.device_id = p_device_id
    and grant_row.grant_hash = p_grant_hash
    and grant_row.action_hash = p_action_hash
    and grant_row.parameters_hash = p_parameters_hash
    and grant_row.normalized_parameters = p_normalized_parameters
    and grant_row.capabilities = p_capabilities
    and grant_row.image_digest = p_image_digest
    and grant_row.fence = p_fence and grant_row.expires_at > now()
    and grant_row.consumed_at is null and grant_row.revoked_at is null
    and exists (
      select 1 from public.danotch_devices device
      where device.id = p_device_id and device.user_id = p_user_id
        and device.status = 'active' and device.current_fence = p_fence
    )
    and exists (
      select 1 from public.danotch_local_action_requests action
      join public.danotch_runs run_row
        on run_row.id = action.run_id and run_row.user_id = action.user_id
      where action.id = p_action_id and action.user_id = p_user_id
        and action.device_id = p_device_id and action.state = 'granted'
        and action.parameters_hash = p_parameters_hash
        and action.action_hash = p_action_hash and action.expires_at > now()
        and run_row.state = 'waiting_for_device'
        and run_row.waiting_expires_at > now()
        and not exists (
          select 1 from public.danotch_run_cancellations cancellation
          where cancellation.run_id = run_row.id
        )
    );
  get diagnostics changed = row_count;
  if changed <> 1 then
    raise exception 'grant is mismatched, stale, revoked, expired, cancelled, or consumed'
      using errcode = '55000';
  end if;
  update public.danotch_local_action_requests set state = 'executing'
  where id = p_action_id and user_id = p_user_id and state = 'granted';
  return 'consumed';
end
$$;

create function public.danotch_expire_waiting_device_runs(p_now timestamptz)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  candidate record;
  expired_count integer := 0;
begin
  for candidate in
    select id, user_id, revision from public.danotch_runs
    where state = 'waiting_for_device' and waiting_expires_at <= p_now
    for update skip locked
  loop
    update public.danotch_execution_grants set revoked_at = p_now
    where user_id = candidate.user_id and consumed_at is null and revoked_at is null
      and action_id in (
        select id from public.danotch_local_action_requests
        where run_id = candidate.id and user_id = candidate.user_id
      );
    update public.danotch_local_action_requests set state = 'expired', terminal_at = p_now
    where run_id = candidate.id and user_id = candidate.user_id
      and state in ('offered', 'approved', 'granted');
    perform public.danotch_transition_run(
      candidate.id, candidate.user_id, gen_random_uuid(), candidate.revision,
      'expired', 'run_expired',
      jsonb_build_object('code', 'waiting_for_device_expired', 'failover', false),
      null
    );
    expired_count := expired_count + 1;
  end loop;
  return expired_count;
end
$$;

revoke all on function public.danotch_enforce_device_journal_quota() from public;
revoke all on function public.danotch_bind_local_action_hash() from public;
revoke all on function public.danotch_fill_protocol_event_fields() from public;
revoke all on function public.danotch_set_waiting_device_expiry() from public;
revoke all on function public.danotch_reject_run_device_change() from public;
revoke all on function public.danotch_revoke_unstarted_grants_on_cancellation() from public;
revoke all on function public.danotch_prepare_device_replay(uuid, uuid, bigint, integer, uuid) from public;
revoke all on function public.danotch_fenced_claim_approval_and_mint_grant(uuid, uuid, uuid, uuid, uuid, text, text, text, bigint, timestamptz) from public;
revoke all on function public.danotch_fenced_consume_execution_grant(uuid, uuid, uuid, uuid, uuid, text, text, text, jsonb, jsonb, text, bigint) from public;
revoke all on function public.danotch_expire_waiting_device_runs(timestamptz) from public;
grant execute on function public.danotch_prepare_device_replay(uuid, uuid, bigint, integer, uuid)
  to danotch_fencing;
grant execute on function public.danotch_fenced_claim_approval_and_mint_grant(uuid, uuid, uuid, uuid, uuid, text, text, text, bigint, timestamptz)
  to danotch_fencing;
grant execute on function public.danotch_fenced_consume_execution_grant(uuid, uuid, uuid, uuid, uuid, text, text, text, jsonb, jsonb, text, bigint)
  to danotch_fencing;
grant execute on function public.danotch_expire_waiting_device_runs(timestamptz)
  to danotch_runner, danotch_reconciler, danotch_fencing;

-- U3's split approval/mint/consume entry points cannot enforce the atomic U10
-- claim and complete binding contract. Keep their definitions for migration
-- readability, but remove every executable operation-role path.
revoke execute on function public.danotch_mint_execution_grant(uuid, uuid, uuid, text, timestamptz)
  from danotch_runner, danotch_fencing;
revoke execute on function public.danotch_consume_execution_grant(uuid, uuid, uuid, uuid, text, text, bigint)
  from danotch_runner, danotch_fencing;
-- END 008_replay_recovery.sql
-- BEGIN 009_device_p256_keys.sql
alter table public.danotch_devices
  drop constraint if exists danotch_devices_key_algorithm_check;

alter table public.danotch_devices
  add constraint danotch_devices_key_algorithm_check
  check (key_algorithm in ('P-256', 'Ed25519'));

drop function public.danotch_enroll_device(
  uuid, uuid, uuid, text, text, text, uuid, integer, timestamptz
);

create function public.danotch_enroll_device(
  p_challenge_id uuid,
  p_device_id uuid,
  p_user_id uuid,
  p_display_name text,
  p_public_key text,
  p_key_algorithm text,
  p_key_fingerprint text,
  p_replacement_device_id uuid,
  p_max_devices integer,
  p_now timestamptz
) returns public.danotch_devices
language plpgsql
security invoker
set search_path = ''
as $$
declare
  challenge public.danotch_device_challenges;
  enrolled public.danotch_devices;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));
  select * into challenge from public.danotch_device_challenges
  where id = p_challenge_id and user_id = p_user_id for update;
  if not found or challenge.purpose <> 'enrollment'
    or challenge.device_id is not null or challenge.consumed_at is not null
    or challenge.expires_at <= p_now then
    raise exception 'invalid or consumed enrollment challenge' using errcode = '42501';
  end if;
  if p_max_devices < 1 or p_max_devices > 20
    or length(p_display_name) not between 1 and 80
    or p_key_algorithm not in ('P-256', 'Ed25519')
    or p_key_fingerprint !~ '^[0-9a-f]{64}$'
    or length(p_public_key) > 1000 then
    raise exception 'invalid enrollment parameters' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.danotch_devices
    where key_fingerprint = p_key_fingerprint
  ) then
    raise exception 'device key is already enrolled' using errcode = '23505';
  end if;
  if p_replacement_device_id is null then
    if (
      select count(*) from public.danotch_devices
      where user_id = p_user_id and status = 'active'
    ) >= p_max_devices then
      raise exception 'active device limit reached' using errcode = '54000';
    end if;
  elsif not exists (
    select 1 from public.danotch_devices
    where id = p_replacement_device_id and user_id = p_user_id
      and status = 'active' for update
  ) then
    raise exception 'replacement device is not active for owner' using errcode = '42501';
  end if;

  update public.danotch_device_challenges
  set consumed_at = p_now where id = p_challenge_id;
  insert into public.danotch_devices(
    id, user_id, display_name, public_key, key_algorithm, key_format,
    key_fingerprint, status, current_fence, enrolled_at
  ) values (
    p_device_id, p_user_id, p_display_name, p_public_key, p_key_algorithm,
    'spki-pem', p_key_fingerprint, 'active', 0, p_now
  ) returning * into enrolled;

  if p_replacement_device_id is not null then
    update public.danotch_devices set
      status = 'revoked',
      revoked_at = p_now,
      current_fence = current_fence + 1,
      replaced_by_device_id = p_device_id
    where id = p_replacement_device_id and user_id = p_user_id;
    update public.danotch_gateway_tickets set consumed_at = p_now
    where user_id = p_user_id and device_id = p_replacement_device_id
      and consumed_at is null;
  end if;
  return enrolled;
end
$$;

revoke all on function public.danotch_enroll_device(
  uuid, uuid, uuid, text, text, text, text, uuid, integer, timestamptz
) from public;

grant execute on function public.danotch_enroll_device(
  uuid, uuid, uuid, text, text, text, text, uuid, integer, timestamptz
) to danotch_fencing;
-- END 009_device_p256_keys.sql
-- BEGIN 010_executor_grant_contract.sql
-- U5 executor contract expansion. Workspace bookmark identifiers are opaque
-- local lookup keys; bookmark bytes never enter hosted storage.

alter table public.danotch_local_action_requests
  add column workspace_bookmark_id text,
  add column result_disclosure_policy jsonb;

update public.danotch_local_action_requests
set
  workspace_bookmark_id = 'workspace-' || id::text,
  result_disclosure_policy = jsonb_build_object(
    'sensitive_output',
    coalesce((capabilities ->> 'sensitive_output_disclosure')::boolean, false),
    'upload',
    coalesce((capabilities ->> 'result_upload')::boolean, false)
  );

alter table public.danotch_local_action_requests
  alter column workspace_bookmark_id set not null,
  alter column result_disclosure_policy set not null,
  add constraint danotch_local_action_workspace_bookmark_id_check
    check (workspace_bookmark_id ~ '^[A-Za-z0-9._-]{1,128}$'),
  add constraint danotch_local_action_result_disclosure_check
    check (
      jsonb_typeof(result_disclosure_policy) = 'object'
      and result_disclosure_policy ?& array['sensitive_output', 'upload']
      and result_disclosure_policy - array['sensitive_output', 'upload'] = '{}'::jsonb
      and jsonb_typeof(result_disclosure_policy -> 'sensitive_output') = 'boolean'
      and jsonb_typeof(result_disclosure_policy -> 'upload') = 'boolean'
    );

alter table public.danotch_execution_grants
  add column registry_version text,
  add column action_type text,
  add column workspace_bookmark_id text,
  add column result_disclosure_policy jsonb,
  add column device_key_fingerprint text;

update public.danotch_execution_grants grant_row
set
  registry_version = action.registry_version,
  action_type = action.action_type,
  workspace_bookmark_id = action.workspace_bookmark_id,
  result_disclosure_policy = action.result_disclosure_policy,
  device_key_fingerprint = device.key_fingerprint
from public.danotch_local_action_requests action,
     public.danotch_devices device
where action.id = grant_row.action_id
  and device.id = grant_row.device_id
  and device.user_id = grant_row.user_id;

alter table public.danotch_execution_grants
  alter column registry_version set not null,
  alter column action_type set not null,
  alter column workspace_bookmark_id set not null,
  alter column result_disclosure_policy set not null,
  alter column device_key_fingerprint set not null,
  add constraint danotch_execution_grant_workspace_bookmark_id_check
    check (workspace_bookmark_id ~ '^[A-Za-z0-9._-]{1,128}$'),
  add constraint danotch_execution_grant_device_key_fingerprint_check
    check (device_key_fingerprint ~ '^[0-9a-f]{64}$');

create function public.danotch_bind_execution_grant_contract()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  action public.danotch_local_action_requests;
  device public.danotch_devices;
begin
  select * into action
  from public.danotch_local_action_requests
  where id = new.action_id and user_id = new.user_id and device_id = new.device_id;
  select * into device
  from public.danotch_devices
  where id = new.device_id and user_id = new.user_id;
  if action.id is null or device.id is null then
    raise exception 'execution grant action/device binding is invalid'
      using errcode = '42501';
  end if;
  new.registry_version := action.registry_version;
  new.action_type := action.action_type;
  new.workspace_bookmark_id := action.workspace_bookmark_id;
  new.result_disclosure_policy := action.result_disclosure_policy;
  new.device_key_fingerprint := device.key_fingerprint;
  return new;
end
$$;

create trigger danotch_execution_grant_bind_contract
before insert or update of action_id, user_id, device_id
on public.danotch_execution_grants
for each row execute function public.danotch_bind_execution_grant_contract();

create function public.danotch_get_execution_grant_contract(
  p_grant_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_fence bigint
) returns jsonb
language sql
security definer
set search_path = ''
stable
as $$
  select jsonb_build_object(
    'registry_version', grant_row.registry_version,
    'action_type', grant_row.action_type,
    'workspace_bookmark_id', grant_row.workspace_bookmark_id,
    'result_disclosure_policy', grant_row.result_disclosure_policy,
    'device_key_fingerprint', grant_row.device_key_fingerprint
  )
  from public.danotch_execution_grants grant_row
  join public.danotch_devices device
    on device.id = grant_row.device_id and device.user_id = grant_row.user_id
  where grant_row.id = p_grant_id
    and grant_row.user_id = p_user_id
    and grant_row.device_id = p_device_id
    and grant_row.fence = p_fence
    and device.current_fence = p_fence
    and device.status = 'active'
    and grant_row.consumed_at is null
    and grant_row.revoked_at is null
    and grant_row.expires_at > now()
$$;

revoke all on function public.danotch_bind_execution_grant_contract() from public;
revoke all on function public.danotch_get_execution_grant_contract(uuid, uuid, uuid, bigint)
  from public;
grant execute on function public.danotch_get_execution_grant_contract(uuid, uuid, uuid, bigint)
  to danotch_fencing;

create function public.danotch_get_device_verification_key(
  p_user_id uuid,
  p_device_id uuid,
  p_fence bigint
) returns jsonb
language sql
security definer
set search_path = ''
stable
as $$
  select jsonb_build_object(
    'public_key', device.public_key,
    'key_algorithm', device.key_algorithm,
    'key_fingerprint', device.key_fingerprint
  )
  from public.danotch_devices device
  where device.user_id = p_user_id
    and device.id = p_device_id
    and device.current_fence = p_fence
    and device.status = 'active'
$$;

revoke all on function public.danotch_get_device_verification_key(uuid, uuid, bigint)
  from public;
grant execute on function public.danotch_get_device_verification_key(uuid, uuid, bigint)
  to danotch_fencing;

create function public.danotch_enrich_executor_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  action public.danotch_local_action_requests;
  grant_row public.danotch_execution_grants;
begin
  if new.event_type = 'local_action_offered' then
    select * into action
    from public.danotch_local_action_requests
    where id = (coalesce(new.payload ->> 'action_id', new.payload ->> 'actionId'))::uuid
      and run_id = new.run_id
      and user_id = new.user_id
      and device_id = new.device_id;
    if action.id is null then
      raise exception 'local action event contract is missing'
        using errcode = '23503';
    end if;
    new.payload := new.payload || jsonb_build_object(
      'action_id', action.id,
      'run_id', action.run_id,
      'session_id', action.run_id,
      'registry_version', action.registry_version,
      'action_type', action.action_type,
      'action_hash', action.action_hash,
      'normalized_parameters', action.normalized_parameters,
      'parameters_hash', action.parameters_hash,
      'capabilities', action.capabilities,
      'image_digest', action.image_digest,
      'workspace_bookmark_id', action.workspace_bookmark_id,
      'result_disclosure_policy', action.result_disclosure_policy,
      'expires_at', action.expires_at
    );
  elsif new.event_type = 'execution_grant_issued' then
    select * into grant_row
    from public.danotch_execution_grants
    where id = (new.payload ->> 'grant_id')::uuid
      and user_id = new.user_id
      and device_id = new.device_id;
    if grant_row.id is null then
      raise exception 'execution grant event contract is missing'
        using errcode = '23503';
    end if;
    new.payload := new.payload || jsonb_build_object(
      'registry_version', grant_row.registry_version,
      'action_type', grant_row.action_type,
      'workspace_bookmark_id', grant_row.workspace_bookmark_id,
      'result_disclosure_policy', grant_row.result_disclosure_policy,
      'device_key_fingerprint', grant_row.device_key_fingerprint
    );
  end if;
  return new;
end
$$;

create trigger danotch_run_events_executor_contract
before insert on public.danotch_run_events
for each row
when (new.event_type in ('local_action_offered', 'execution_grant_issued'))
execute function public.danotch_enrich_executor_event();

revoke all on function public.danotch_enrich_executor_event() from public;
-- END 010_executor_grant_contract.sql
-- BEGIN 011_identity_oauth_actions_scheduler.sql
-- U6: verified identity provisioning, distributed quotas, one-time OAuth state,
-- immutable external actions, and replica-safe scheduler leases.

alter table auth.users
  add column if not exists email text,
  add column if not exists email_confirmed_at timestamptz,
  add column if not exists raw_user_meta_data jsonb not null default '{}'::jsonb;

create table public.danotch_capability_quota_config (
  capability text primary key check (capability in (
    'signup', 'trial', 'provider', 'enrollment', 'oauth', 'scheduler',
    'action', 'replay', 'storage'
  )),
  window_seconds integer not null check (window_seconds between 1 and 2592000),
  capacity integer not null check (capacity > 0),
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

insert into public.danotch_capability_quota_config(capability, window_seconds, capacity)
values
  ('signup', 3600, 5), ('trial', 2592000, 1), ('provider', 60, 10),
  ('enrollment', 3600, 10), ('oauth', 900, 10), ('scheduler', 60, 30),
  ('action', 60, 30), ('replay', 60, 120), ('storage', 3600, 1000)
on conflict (capability) do nothing;

create table public.danotch_capability_quota_events (
  id uuid primary key default gen_random_uuid(),
  capability text not null references public.danotch_capability_quota_config(capability),
  subject_hash text not null check (subject_hash ~ '^[0-9a-f]{64}$'),
  cost integer not null check (cost > 0),
  idempotency_key text,
  created_at timestamptz not null default now()
);
create index danotch_capability_quota_events_window_idx
  on public.danotch_capability_quota_events(capability, subject_hash, created_at desc);
create unique index danotch_capability_quota_events_idempotency_idx
  on public.danotch_capability_quota_events(capability, subject_hash, idempotency_key)
  where idempotency_key is not null;

create function public.danotch_consume_capability_quota(
  p_capability text,
  p_subject_hash text,
  p_cost integer default 1,
  p_idempotency_key text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  quota public.danotch_capability_quota_config;
  used bigint;
  oldest timestamptz;
begin
  if p_cost <= 0 or p_subject_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid quota request' using errcode = '22023';
  end if;
  select * into quota from public.danotch_capability_quota_config
    where capability = p_capability and enabled for update;
  if quota.capability is null then
    raise exception 'capability quota configuration unavailable' using errcode = '55000';
  end if;
  if p_idempotency_key is not null and exists (
    select 1 from public.danotch_capability_quota_events
    where capability = p_capability and subject_hash = p_subject_hash
      and idempotency_key = p_idempotency_key
  ) then
    return jsonb_build_object('allowed', true, 'idempotent', true);
  end if;
  select coalesce(sum(cost), 0), min(created_at) into used, oldest
  from public.danotch_capability_quota_events
  where capability = p_capability and subject_hash = p_subject_hash
    and created_at > now() - make_interval(secs => quota.window_seconds);
  if used + p_cost > quota.capacity then
    return jsonb_build_object(
      'allowed', false,
      'retry_after_seconds',
      greatest(1, quota.window_seconds - extract(epoch from now() - oldest)::integer)
    );
  end if;
  insert into public.danotch_capability_quota_events(
    capability, subject_hash, cost, idempotency_key
  ) values (p_capability, p_subject_hash, p_cost, p_idempotency_key);
  return jsonb_build_object('allowed', true, 'remaining', quota.capacity - used - p_cost);
exception when unique_violation then
  return jsonb_build_object('allowed', true, 'idempotent', true);
end
$$;

create table public.danotch_verified_provisioning (
  user_id uuid primary key references auth.users(id) on delete cascade,
  profile_ready boolean not null default false,
  apps_ready boolean not null default false,
  trial_ready boolean not null default false,
  attempts integer not null default 0,
  last_error text,
  completed_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.danotch_signup_enrollments (
  email_hash text primary key check (email_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid unique references auth.users(id) on delete cascade,
  requested_at timestamptz not null default now(),
  verified_at timestamptz,
  status text not null default 'pending'
    check (status in ('pending', 'verified', 'blocked'))
);

create function public.danotch_provision_verified_user(
  p_user_id uuid,
  p_email text,
  p_full_name text,
  p_trial_subject_hash text,
  p_apps text[]
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_verified_at timestamptz;
  quota_result jsonb;
  provision public.danotch_verified_provisioning;
  profile_exists boolean;
begin
  select email_confirmed_at into v_verified_at from auth.users where id = p_user_id for update;
  if v_verified_at is null then
    raise exception 'verified email required' using errcode = '42501';
  end if;
  select exists(select 1 from public.danotch_user_profiles where id = p_user_id)
    into profile_exists;
  if not profile_exists and not exists (
    select 1 from public.danotch_signup_enrollments
    where email_hash = encode(
        digest(convert_to(lower(p_email), 'utf8'), 'sha256'), 'hex'
      )
      and (user_id is null or user_id = p_user_id)
      and status = 'pending'
      and requested_at <= v_verified_at
  ) then
    raise exception 'verified signup enrollment required' using errcode = '42501';
  end if;
  update public.danotch_signup_enrollments set user_id = p_user_id
    where email_hash = encode(
      digest(convert_to(lower(p_email), 'utf8'), 'sha256'), 'hex'
    ) and (user_id is null or user_id = p_user_id);
  insert into public.danotch_verified_provisioning(user_id, attempts)
    values (p_user_id, 1)
    on conflict (user_id) do update set attempts =
      public.danotch_verified_provisioning.attempts + 1, updated_at = now();
  insert into public.danotch_user_profiles(
    id, email, full_name, trial_started_at, trial_ends_at, billing_status
  ) values (
    p_user_id, lower(p_email), p_full_name, null, null, 'inactive'
  ) on conflict (id) do update set
    email = excluded.email,
    full_name = case when public.danotch_user_profiles.full_name = ''
      then excluded.full_name else public.danotch_user_profiles.full_name end;
  update public.danotch_verified_provisioning set profile_ready = true where user_id = p_user_id;
  insert into public.danotch_connected_apps(user_id, app_type, active)
    select p_user_id, app_type, false from unnest(p_apps) app_type
    on conflict (user_id, app_type) do nothing;
  update public.danotch_verified_provisioning set apps_ready = true where user_id = p_user_id;
  select * into provision from public.danotch_verified_provisioning where user_id = p_user_id;
  if not provision.trial_ready then
    quota_result := public.danotch_consume_capability_quota(
      'trial', p_trial_subject_hash, 1, p_user_id::text
    );
    if coalesce((quota_result ->> 'allowed')::boolean, false) is not true then
      raise exception 'trial quota exceeded' using errcode = 'P0001';
    end if;
    update public.danotch_user_profiles set
      trial_started_at = coalesce(trial_started_at, now()),
      trial_ends_at = coalesce(trial_ends_at, now() + interval '14 days'),
      billing_status = case when billing_status = 'inactive' then 'trialing' else billing_status end
    where id = p_user_id;
    update public.danotch_verified_provisioning set trial_ready = true where user_id = p_user_id;
  end if;
  update public.danotch_verified_provisioning
    set completed_at = now(), last_error = null, updated_at = now()
    where user_id = p_user_id and profile_ready and apps_ready and trial_ready;
  update public.danotch_signup_enrollments
    set status = 'verified', verified_at = v_verified_at
    where user_id = p_user_id and status = 'pending';
  return (select to_jsonb(row_value) from (
    select profile_ready, apps_ready, trial_ready, completed_at
    from public.danotch_verified_provisioning where user_id = p_user_id
  ) row_value);
end
$$;

create table public.danotch_oauth_link_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.danotch_devices(id) on delete cascade,
  app_type text not null,
  toolkit_slug text not null,
  state_hash text not null unique check (state_hash ~ '^[0-9a-f]{64}$'),
  pkce_verifier_hash text check (pkce_verifier_hash is null or pkce_verifier_hash ~ '^[0-9a-f]{64}$'),
  callback_url text not null check (callback_url ~ '^https://'),
  prior_account_id text,
  candidate_account_id text,
  status text not null default 'pending'
    check (status in ('pending', 'confirmed', 'cancelled', 'expired', 'failed', 'superseded')),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint danotch_oauth_link_attempts_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id)
);
create unique index danotch_oauth_link_attempts_one_active_idx
  on public.danotch_oauth_link_attempts(user_id, app_type)
  where status = 'pending' and consumed_at is null;
create index danotch_oauth_link_attempts_owner_idx
  on public.danotch_oauth_link_attempts(user_id, created_at desc);

alter table public.danotch_pending_actions
  add column registry_version text not null default '1',
  add column normalized_parameters jsonb,
  add column parameters_hash text,
  add column account_id text,
  add column device_id uuid references public.danotch_devices(id),
  add column delivery_semantics text,
  add column retry_semantics text,
  add column reconciliation_semantics text,
  add column terminal_decision text,
  add column reconciliation_required boolean not null default false;
update public.danotch_pending_actions set
  normalized_parameters = payload,
  parameters_hash = encode(digest(convert_to(payload::text, 'utf8'), 'sha256'), 'hex'),
  delivery_semantics = 'none',
  retry_semantics = 'never_after_ambiguous',
  reconciliation_semantics = 'provider_lookup_or_manual';
alter table public.danotch_pending_actions
  alter column normalized_parameters set not null,
  alter column parameters_hash set not null,
  alter column delivery_semantics set not null,
  alter column retry_semantics set not null,
  alter column reconciliation_semantics set not null,
  add constraint danotch_pending_actions_owned_device_fk
    foreign key (device_id, user_id)
    references public.danotch_devices(id, user_id),
  add constraint danotch_pending_actions_parameters_hash_check
    check (parameters_hash ~ '^[0-9a-f]{64}$');

create function public.danotch_pending_action_immutable_contract()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if (new.user_id, new.action_type, new.payload, new.registry_version,
      new.normalized_parameters, new.parameters_hash, new.account_id, new.device_id,
      new.idempotency_key, new.expires_at, new.delivery_semantics,
      new.retry_semantics, new.reconciliation_semantics)
    is distinct from
     (old.user_id, old.action_type, old.payload, old.registry_version,
      old.normalized_parameters, old.parameters_hash, old.account_id, old.device_id,
      old.idempotency_key, old.expires_at, old.delivery_semantics,
      old.retry_semantics, old.reconciliation_semantics) then
    raise exception 'pending action contract is immutable' using errcode = '42501';
  end if;
  return new;
end
$$;
create trigger danotch_pending_action_contract_immutable
before update on public.danotch_pending_actions
for each row execute function public.danotch_pending_action_immutable_contract();

create function public.danotch_expire_pending_actions(p_now timestamptz default now())
returns integer
language plpgsql security definer set search_path = ''
as $$
declare expired_count integer;
begin
  update public.danotch_pending_actions set
    status = 'expired',
    terminal_decision = 'expired',
    decided_at = p_now
  where status = 'pending' and expires_at <= p_now;
  get diagnostics expired_count = row_count;
  return expired_count;
end
$$;

alter table public.danotch_scheduled_tasks
  add column execution_location text not null default 'hosted'
    check (execution_location in ('hosted', 'device_local')),
  add column bound_device_id uuid references public.danotch_devices(id),
  add column lease_owner text,
  add column lease_token uuid,
  add column lease_expires_at timestamptz,
  add column attempt_count integer not null default 0,
  add column max_attempts integer not null default 3 check (max_attempts between 1 and 10),
  add column run_state text not null default 'ready'
    check (run_state in ('ready', 'leased', 'queued_local', 'retry_wait', 'cancelled', 'poisoned')),
  add column retry_at timestamptz,
  add column last_attempt_id uuid;
alter table public.danotch_scheduled_tasks
  add constraint danotch_scheduled_tasks_owned_device_fk
    foreign key (bound_device_id, user_id)
    references public.danotch_devices(id, user_id),
  add constraint danotch_scheduled_tasks_device_binding_check check (
    (execution_location = 'hosted' and bound_device_id is null)
    or (execution_location = 'device_local' and bound_device_id is not null)
  );
grant insert (execution_location, bound_device_id)
  on public.danotch_scheduled_tasks to authenticated;
create index danotch_scheduled_tasks_lease_idx
  on public.danotch_scheduled_tasks(run_state, next_run_at, lease_expires_at);

create function public.danotch_claim_due_schedules(
  p_worker_id text,
  p_limit integer default 25,
  p_lease_seconds integer default 120
) returns setof public.danotch_scheduled_tasks
language plpgsql security definer set search_path = ''
as $$
begin
  if p_worker_id = '' or p_limit not between 1 and 100 or p_lease_seconds not between 15 and 900 then
    raise exception 'invalid scheduler lease request' using errcode = '22023';
  end if;
  return query
  with candidates as (
    select id from public.danotch_scheduled_tasks
    where enabled
      and run_state not in ('cancelled', 'poisoned', 'queued_local')
      and coalesce(retry_at, next_run_at) <= now()
      and (lease_expires_at is null or lease_expires_at <= now())
    order by coalesce(retry_at, next_run_at)
    for update skip locked limit p_limit
  ), claimed as (
    update public.danotch_scheduled_tasks task set
      run_state = 'leased',
      lease_owner = p_worker_id,
      lease_token = gen_random_uuid(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      attempt_count = case when task.last_attempt_id is null then 1 else task.attempt_count + 1 end,
      last_attempt_id = gen_random_uuid()
    from candidates where task.id = candidates.id
    returning task.*
  )
  select * from claimed;
end
$$;

create function public.danotch_finish_schedule_attempt(
  p_task_id uuid,
  p_worker_id text,
  p_lease_token uuid,
  p_outcome text,
  p_next_run_at timestamptz,
  p_last_result jsonb default null
) returns text
language plpgsql security definer set search_path = ''
as $$
declare task public.danotch_scheduled_tasks;
  local_run_id uuid;
  local_device_sequence bigint;
begin
  select * into task from public.danotch_scheduled_tasks
    where id = p_task_id for update;
  if task.id is null or task.run_state <> 'leased' or task.lease_owner <> p_worker_id
    or task.lease_token <> p_lease_token or task.lease_expires_at <= now() then
    return 'stale';
  end if;
  if p_outcome = 'completed' then
    update public.danotch_scheduled_tasks set run_state = 'ready',
      next_run_at = p_next_run_at, retry_at = null, lease_owner = null,
      lease_token = null, lease_expires_at = null, last_run_at = now(),
      run_count = run_count + 1, last_result = p_last_result, attempt_count = 0
    where id = p_task_id;
  elsif p_outcome = 'queued_local' and task.execution_location = 'device_local' then
    local_run_id := gen_random_uuid();
    update public.danotch_devices set next_event_sequence = next_event_sequence + 1
      where id = task.bound_device_id and user_id = task.user_id and status = 'active'
      returning next_event_sequence - 1 into local_device_sequence;
    if local_device_sequence is null then
      update public.danotch_scheduled_tasks set run_state = 'retry_wait',
        retry_at = now() + interval '1 minute', lease_owner = null,
        lease_token = null, lease_expires_at = null,
        last_result = jsonb_build_object('status', 'waiting_for_bound_device')
      where id = p_task_id;
      return 'waiting_for_device';
    end if;
    insert into public.danotch_runs(
      id, user_id, device_id, idempotency_key, state, input
    ) values (
      local_run_id, task.user_id, task.bound_device_id,
      'schedule:' || task.id::text || ':attempt:' || task.last_attempt_id::text,
      'queued',
      jsonb_build_object(
        'source', 'scheduled_task', 'schedule_id', task.id,
        'name', task.name, 'prompt', task.prompt, 'execution_location', 'device_local'
      )
    );
    insert into public.danotch_run_events(
      id, run_id, user_id, device_id, run_sequence, device_sequence,
      event_type, to_state, payload
    ) values (
      gen_random_uuid(), local_run_id, task.user_id, task.bound_device_id, 1,
      local_device_sequence, 'run_created', 'queued',
      jsonb_build_object('source', 'scheduled_task', 'schedule_id', task.id)
    );
    update public.danotch_scheduled_tasks set run_state = 'ready',
      next_run_at = p_next_run_at, lease_owner = null, lease_token = null,
      lease_expires_at = null, last_run_at = now(), run_count = run_count + 1,
      last_result = p_last_result, attempt_count = 0 where id = p_task_id;
  elsif p_outcome = 'retry' and task.attempt_count < task.max_attempts then
    update public.danotch_scheduled_tasks set run_state = 'retry_wait',
      retry_at = now() + make_interval(secs => least(3600, 30 * (2 ^ task.attempt_count)::integer)),
      lease_owner = null, lease_token = null, lease_expires_at = null,
      last_result = p_last_result where id = p_task_id;
  else
    update public.danotch_scheduled_tasks set run_state = 'poisoned',
      enabled = false, lease_owner = null, lease_token = null,
      lease_expires_at = null, last_result = p_last_result where id = p_task_id;
  end if;
  return 'updated';
end
$$;

create function public.danotch_renew_schedule_lease(
  p_task_id uuid,
  p_worker_id text,
  p_lease_token uuid,
  p_lease_seconds integer default 120
) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare renewed integer;
begin
  if p_worker_id = '' or p_lease_seconds not between 15 and 900 then
    raise exception 'invalid scheduler lease renewal' using errcode = '22023';
  end if;
  update public.danotch_scheduled_tasks set
    lease_expires_at = now() + make_interval(secs => p_lease_seconds)
  where id = p_task_id and run_state = 'leased'
    and lease_owner = p_worker_id and lease_token = p_lease_token
    and enabled and lease_expires_at > now();
  get diagnostics renewed = row_count;
  return renewed = 1;
end
$$;

alter table public.danotch_capability_quota_config enable row level security;
alter table public.danotch_capability_quota_events enable row level security;
alter table public.danotch_verified_provisioning enable row level security;
alter table public.danotch_signup_enrollments enable row level security;
alter table public.danotch_oauth_link_attempts enable row level security;
alter table public.danotch_capability_quota_config force row level security;
alter table public.danotch_capability_quota_events force row level security;
alter table public.danotch_verified_provisioning force row level security;
alter table public.danotch_signup_enrollments force row level security;
alter table public.danotch_oauth_link_attempts force row level security;

revoke all on public.danotch_capability_quota_config,
  public.danotch_capability_quota_events,
  public.danotch_verified_provisioning,
  public.danotch_signup_enrollments,
  public.danotch_oauth_link_attempts from public, anon, authenticated;
revoke all on function public.danotch_consume_capability_quota(text, text, integer, text),
  public.danotch_provision_verified_user(uuid, text, text, text, text[]),
  public.danotch_claim_due_schedules(text, integer, integer),
  public.danotch_finish_schedule_attempt(uuid, text, uuid, text, timestamptz, jsonb),
  public.danotch_renew_schedule_lease(uuid, text, uuid, integer),
  public.danotch_expire_pending_actions(timestamptz)
  from public, anon, authenticated;

grant select, insert, update on public.danotch_verified_provisioning to danotch_bootstrap;
grant select, insert, update on public.danotch_signup_enrollments to danotch_bootstrap;
grant select, insert, update, delete on public.danotch_oauth_link_attempts to danotch_reconciler;
grant execute on function public.danotch_provision_verified_user(uuid, text, text, text, text[])
  to danotch_bootstrap;
grant execute on function public.danotch_claim_due_schedules(text, integer, integer),
  public.danotch_finish_schedule_attempt(uuid, text, uuid, text, timestamptz, jsonb),
  public.danotch_renew_schedule_lease(uuid, text, uuid, integer)
  to danotch_scheduler;
grant execute on function public.danotch_consume_capability_quota(text, text, integer, text)
  to danotch_bootstrap, danotch_scheduler, danotch_fencing, danotch_reconciler,
     danotch_provider, danotch_runner;
grant execute on function public.danotch_expire_pending_actions(timestamptz)
  to danotch_reconciler;

revoke all on function public.danotch_pending_action_immutable_contract() from public;
-- END 011_identity_oauth_actions_scheduler.sql
-- BEGIN 012_launch_readiness.sql
-- Launch-readiness corrections for verified provisioning and protocol journals.

-- A fresh profile must satisfy the billing_status constraint before the trial
-- fields are finalized later in the same transaction.
create or replace function public.danotch_provision_verified_user(
  p_user_id uuid,
  p_email text,
  p_full_name text,
  p_trial_subject_hash text,
  p_apps text[]
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_verified_at timestamptz;
  quota_result jsonb;
  provision public.danotch_verified_provisioning;
  profile_exists boolean;
begin
  select email_confirmed_at into v_verified_at from auth.users where id = p_user_id for update;
  if v_verified_at is null then
    raise exception 'verified email required' using errcode = '42501';
  end if;
  select exists(select 1 from public.danotch_user_profiles where id = p_user_id)
    into profile_exists;
  if not profile_exists and not exists (
    select 1 from public.danotch_signup_enrollments
    where email_hash = encode(
        digest(convert_to(lower(p_email), 'utf8'), 'sha256'), 'hex'
      )
      and (user_id is null or user_id = p_user_id)
      and status = 'pending'
      and requested_at <= v_verified_at
  ) then
    raise exception 'verified signup enrollment required' using errcode = '42501';
  end if;
  update public.danotch_signup_enrollments set user_id = p_user_id
    where email_hash = encode(
      digest(convert_to(lower(p_email), 'utf8'), 'sha256'), 'hex'
    ) and (user_id is null or user_id = p_user_id);
  insert into public.danotch_verified_provisioning(user_id, attempts)
    values (p_user_id, 1)
    on conflict (user_id) do update set attempts =
      public.danotch_verified_provisioning.attempts + 1, updated_at = now();
  insert into public.danotch_user_profiles(
    id, email, full_name, trial_started_at, trial_ends_at, billing_status
  ) values (
    p_user_id, lower(p_email), p_full_name, null, null, 'trialing'
  ) on conflict (id) do update set
    email = excluded.email,
    full_name = case when public.danotch_user_profiles.full_name = ''
      then excluded.full_name else public.danotch_user_profiles.full_name end;
  update public.danotch_verified_provisioning set profile_ready = true where user_id = p_user_id;
  insert into public.danotch_connected_apps(user_id, app_type, active)
    select p_user_id, app_type, false from unnest(p_apps) app_type
    on conflict (user_id, app_type) do nothing;
  update public.danotch_verified_provisioning set apps_ready = true where user_id = p_user_id;
  select * into provision from public.danotch_verified_provisioning where user_id = p_user_id;
  if not provision.trial_ready then
    quota_result := public.danotch_consume_capability_quota(
      'trial', p_trial_subject_hash, 1, p_user_id::text
    );
    if coalesce((quota_result ->> 'allowed')::boolean, false) is not true then
      raise exception 'trial quota exceeded' using errcode = 'P0001';
    end if;
    update public.danotch_user_profiles set
      trial_started_at = coalesce(trial_started_at, now()),
      trial_ends_at = coalesce(trial_ends_at, now() + interval '14 days'),
      billing_status = case
        when lifetime_purchased_at is not null then 'paid'
        else 'trialing'
      end
    where id = p_user_id;
    update public.danotch_verified_provisioning set trial_ready = true where user_id = p_user_id;
  end if;
  update public.danotch_verified_provisioning
    set completed_at = now(), last_error = null, updated_at = now()
    where user_id = p_user_id and profile_ready and apps_ready and trial_ready;
  update public.danotch_signup_enrollments
    set status = 'verified', verified_at = v_verified_at
    where user_id = p_user_id and status = 'pending';
  return (select to_jsonb(row_value) from (
    select profile_ready, apps_ready, trial_ready, completed_at
    from public.danotch_verified_provisioning where user_id = p_user_id
  ) row_value);
end
$$;

-- Run revisions count state transitions, while the journal also contains grant
-- events. Allocate the next run sequence from the journal itself so a later
-- transition cannot collide with a non-transition event.
create or replace function public.danotch_transition_run(
  p_run_id uuid,
  p_user_id uuid,
  p_transition_id uuid,
  p_expected_revision bigint,
  p_target_state text,
  p_event_type text,
  p_payload jsonb default '{}'::jsonb,
  p_checkpoint jsonb default null
) returns public.danotch_runs
language plpgsql
security invoker
set search_path = ''
as $$
declare
  current_run public.danotch_runs;
  next_device_sequence bigint;
  next_run_sequence bigint;
  allowed boolean := false;
begin
  select * into current_run from public.danotch_runs
  where id = p_run_id and user_id = p_user_id for update;
  if not found then
    raise exception 'run not found for owner' using errcode = '42501';
  end if;

  if exists (select 1 from public.danotch_run_events where id = p_transition_id) then
    if not exists (
      select 1 from public.danotch_run_events
      where id = p_transition_id and run_id = p_run_id and user_id = p_user_id
        and to_state = p_target_state and event_type = p_event_type
        and payload = coalesce(p_payload, '{}'::jsonb)
        and checkpoint is not distinct from p_checkpoint
    ) then
      raise exception 'transition id reused with different content' using errcode = '23505';
    end if;
    return current_run;
  end if;
  if current_run.revision <> p_expected_revision then
    raise exception 'out-of-order transition: expected %, actual %',
      p_expected_revision, current_run.revision using errcode = '40001';
  end if;
  if current_run.state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired') then
    raise exception 'late transition for terminal run' using errcode = '55000';
  end if;
  if p_target_state is distinct from (case p_event_type
    when 'provider_stream_started' then 'provider_streaming'
    when 'provider_checkpointed' then 'checkpointed'
    when 'local_action_offered' then 'waiting_for_device'
    when 'cancellation_requested' then 'cancellation_requested'
    when 'run_completed' then 'completed'
    when 'run_failed' then 'failed'
    when 'provider_stream_interrupted' then 'failed_recoverable'
    when 'run_cancelled' then 'cancelled'
    when 'run_expired' then 'expired'
    else null
  end) then
    raise exception 'event type does not authorize target state' using errcode = '22023';
  end if;

  allowed := case current_run.state
    when 'queued' then p_target_state in (
      'provider_streaming', 'waiting_for_device', 'cancellation_requested', 'failed'
    )
    when 'provider_streaming' then p_target_state in (
      'checkpointed', 'completed', 'failed', 'failed_recoverable', 'cancellation_requested'
    )
    when 'checkpointed' then p_target_state in (
      'provider_streaming', 'waiting_for_device', 'completed', 'failed', 'cancellation_requested'
    )
    when 'waiting_for_device' then p_target_state in (
      'checkpointed', 'cancellation_requested', 'cancelled', 'expired', 'failed'
    )
    when 'cancellation_requested' then p_target_state in ('cancelled', 'failed')
    else false
  end;
  if not allowed then
    raise exception 'invalid run transition: % -> %', current_run.state, p_target_state
      using errcode = '22023';
  end if;

  if current_run.device_id is not null then
    update public.danotch_devices
    set next_event_sequence = next_event_sequence + 1
    where id = current_run.device_id and user_id = p_user_id
    returning next_event_sequence - 1 into next_device_sequence;
  end if;
  select coalesce(max(run_sequence), 0) + 1 into next_run_sequence
  from public.danotch_run_events where run_id = p_run_id;

  insert into public.danotch_run_events(
    id, run_id, user_id, device_id, run_sequence, device_sequence,
    event_type, from_state, to_state, payload, checkpoint
  ) values (
    p_transition_id, p_run_id, p_user_id, current_run.device_id,
    next_run_sequence, next_device_sequence, p_event_type,
    current_run.state, p_target_state, coalesce(p_payload, '{}'::jsonb), p_checkpoint
  );

  update public.danotch_runs set
    state = p_target_state,
    revision = revision + 1,
    checkpoint = case when p_checkpoint is null then checkpoint else p_checkpoint end,
    terminal_code = case
      when p_target_state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired')
        then coalesce(p_payload ->> 'code', p_target_state)
      else terminal_code
    end,
    terminal_at = case
      when p_target_state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired')
        then now()
      else terminal_at
    end,
    updated_at = now()
  where id = p_run_id and user_id = p_user_id
  returning * into current_run;

  if p_target_state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired') then
    insert into public.danotch_terminal_results(
      id, run_id, user_id, device_id, status, result
    ) values (
      p_transition_id, p_run_id, p_user_id, current_run.device_id,
      p_target_state, coalesce(p_payload, '{}'::jsonb)
    )
    on conflict (run_id) do nothing;
  end if;
  return current_run;
end
$$;
-- END 012_launch_readiness.sql
-- BEGIN 013_billing_launch_readiness.sql
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
-- END 013_billing_launch_readiness.sql
-- BEGIN 014_trial_cost_security.sql
-- Server-funded trial budgets and scheduler abuse ceilings.

create table public.danotch_trial_usage_daily (
  user_id uuid not null references public.danotch_user_profiles(id) on delete cascade,
  usage_day date not null,
  tokens_used bigint not null default 0 check (tokens_used >= 0),
  spend_micro_usd bigint not null default 0 check (spend_micro_usd >= 0),
  primary key (user_id, usage_day)
);

create table public.danotch_trial_usage_leases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.danotch_user_profiles(id) on delete cascade,
  reserved_tokens integer not null check (reserved_tokens > 0),
  reserved_spend_micro_usd integer not null check (reserved_spend_micro_usd > 0),
  expires_at timestamptz not null default now() + interval '5 minutes',
  created_at timestamptz not null default now()
);
create index danotch_trial_usage_leases_user_idx
  on public.danotch_trial_usage_leases(user_id, expires_at);

create function public.danotch_reserve_trial_usage(
  p_user_id uuid,
  p_reserved_tokens integer,
  p_reserved_spend_micro_usd integer,
  p_daily_token_limit integer,
  p_daily_spend_micro_usd integer,
  p_max_concurrency integer
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  daily public.danotch_trial_usage_daily;
  reserved_tokens bigint;
  reserved_spend bigint;
  active_count integer;
  lease_id uuid;
begin
  if p_reserved_tokens <= 0 or p_reserved_spend_micro_usd <= 0
    or p_daily_token_limit <= 0 or p_daily_token_limit > 10000000
    or p_daily_spend_micro_usd <= 0 or p_daily_spend_micro_usd > 100000000
    or p_max_concurrency <= 0 or p_max_concurrency > 10
  then
    raise exception 'invalid trial budget configuration' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text || ':trial-usage', 0));
  delete from public.danotch_trial_usage_leases
    where user_id = p_user_id and expires_at <= now();
  insert into public.danotch_trial_usage_daily(user_id, usage_day)
    values (p_user_id, current_date) on conflict do nothing;
  select * into daily from public.danotch_trial_usage_daily
    where user_id = p_user_id and usage_day = current_date for update;
  select coalesce(sum(reserved_tokens), 0),
         coalesce(sum(reserved_spend_micro_usd), 0),
         count(*)::integer
    into reserved_tokens, reserved_spend, active_count
    from public.danotch_trial_usage_leases
    where user_id = p_user_id and expires_at > now();

  if active_count >= p_max_concurrency
    or daily.tokens_used + reserved_tokens + p_reserved_tokens > p_daily_token_limit
    or daily.spend_micro_usd + reserved_spend + p_reserved_spend_micro_usd > p_daily_spend_micro_usd
  then
    return jsonb_build_object('allowed', false, 'retry_after_seconds', 60);
  end if;

  insert into public.danotch_trial_usage_leases(
    user_id, reserved_tokens, reserved_spend_micro_usd
  ) values (p_user_id, p_reserved_tokens, p_reserved_spend_micro_usd)
  returning id into lease_id;
  return jsonb_build_object('allowed', true, 'lease_id', lease_id);
end
$$;

create function public.danotch_settle_trial_usage(
  p_lease_id uuid,
  p_user_id uuid,
  p_actual_tokens integer,
  p_actual_spend_micro_usd integer
) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  removed integer;
begin
  if p_actual_tokens < 0 or p_actual_spend_micro_usd < 0 then
    raise exception 'invalid trial usage' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text || ':trial-usage', 0));
  delete from public.danotch_trial_usage_leases
    where id = p_lease_id and user_id = p_user_id;
  get diagnostics removed = row_count;
  if removed <> 1 then return false; end if;
  insert into public.danotch_trial_usage_daily(
    user_id, usage_day, tokens_used, spend_micro_usd
  ) values (p_user_id, current_date, p_actual_tokens, p_actual_spend_micro_usd)
  on conflict (user_id, usage_day) do update set
    tokens_used = public.danotch_trial_usage_daily.tokens_used + excluded.tokens_used,
    spend_micro_usd = public.danotch_trial_usage_daily.spend_micro_usd + excluded.spend_micro_usd;
  return true;
end
$$;

create function public.danotch_enforce_schedule_caps() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.interval_ms is not null and new.interval_ms < 900000 then
    raise exception 'scheduled interval must be at least 15 minutes' using errcode = '23514';
  end if;
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtextextended(new.user_id::text || ':schedules', 0));
    if (select count(*) from public.danotch_scheduled_tasks where user_id = new.user_id) >= 5 then
      raise exception 'scheduled task limit reached' using errcode = '23514';
    end if;
  end if;
  return new;
end
$$;

create trigger danotch_scheduled_tasks_caps
before insert or update of interval_ms on public.danotch_scheduled_tasks
for each row execute function public.danotch_enforce_schedule_caps();

alter table public.danotch_trial_usage_daily enable row level security;
alter table public.danotch_trial_usage_daily force row level security;
alter table public.danotch_trial_usage_leases enable row level security;
alter table public.danotch_trial_usage_leases force row level security;
revoke all on public.danotch_trial_usage_daily,
  public.danotch_trial_usage_leases from public, anon, authenticated;
revoke all on function public.danotch_reserve_trial_usage(uuid, integer, integer, integer, integer, integer),
  public.danotch_settle_trial_usage(uuid, uuid, integer, integer),
  public.danotch_enforce_schedule_caps() from public, anon, authenticated;
grant execute on function public.danotch_reserve_trial_usage(uuid, integer, integer, integer, integer, integer),
  public.danotch_settle_trial_usage(uuid, uuid, integer, integer)
  to danotch_runner, danotch_scheduler;
-- END 014_trial_cost_security.sql
-- BEGIN 015_provisioning_result_privileges.sql
-- Launch-readiness privilege corrections. Keep generic run transitions scoped
-- to the runner while allowing the validated action-result reducer to perform
-- its terminal transition atomically.

alter function public.danotch_record_action_result(
  uuid, uuid, uuid, uuid, uuid, text, jsonb, bigint
) security definer;
alter function public.danotch_record_action_result(
  uuid, uuid, uuid, uuid, uuid, text, jsonb, bigint
) set search_path = '';

-- Defense in depth: fencing may submit a fully validated action result, but it
-- must never gain arbitrary access to the generic run state transition API.
revoke execute on function public.danotch_transition_run(
  uuid, uuid, uuid, bigint, text, text, jsonb, jsonb
) from danotch_fencing;

-- The provisioning function intentionally has an empty search_path. pgcrypto
-- installs digest in public in this schema, so qualify it explicitly.
create or replace function public.danotch_provision_verified_user(
  p_user_id uuid,
  p_email text,
  p_full_name text,
  p_trial_subject_hash text,
  p_apps text[]
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_verified_at timestamptz;
  quota_result jsonb;
  provision public.danotch_verified_provisioning;
  profile_exists boolean;
begin
  select email_confirmed_at into v_verified_at from auth.users where id = p_user_id for update;
  if v_verified_at is null then
    raise exception 'verified email required' using errcode = '42501';
  end if;
  select exists(select 1 from public.danotch_user_profiles where id = p_user_id)
    into profile_exists;
  if not profile_exists and not exists (
    select 1 from public.danotch_signup_enrollments
    where email_hash = encode(
        public.digest(convert_to(lower(p_email), 'utf8'), 'sha256'), 'hex'
      )
      and (user_id is null or user_id = p_user_id)
      and status = 'pending'
      and requested_at <= v_verified_at
  ) then
    raise exception 'verified signup enrollment required' using errcode = '42501';
  end if;
  update public.danotch_signup_enrollments set user_id = p_user_id
    where email_hash = encode(
      public.digest(convert_to(lower(p_email), 'utf8'), 'sha256'), 'hex'
    ) and (user_id is null or user_id = p_user_id);
  insert into public.danotch_verified_provisioning(user_id, attempts)
    values (p_user_id, 1)
    on conflict (user_id) do update set attempts =
      public.danotch_verified_provisioning.attempts + 1, updated_at = now();
  insert into public.danotch_user_profiles(
    id, email, full_name, trial_started_at, trial_ends_at, billing_status
  ) values (
    p_user_id, lower(p_email), p_full_name, null, null, 'trialing'
  ) on conflict (id) do update set
    email = excluded.email,
    full_name = case when public.danotch_user_profiles.full_name = ''
      then excluded.full_name else public.danotch_user_profiles.full_name end;
  update public.danotch_verified_provisioning set profile_ready = true where user_id = p_user_id;
  insert into public.danotch_connected_apps(user_id, app_type, active)
    select p_user_id, app_type, false from unnest(p_apps) app_type
    on conflict (user_id, app_type) do nothing;
  update public.danotch_verified_provisioning set apps_ready = true where user_id = p_user_id;
  select * into provision from public.danotch_verified_provisioning where user_id = p_user_id;
  if not provision.trial_ready then
    quota_result := public.danotch_consume_capability_quota(
      'trial', p_trial_subject_hash, 1, p_user_id::text
    );
    if coalesce((quota_result ->> 'allowed')::boolean, false) is not true then
      raise exception 'trial quota exceeded' using errcode = 'P0001';
    end if;
    update public.danotch_user_profiles set
      trial_started_at = coalesce(trial_started_at, now()),
      trial_ends_at = coalesce(trial_ends_at, now() + interval '14 days'),
      billing_status = case
        when lifetime_purchased_at is not null then 'paid'
        else 'trialing'
      end
    where id = p_user_id;
    update public.danotch_verified_provisioning set trial_ready = true where user_id = p_user_id;
  end if;
  update public.danotch_verified_provisioning
    set completed_at = now(), last_error = null, updated_at = now()
    where user_id = p_user_id and profile_ready and apps_ready and trial_ready;
  update public.danotch_signup_enrollments
    set status = 'verified', verified_at = v_verified_at
    where user_id = p_user_id and status = 'pending';
  return (select to_jsonb(row_value) from (
    select profile_ready, apps_ready, trial_ready, completed_at
    from public.danotch_verified_provisioning where user_id = p_user_id
  ) row_value);
end
$$;

-- Device-local execution completes while the run is waiting for its device.
-- Permit that validated terminal path without changing who may execute the
-- generic transition reducer.
create or replace function public.danotch_transition_run(
  p_run_id uuid,
  p_user_id uuid,
  p_transition_id uuid,
  p_expected_revision bigint,
  p_target_state text,
  p_event_type text,
  p_payload jsonb default '{}'::jsonb,
  p_checkpoint jsonb default null
) returns public.danotch_runs
language plpgsql
security invoker
set search_path = ''
as $$
declare
  current_run public.danotch_runs;
  next_device_sequence bigint;
  next_run_sequence bigint;
  allowed boolean := false;
begin
  select * into current_run from public.danotch_runs
  where id = p_run_id and user_id = p_user_id for update;
  if not found then
    raise exception 'run not found for owner' using errcode = '42501';
  end if;

  if exists (select 1 from public.danotch_run_events where id = p_transition_id) then
    if not exists (
      select 1 from public.danotch_run_events
      where id = p_transition_id and run_id = p_run_id and user_id = p_user_id
        and to_state = p_target_state and event_type = p_event_type
        and payload = coalesce(p_payload, '{}'::jsonb)
        and checkpoint is not distinct from p_checkpoint
    ) then
      raise exception 'transition id reused with different content' using errcode = '23505';
    end if;
    return current_run;
  end if;
  if current_run.revision <> p_expected_revision then
    raise exception 'out-of-order transition: expected %, actual %',
      p_expected_revision, current_run.revision using errcode = '40001';
  end if;
  if current_run.state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired') then
    raise exception 'late transition for terminal run' using errcode = '55000';
  end if;
  if p_target_state is distinct from (case p_event_type
    when 'provider_stream_started' then 'provider_streaming'
    when 'provider_checkpointed' then 'checkpointed'
    when 'local_action_offered' then 'waiting_for_device'
    when 'cancellation_requested' then 'cancellation_requested'
    when 'run_completed' then 'completed'
    when 'run_failed' then 'failed'
    when 'provider_stream_interrupted' then 'failed_recoverable'
    when 'run_cancelled' then 'cancelled'
    when 'run_expired' then 'expired'
    else null
  end) then
    raise exception 'event type does not authorize target state' using errcode = '22023';
  end if;

  allowed := case current_run.state
    when 'queued' then p_target_state in (
      'provider_streaming', 'waiting_for_device', 'cancellation_requested', 'failed'
    )
    when 'provider_streaming' then p_target_state in (
      'checkpointed', 'completed', 'failed', 'failed_recoverable', 'cancellation_requested'
    )
    when 'checkpointed' then p_target_state in (
      'provider_streaming', 'waiting_for_device', 'completed', 'failed', 'cancellation_requested'
    )
    when 'waiting_for_device' then p_target_state in (
      'checkpointed', 'completed', 'cancellation_requested', 'cancelled', 'expired', 'failed'
    )
    when 'cancellation_requested' then p_target_state in ('cancelled', 'failed')
    else false
  end;
  if not allowed then
    raise exception 'invalid run transition: % -> %', current_run.state, p_target_state
      using errcode = '22023';
  end if;

  if current_run.device_id is not null then
    update public.danotch_devices
    set next_event_sequence = next_event_sequence + 1
    where id = current_run.device_id and user_id = p_user_id
    returning next_event_sequence - 1 into next_device_sequence;
  end if;
  select coalesce(max(run_sequence), 0) + 1 into next_run_sequence
  from public.danotch_run_events where run_id = p_run_id;

  insert into public.danotch_run_events(
    id, run_id, user_id, device_id, run_sequence, device_sequence,
    event_type, from_state, to_state, payload, checkpoint
  ) values (
    p_transition_id, p_run_id, p_user_id, current_run.device_id,
    next_run_sequence, next_device_sequence, p_event_type,
    current_run.state, p_target_state, coalesce(p_payload, '{}'::jsonb), p_checkpoint
  );

  update public.danotch_runs set
    state = p_target_state,
    revision = revision + 1,
    checkpoint = case when p_checkpoint is null then checkpoint else p_checkpoint end,
    terminal_code = case
      when p_target_state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired')
        then coalesce(p_payload ->> 'code', p_target_state)
      else terminal_code
    end,
    terminal_at = case
      when p_target_state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired')
        then now()
      else terminal_at
    end,
    updated_at = now()
  where id = p_run_id and user_id = p_user_id
  returning * into current_run;

  if p_target_state in ('completed', 'failed', 'failed_recoverable', 'cancelled', 'expired') then
    insert into public.danotch_terminal_results(
      id, run_id, user_id, device_id, status, result
    ) values (
      p_transition_id, p_run_id, p_user_id, current_run.device_id,
      p_target_state, coalesce(p_payload, '{}'::jsonb)
    )
    on conflict (run_id) do nothing;
  end if;
  return current_run;
end
$$;
-- END 015_provisioning_result_privileges.sql
