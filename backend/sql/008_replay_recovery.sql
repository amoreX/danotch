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
