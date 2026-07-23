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
