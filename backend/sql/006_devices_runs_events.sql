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
