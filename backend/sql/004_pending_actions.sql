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
