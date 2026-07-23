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
