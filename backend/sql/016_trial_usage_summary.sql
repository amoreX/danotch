-- Authenticated, account-scoped trial usage reporting for the client meter.
-- Daily rows are retained for the lifetime of the account, so the same ledger
-- provides both today's usage and durable all-time totals.

alter table public.danotch_trial_usage_daily
  add column requests_used bigint not null default 0 check (requests_used >= 0),
  add column limit_reached_at timestamptz;

create or replace function public.danotch_reserve_trial_usage(
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
  v_reserved_tokens bigint;
  v_reserved_spend bigint;
  active_count integer;
  lease_id uuid;
  reset_at timestamptz :=
    (date_trunc('day', now() at time zone 'UTC') + interval '1 day') at time zone 'UTC';
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
    values (p_user_id, (now() at time zone 'UTC')::date) on conflict do nothing;
  select * into daily from public.danotch_trial_usage_daily
    where user_id = p_user_id
      and usage_day = (now() at time zone 'UTC')::date
    for update;
  select coalesce(sum(reserved_tokens), 0),
         coalesce(sum(reserved_spend_micro_usd), 0),
         count(*)::integer
    into v_reserved_tokens, v_reserved_spend, active_count
    from public.danotch_trial_usage_leases
    where user_id = p_user_id and expires_at > now();

  if active_count >= p_max_concurrency then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'concurrency',
      'retry_after_seconds', 60
    );
  end if;

  if daily.spend_micro_usd + v_reserved_spend + p_reserved_spend_micro_usd
      > p_daily_spend_micro_usd then
    update public.danotch_trial_usage_daily
      set limit_reached_at = coalesce(limit_reached_at, now())
      where user_id = p_user_id
        and usage_day = (now() at time zone 'UTC')::date;
    return jsonb_build_object(
      'allowed', false,
      'reason', 'daily_spend',
      'retry_after_seconds', greatest(1, extract(epoch from reset_at - now())::integer),
      'reset_at', reset_at
    );
  end if;

  if daily.tokens_used + v_reserved_tokens + p_reserved_tokens > p_daily_token_limit then
    update public.danotch_trial_usage_daily
      set limit_reached_at = coalesce(limit_reached_at, now())
      where user_id = p_user_id
        and usage_day = (now() at time zone 'UTC')::date;
    return jsonb_build_object(
      'allowed', false,
      'reason', 'daily_tokens',
      'retry_after_seconds', greatest(1, extract(epoch from reset_at - now())::integer),
      'reset_at', reset_at
    );
  end if;

  insert into public.danotch_trial_usage_leases(
    user_id, reserved_tokens, reserved_spend_micro_usd
  ) values (p_user_id, p_reserved_tokens, p_reserved_spend_micro_usd)
  returning id into lease_id;
  return jsonb_build_object('allowed', true, 'lease_id', lease_id);
end
$$;

create or replace function public.danotch_settle_trial_usage(
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
    user_id, usage_day, requests_used, tokens_used, spend_micro_usd
  ) values (
    p_user_id, (now() at time zone 'UTC')::date, 1,
    p_actual_tokens, p_actual_spend_micro_usd
  )
  on conflict (user_id, usage_day) do update set
    requests_used = public.danotch_trial_usage_daily.requests_used + 1,
    tokens_used = public.danotch_trial_usage_daily.tokens_used + excluded.tokens_used,
    spend_micro_usd = public.danotch_trial_usage_daily.spend_micro_usd + excluded.spend_micro_usd;
  return true;
end
$$;

create or replace function public.danotch_finish_schedule_attempt(
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
  elsif p_outcome = 'trial_limit' then
    update public.danotch_scheduled_tasks set run_state = 'ready',
      next_run_at = p_next_run_at, retry_at = null, lease_owner = null,
      lease_token = null, lease_expires_at = null, last_run_at = now(),
      last_result = p_last_result, attempt_count = 0
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

create function public.danotch_get_trial_usage_summary()
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_daily_requests bigint;
  v_daily_tokens bigint;
  v_daily_spend bigint;
  v_daily_limit_reached boolean;
  v_total_requests bigint;
  v_total_tokens bigint;
  v_total_spend bigint;
begin
  if v_user_id is null then
    raise exception 'authenticated user required' using errcode = '42501';
  end if;

  select
    coalesce(sum(requests_used) filter (
      where usage_day = (now() at time zone 'UTC')::date
    ), 0),
    coalesce(sum(tokens_used) filter (
      where usage_day = (now() at time zone 'UTC')::date
    ), 0),
    coalesce(sum(spend_micro_usd) filter (
      where usage_day = (now() at time zone 'UTC')::date
    ), 0),
    coalesce(bool_or(limit_reached_at is not null) filter (
      where usage_day = (now() at time zone 'UTC')::date
    ), false),
    coalesce(sum(requests_used), 0),
    coalesce(sum(tokens_used), 0),
    coalesce(sum(spend_micro_usd), 0)
  into v_daily_requests, v_daily_tokens, v_daily_spend, v_daily_limit_reached,
       v_total_requests, v_total_tokens, v_total_spend
  from public.danotch_trial_usage_daily
  where user_id = v_user_id;

  return jsonb_build_object(
    'usage_day', (now() at time zone 'UTC')::date,
    'daily_requests', v_daily_requests,
    'daily_tokens', v_daily_tokens,
    'daily_spend_micro_usd', v_daily_spend,
    'daily_limit_reached', v_daily_limit_reached,
    'resets_at',
      (date_trunc('day', now() at time zone 'UTC') + interval '1 day') at time zone 'UTC',
    'total_requests', v_total_requests,
    'total_tokens', v_total_tokens,
    'total_spend_micro_usd', v_total_spend
  );
end
$$;

revoke all on function public.danotch_get_trial_usage_summary()
  from public, anon, authenticated;
grant execute on function public.danotch_get_trial_usage_summary()
  to authenticated;
