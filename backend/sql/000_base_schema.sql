-- Authoritative application bootstrap. Supabase projects already provide
-- auth.users; the compatibility table only makes clean PostgreSQL CI databases
-- capable of exercising the same foreign keys.
create extension if not exists pgcrypto;
create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key
);

create table if not exists public.danotch_user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null default '',
  avatar_url text,
  plan text not null default 'free',
  created_at timestamptz not null default now()
);

create table if not exists public.danotch_connected_apps (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  app_type text not null,
  active boolean not null default false,
  composio_conn_id text,
  connected_at timestamptz,
  disconnected_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, app_type)
);

create table if not exists public.danotch_provider_configs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null,
  api_key_encrypted text not null,
  model_id text not null,
  is_active boolean not null default false,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, provider)
);

create table if not exists public.danotch_threads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id)
);

create table if not exists public.danotch_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null,
  content text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint danotch_messages_owned_thread_fk
    foreign key (thread_id, user_id)
    references public.danotch_threads(id, user_id)
    on delete cascade
);

create table if not exists public.danotch_scheduled_tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  prompt text not null,
  task_type text not null default 'scheduled',
  cron text,
  interval_ms bigint,
  target_app text,
  notify_user boolean not null default false,
  enabled boolean not null default true,
  next_run_at timestamptz,
  last_run_at timestamptz,
  run_count integer not null default 0,
  last_result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.danotch_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source text not null,
  source_id uuid,
  title text not null,
  body text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

-- Bring the historical hand-created schema up to the bootstrap contract before
-- later migrations run. These statements are intentionally additive.
alter table public.danotch_user_profiles
  add column if not exists avatar_url text,
  add column if not exists plan text not null default 'free';
alter table public.danotch_scheduled_tasks
  add column if not exists updated_at timestamptz not null default now();
create unique index if not exists danotch_threads_id_user_uidx
  on public.danotch_threads(id, user_id);
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.danotch_messages'::regclass
      and conname = 'danotch_messages_owned_thread_fk'
  ) then
    alter table public.danotch_messages
      add constraint danotch_messages_owned_thread_fk
      foreign key (thread_id, user_id)
      references public.danotch_threads(id, user_id)
      on delete cascade;
  end if;
end
$$;

create index if not exists idx_danotch_connected_apps_user
  on public.danotch_connected_apps(user_id);
create index if not exists idx_danotch_provider_configs_user
  on public.danotch_provider_configs(user_id);
create index if not exists idx_danotch_threads_user
  on public.danotch_threads(user_id);
create index if not exists idx_danotch_messages_thread
  on public.danotch_messages(thread_id);
create index if not exists idx_danotch_messages_user
  on public.danotch_messages(user_id);
create index if not exists idx_danotch_scheduled_tasks_user
  on public.danotch_scheduled_tasks(user_id);
create index if not exists idx_danotch_scheduled_tasks_next_run
  on public.danotch_scheduled_tasks(enabled, next_run_at);
create index if not exists idx_danotch_notifications_user
  on public.danotch_notifications(user_id, created_at desc);
create index if not exists idx_danotch_notifications_unread
  on public.danotch_notifications(user_id, read) where read = false;
