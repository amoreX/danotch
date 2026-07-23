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
