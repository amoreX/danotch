-- Tenant boundary and operation-role classification.
--
-- User-readable/user-writable:
--   profiles (read; name/avatar write), provider configs (metadata read; config
--   write), threads/messages (legacy owner CRUD), scheduled task definition
--   fields (owner CRUD), notifications (read/read-state/delete).
-- User-readable/server-authoritative:
--   connected app state, connection requests, pending actions.
-- Server-authoritative:
--   billing/trial/payment fields, checkout/payment ledgers, OAuth attempt state,
--   schedule execution fields, notification creation, action/connection state.

do $$
declare
  role_name text;
begin
  foreach role_name in array array[
    'anon', 'authenticated', 'service_role',
    'danotch_bootstrap', 'danotch_webhook', 'danotch_scheduler',
    'danotch_fencing', 'danotch_reconciler', 'danotch_provider'
  ]
  loop
    if not exists (select 1 from pg_roles where rolname = role_name) then
      execute format('create role %I nologin', role_name);
    end if;
  end loop;
end
$$;

alter role danotch_bootstrap bypassrls;
alter role danotch_webhook bypassrls;
alter role danotch_scheduler bypassrls;
alter role danotch_fencing bypassrls;
alter role danotch_reconciler bypassrls;
alter role danotch_provider bypassrls;

do $$
declare
  role_name text;
begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    foreach role_name in array array[
      'danotch_bootstrap', 'danotch_webhook', 'danotch_scheduler',
      'danotch_fencing', 'danotch_reconciler', 'danotch_provider'
    ]
    loop
      execute format('grant %I to authenticator', role_name);
    end loop;
  end if;
end
$$;

-- Plain PostgreSQL integration tests do not have Supabase's auth.uid().
do $outer$
begin
  if to_regprocedure('auth.uid()') is null then
    execute $fn$
      create function auth.uid() returns uuid
      language sql stable
      set search_path = ''
      as 'select nullif(current_setting(''request.jwt.claim.sub'', true), '''')::uuid'
    $fn$;
  end if;
end
$outer$;

alter table public.danotch_user_profiles
  add constraint danotch_user_profiles_billing_status_check
    check (billing_status in ('trialing', 'paid', 'expired')),
  add constraint danotch_user_profiles_plan_check
    check (plan in ('free', 'paid'));
alter table public.danotch_connected_apps
  add constraint danotch_connected_apps_type_check
    check (app_type in ('gmail', 'googlecalendar', 'googledocs', 'github'));
alter table public.danotch_provider_configs
  add constraint danotch_provider_configs_provider_check
    check (provider in ('anthropic', 'openai', 'openrouter'));
alter table public.danotch_messages
  add constraint danotch_messages_role_check
    check (role in ('user', 'assistant', 'tool', 'connection_request'));
alter table public.danotch_scheduled_tasks
  add constraint danotch_scheduled_tasks_type_check
    check (task_type in ('scheduled', 'poll')),
  add constraint danotch_scheduled_tasks_run_count_check
    check (run_count >= 0),
  add constraint danotch_scheduled_tasks_schedule_check
    check (
      (task_type = 'scheduled' and cron is not null and interval_ms is null)
      or
      (task_type = 'poll' and interval_ms >= 60000 and cron is null)
    );
alter table public.danotch_checkout_records
  add constraint danotch_checkout_records_status_check
    check (status in ('pending', 'consumed', 'expired')),
  add constraint danotch_checkout_records_amount_check
    check (expected_amount >= 0 and expected_quantity > 0);
alter table public.danotch_payment_events
  add constraint danotch_payment_events_outcome_check
    check (outcome in ('granted', 'duplicate', 'unknown_profile', 'rejected'));
alter table public.danotch_connection_requests
  add constraint danotch_connection_requests_status_check
    check (status in ('pending', 'approved', 'denied', 'expired'));
alter table public.danotch_connection_attempts
  add constraint danotch_connection_attempts_status_check
    check (status in ('pending', 'active', 'expired', 'failed'));
alter table public.danotch_pending_actions
  add constraint danotch_pending_actions_status_check
    check (status in ('pending', 'executing', 'completed', 'rejected', 'expired', 'failed'));

create unique index if not exists danotch_provider_configs_one_active_idx
  on public.danotch_provider_configs(user_id) where is_active;
create index if not exists danotch_payment_events_claimed_user_idx
  on public.danotch_payment_events(claimed_user_id);

-- Every owner predicate has a supporting index, including tables introduced by
-- delta migrations.
create index if not exists danotch_checkout_records_owner_idx
  on public.danotch_checkout_records(user_id);
create index if not exists danotch_payment_events_owner_idx
  on public.danotch_payment_events(profile_id);
create index if not exists danotch_connection_requests_owner_idx
  on public.danotch_connection_requests(user_id);
create index if not exists danotch_connection_attempts_owner_idx
  on public.danotch_connection_attempts(user_id);
create index if not exists danotch_pending_actions_owner_idx
  on public.danotch_pending_actions(user_id);

create or replace function public.danotch_reject_owner_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (to_jsonb(old) ->> tg_argv[0]) is distinct from (to_jsonb(new) ->> tg_argv[0]) then
    raise exception 'immutable owner column %', tg_argv[0] using errcode = '42501';
  end if;
  return new;
end
$$;

do $$
declare
  item record;
begin
  for item in
    select * from (values
      ('danotch_user_profiles', 'id'),
      ('danotch_connected_apps', 'user_id'),
      ('danotch_provider_configs', 'user_id'),
      ('danotch_threads', 'user_id'),
      ('danotch_messages', 'user_id'),
      ('danotch_scheduled_tasks', 'user_id'),
      ('danotch_notifications', 'user_id'),
      ('danotch_checkout_records', 'user_id'),
      ('danotch_connection_requests', 'user_id'),
      ('danotch_connection_attempts', 'user_id'),
      ('danotch_pending_actions', 'user_id')
    ) as owners(table_name, column_name)
  loop
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.danotch_reject_owner_change(%L)',
      item.table_name || '_immutable_owner', item.table_name, item.column_name
    );
  end loop;
end
$$;

-- RLS is authoritative even for table owners used by local integration tests.
alter table public.danotch_user_profiles enable row level security;
alter table public.danotch_user_profiles force row level security;
alter table public.danotch_connected_apps enable row level security;
alter table public.danotch_connected_apps force row level security;
alter table public.danotch_provider_configs enable row level security;
alter table public.danotch_provider_configs force row level security;
alter table public.danotch_threads enable row level security;
alter table public.danotch_threads force row level security;
alter table public.danotch_messages enable row level security;
alter table public.danotch_messages force row level security;
alter table public.danotch_scheduled_tasks enable row level security;
alter table public.danotch_scheduled_tasks force row level security;
alter table public.danotch_notifications enable row level security;
alter table public.danotch_notifications force row level security;
alter table public.danotch_checkout_records enable row level security;
alter table public.danotch_checkout_records force row level security;
alter table public.danotch_payment_events enable row level security;
alter table public.danotch_payment_events force row level security;
alter table public.danotch_connection_requests enable row level security;
alter table public.danotch_connection_requests force row level security;
alter table public.danotch_connection_attempts enable row level security;
alter table public.danotch_connection_attempts force row level security;
alter table public.danotch_pending_actions enable row level security;
alter table public.danotch_pending_actions force row level security;

create policy profiles_owner_select on public.danotch_user_profiles
  for select to authenticated using (id = auth.uid());
create policy profiles_owner_update on public.danotch_user_profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy connected_apps_owner_select on public.danotch_connected_apps
  for select to authenticated using (user_id = auth.uid());

create policy provider_configs_owner_select on public.danotch_provider_configs
  for select to authenticated using (user_id = auth.uid());
create policy provider_configs_owner_insert on public.danotch_provider_configs
  for insert to authenticated with check (user_id = auth.uid());
create policy provider_configs_owner_update on public.danotch_provider_configs
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy provider_configs_owner_delete on public.danotch_provider_configs
  for delete to authenticated using (user_id = auth.uid());

create policy threads_owner_select on public.danotch_threads
  for select to authenticated using (user_id = auth.uid());
create policy threads_owner_insert on public.danotch_threads
  for insert to authenticated with check (user_id = auth.uid());
create policy threads_owner_update on public.danotch_threads
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy threads_owner_delete on public.danotch_threads
  for delete to authenticated using (user_id = auth.uid());

create policy messages_owner_select on public.danotch_messages
  for select to authenticated using (user_id = auth.uid());
create policy messages_owner_insert on public.danotch_messages
  for insert to authenticated with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.danotch_threads t
      where t.id = thread_id and t.user_id = auth.uid()
    )
  );
create policy messages_owner_update on public.danotch_messages
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy messages_owner_delete on public.danotch_messages
  for delete to authenticated using (user_id = auth.uid());

create policy scheduled_tasks_owner_select on public.danotch_scheduled_tasks
  for select to authenticated using (user_id = auth.uid());
create policy scheduled_tasks_owner_insert on public.danotch_scheduled_tasks
  for insert to authenticated with check (user_id = auth.uid());
create policy scheduled_tasks_owner_update on public.danotch_scheduled_tasks
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy scheduled_tasks_owner_delete on public.danotch_scheduled_tasks
  for delete to authenticated using (user_id = auth.uid());

create policy notifications_owner_select on public.danotch_notifications
  for select to authenticated using (user_id = auth.uid());
create policy notifications_owner_update on public.danotch_notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notifications_owner_delete on public.danotch_notifications
  for delete to authenticated using (user_id = auth.uid());

create policy checkout_records_owner_select on public.danotch_checkout_records
  for select to authenticated using (user_id = auth.uid());
create policy connection_requests_owner_select on public.danotch_connection_requests
  for select to authenticated using (user_id = auth.uid());
create policy pending_actions_owner_select on public.danotch_pending_actions
  for select to authenticated using (user_id = auth.uid());

revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
grant usage on schema public to authenticated;
grant usage on schema public to danotch_bootstrap, danotch_webhook,
  danotch_scheduler, danotch_fencing, danotch_reconciler, danotch_provider;

grant select (id, email, full_name, avatar_url, plan, created_at,
  trial_started_at, trial_ends_at, lifetime_purchased_at, billing_status)
  on public.danotch_user_profiles to authenticated;
grant update (full_name, avatar_url) on public.danotch_user_profiles to authenticated;

grant select (id, user_id, app_type, active, connected_at, disconnected_at, created_at)
  on public.danotch_connected_apps to authenticated;

grant select (id, user_id, provider, model_id, is_active, verified_at, created_at, updated_at)
  on public.danotch_provider_configs to authenticated;
grant insert (user_id, provider, api_key_encrypted, model_id, is_active, updated_at)
  on public.danotch_provider_configs to authenticated;
grant update (provider, api_key_encrypted, model_id, is_active, updated_at)
  on public.danotch_provider_configs to authenticated;
grant delete on public.danotch_provider_configs to authenticated;

grant select, delete on public.danotch_threads to authenticated;
grant insert (id, user_id, title) on public.danotch_threads to authenticated;
grant update (title, updated_at) on public.danotch_threads to authenticated;
grant select, delete on public.danotch_messages to authenticated;
grant insert (thread_id, user_id, role, content, metadata) on public.danotch_messages to authenticated;
grant update (content, metadata) on public.danotch_messages to authenticated;

grant select, delete on public.danotch_scheduled_tasks to authenticated;
grant insert (user_id, name, prompt, task_type, cron, interval_ms, target_app, notify_user, enabled)
  on public.danotch_scheduled_tasks to authenticated;
grant update (name, prompt, cron, interval_ms, target_app, notify_user, enabled, updated_at)
  on public.danotch_scheduled_tasks to authenticated;

grant select, delete on public.danotch_notifications to authenticated;
grant update (read) on public.danotch_notifications to authenticated;
grant select on public.danotch_checkout_records to authenticated;
grant select on public.danotch_connection_requests to authenticated;
grant select on public.danotch_pending_actions to authenticated;

-- Operation-specific roles. Public request code receives none of these clients.
grant select, insert, update on public.danotch_user_profiles to danotch_bootstrap;
grant select, insert, update on public.danotch_connected_apps to danotch_bootstrap;
grant select, insert, update on public.danotch_checkout_records to danotch_webhook;
grant select, insert on public.danotch_payment_events to danotch_webhook;
grant select, update on public.danotch_user_profiles to danotch_webhook;
grant select, insert, update on public.danotch_scheduled_tasks to danotch_scheduler;
grant select, insert on public.danotch_notifications to danotch_scheduler;
grant select on public.danotch_provider_configs to danotch_scheduler;
grant select on public.danotch_user_profiles to danotch_scheduler;
grant select, insert, update on public.danotch_connection_requests to danotch_fencing;
grant select, insert, update on public.danotch_connection_attempts to danotch_reconciler;
grant select, insert, update on public.danotch_connected_apps to danotch_reconciler;
grant select, insert, update on public.danotch_pending_actions to danotch_reconciler;
grant select on public.danotch_provider_configs to danotch_reconciler;
grant select on public.danotch_provider_configs to danotch_provider;
grant update (verified_at) on public.danotch_provider_configs to danotch_provider;

revoke all on function public.danotch_reject_owner_change() from public;
grant execute on function public.danotch_record_payment(text, text, text, text, text, integer, text, text)
  to danotch_webhook;
grant execute on function public.danotch_resolve_connection_request(uuid, uuid, text)
  to danotch_fencing;
grant execute on function public.danotch_claim_pending_action(uuid, uuid)
  to danotch_reconciler;
