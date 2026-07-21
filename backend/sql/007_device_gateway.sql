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
