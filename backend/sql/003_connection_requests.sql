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
