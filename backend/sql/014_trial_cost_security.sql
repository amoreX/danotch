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
