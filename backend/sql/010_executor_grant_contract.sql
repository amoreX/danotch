-- U5 executor contract expansion. Workspace bookmark identifiers are opaque
-- local lookup keys; bookmark bytes never enter hosted storage.

alter table public.danotch_local_action_requests
  add column workspace_bookmark_id text,
  add column result_disclosure_policy jsonb;

update public.danotch_local_action_requests
set
  workspace_bookmark_id = 'workspace-' || id::text,
  result_disclosure_policy = jsonb_build_object(
    'sensitive_output',
    coalesce((capabilities ->> 'sensitive_output_disclosure')::boolean, false),
    'upload',
    coalesce((capabilities ->> 'result_upload')::boolean, false)
  );

alter table public.danotch_local_action_requests
  alter column workspace_bookmark_id set not null,
  alter column result_disclosure_policy set not null,
  add constraint danotch_local_action_workspace_bookmark_id_check
    check (workspace_bookmark_id ~ '^[A-Za-z0-9._-]{1,128}$'),
  add constraint danotch_local_action_result_disclosure_check
    check (
      jsonb_typeof(result_disclosure_policy) = 'object'
      and result_disclosure_policy ?& array['sensitive_output', 'upload']
      and result_disclosure_policy - array['sensitive_output', 'upload'] = '{}'::jsonb
      and jsonb_typeof(result_disclosure_policy -> 'sensitive_output') = 'boolean'
      and jsonb_typeof(result_disclosure_policy -> 'upload') = 'boolean'
    );

alter table public.danotch_execution_grants
  add column registry_version text,
  add column action_type text,
  add column workspace_bookmark_id text,
  add column result_disclosure_policy jsonb,
  add column device_key_fingerprint text;

update public.danotch_execution_grants grant_row
set
  registry_version = action.registry_version,
  action_type = action.action_type,
  workspace_bookmark_id = action.workspace_bookmark_id,
  result_disclosure_policy = action.result_disclosure_policy,
  device_key_fingerprint = device.key_fingerprint
from public.danotch_local_action_requests action,
     public.danotch_devices device
where action.id = grant_row.action_id
  and device.id = grant_row.device_id
  and device.user_id = grant_row.user_id;

alter table public.danotch_execution_grants
  alter column registry_version set not null,
  alter column action_type set not null,
  alter column workspace_bookmark_id set not null,
  alter column result_disclosure_policy set not null,
  alter column device_key_fingerprint set not null,
  add constraint danotch_execution_grant_workspace_bookmark_id_check
    check (workspace_bookmark_id ~ '^[A-Za-z0-9._-]{1,128}$'),
  add constraint danotch_execution_grant_device_key_fingerprint_check
    check (device_key_fingerprint ~ '^[0-9a-f]{64}$');

create function public.danotch_bind_execution_grant_contract()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  action public.danotch_local_action_requests;
  device public.danotch_devices;
begin
  select * into action
  from public.danotch_local_action_requests
  where id = new.action_id and user_id = new.user_id and device_id = new.device_id;
  select * into device
  from public.danotch_devices
  where id = new.device_id and user_id = new.user_id;
  if action.id is null or device.id is null then
    raise exception 'execution grant action/device binding is invalid'
      using errcode = '42501';
  end if;
  new.registry_version := action.registry_version;
  new.action_type := action.action_type;
  new.workspace_bookmark_id := action.workspace_bookmark_id;
  new.result_disclosure_policy := action.result_disclosure_policy;
  new.device_key_fingerprint := device.key_fingerprint;
  return new;
end
$$;

create trigger danotch_execution_grant_bind_contract
before insert or update of action_id, user_id, device_id
on public.danotch_execution_grants
for each row execute function public.danotch_bind_execution_grant_contract();

create function public.danotch_get_execution_grant_contract(
  p_grant_id uuid,
  p_user_id uuid,
  p_device_id uuid,
  p_fence bigint
) returns jsonb
language sql
security definer
set search_path = ''
stable
as $$
  select jsonb_build_object(
    'registry_version', grant_row.registry_version,
    'action_type', grant_row.action_type,
    'workspace_bookmark_id', grant_row.workspace_bookmark_id,
    'result_disclosure_policy', grant_row.result_disclosure_policy,
    'device_key_fingerprint', grant_row.device_key_fingerprint
  )
  from public.danotch_execution_grants grant_row
  join public.danotch_devices device
    on device.id = grant_row.device_id and device.user_id = grant_row.user_id
  where grant_row.id = p_grant_id
    and grant_row.user_id = p_user_id
    and grant_row.device_id = p_device_id
    and grant_row.fence = p_fence
    and device.current_fence = p_fence
    and device.status = 'active'
    and grant_row.consumed_at is null
    and grant_row.revoked_at is null
    and grant_row.expires_at > now()
$$;

revoke all on function public.danotch_bind_execution_grant_contract() from public;
revoke all on function public.danotch_get_execution_grant_contract(uuid, uuid, uuid, bigint)
  from public;
grant execute on function public.danotch_get_execution_grant_contract(uuid, uuid, uuid, bigint)
  to danotch_fencing;

create function public.danotch_get_device_verification_key(
  p_user_id uuid,
  p_device_id uuid,
  p_fence bigint
) returns jsonb
language sql
security definer
set search_path = ''
stable
as $$
  select jsonb_build_object(
    'public_key', device.public_key,
    'key_algorithm', device.key_algorithm,
    'key_fingerprint', device.key_fingerprint
  )
  from public.danotch_devices device
  where device.user_id = p_user_id
    and device.id = p_device_id
    and device.current_fence = p_fence
    and device.status = 'active'
$$;

revoke all on function public.danotch_get_device_verification_key(uuid, uuid, bigint)
  from public;
grant execute on function public.danotch_get_device_verification_key(uuid, uuid, bigint)
  to danotch_fencing;

create function public.danotch_enrich_executor_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  action public.danotch_local_action_requests;
  grant_row public.danotch_execution_grants;
begin
  if new.event_type = 'local_action_offered' then
    select * into action
    from public.danotch_local_action_requests
    where id = (coalesce(new.payload ->> 'action_id', new.payload ->> 'actionId'))::uuid
      and run_id = new.run_id
      and user_id = new.user_id
      and device_id = new.device_id;
    if action.id is null then
      raise exception 'local action event contract is missing'
        using errcode = '23503';
    end if;
    new.payload := new.payload || jsonb_build_object(
      'action_id', action.id,
      'run_id', action.run_id,
      'session_id', action.run_id,
      'registry_version', action.registry_version,
      'action_type', action.action_type,
      'action_hash', action.action_hash,
      'normalized_parameters', action.normalized_parameters,
      'parameters_hash', action.parameters_hash,
      'capabilities', action.capabilities,
      'image_digest', action.image_digest,
      'workspace_bookmark_id', action.workspace_bookmark_id,
      'result_disclosure_policy', action.result_disclosure_policy,
      'expires_at', action.expires_at
    );
  elsif new.event_type = 'execution_grant_issued' then
    select * into grant_row
    from public.danotch_execution_grants
    where id = (new.payload ->> 'grant_id')::uuid
      and user_id = new.user_id
      and device_id = new.device_id;
    if grant_row.id is null then
      raise exception 'execution grant event contract is missing'
        using errcode = '23503';
    end if;
    new.payload := new.payload || jsonb_build_object(
      'registry_version', grant_row.registry_version,
      'action_type', grant_row.action_type,
      'workspace_bookmark_id', grant_row.workspace_bookmark_id,
      'result_disclosure_policy', grant_row.result_disclosure_policy,
      'device_key_fingerprint', grant_row.device_key_fingerprint
    );
  end if;
  return new;
end
$$;

create trigger danotch_run_events_executor_contract
before insert on public.danotch_run_events
for each row
when (new.event_type in ('local_action_offered', 'execution_grant_issued'))
execute function public.danotch_enrich_executor_event();

revoke all on function public.danotch_enrich_executor_event() from public;
