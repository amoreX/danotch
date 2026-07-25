export interface Migration {
  version: number;
  name: string;
  sql: string;
}

export const migrations: readonly Migration[] = [
  {
    version: 1,
    name: 'local_first_core',
    sql: `
CREATE TABLE provider_preferences (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL CHECK (provider IN ('anthropic','openai','openrouter','deepseek','custom')),
  model_id TEXT NOT NULL,
  base_url TEXT,
  keychain_account TEXT NOT NULL,
  is_active INTEGER NOT NULL DEFAULT 0 CHECK (is_active IN (0,1)),
  verified_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX one_active_provider ON provider_preferences(is_active) WHERE is_active = 1;

CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  title TEXT,
  provider_id TEXT REFERENCES provider_preferences(id) ON DELETE SET NULL,
  model_id TEXT,
  base_url TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user','assistant','tool')),
  content TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);
CREATE INDEX messages_conversation_created ON messages(conversation_id, created_at);

CREATE TABLE schedules (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  prompt TEXT NOT NULL,
  task_type TEXT NOT NULL CHECK (task_type IN ('scheduled','poll')),
  cron TEXT,
  interval_ms INTEGER,
  provider_id TEXT REFERENCES provider_preferences(id) ON DELETE SET NULL,
  model_id TEXT,
  base_url TEXT,
  notify_user INTEGER NOT NULL DEFAULT 0 CHECK (notify_user IN (0,1)),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  next_run_at TEXT NOT NULL,
  last_run_at TEXT,
  run_count INTEGER NOT NULL DEFAULT 0,
  last_status TEXT,
  last_result TEXT,
  claim_id TEXT,
  claim_until TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK ((cron IS NOT NULL) != (interval_ms IS NOT NULL))
);
CREATE INDEX schedules_due ON schedules(enabled, next_run_at);

CREATE TABLE notifications (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  source_id TEXT,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  read INTEGER NOT NULL DEFAULT 0 CHECK (read IN (0,1)),
  created_at TEXT NOT NULL
);
CREATE INDEX notifications_created ON notifications(created_at DESC);

CREATE TABLE connections (
  id TEXT PRIMARY KEY,
  app_type TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL,
  external_account_id TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
  schedule_id TEXT REFERENCES schedules(id) ON DELETE SET NULL,
  provider_id TEXT REFERENCES provider_preferences(id) ON DELETE SET NULL,
  model_id TEXT,
  status TEXT NOT NULL,
  input_json TEXT NOT NULL,
  result TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT
);
CREATE INDEX runs_created ON runs(created_at DESC);
CREATE TABLE run_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX run_events_run ON run_events(run_id, id);

CREATE TABLE pending_actions (
  id TEXT PRIMARY KEY,
  run_id TEXT REFERENCES runs(id) ON DELETE CASCADE,
  action_type TEXT NOT NULL,
  summary TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending','approved','rejected','expired')),
  created_at TEXT NOT NULL,
  resolved_at TEXT
);
`,
  },
  {
    version: 2,
    name: 'one_preference_per_provider',
    sql: `
DELETE FROM provider_preferences
 WHERE id NOT IN (
   SELECT id FROM provider_preferences AS selected
    WHERE selected.id = (
      SELECT candidate.id FROM provider_preferences AS candidate
       WHERE candidate.provider = selected.provider
       ORDER BY candidate.updated_at DESC, candidate.id DESC LIMIT 1
    )
 );
CREATE UNIQUE INDEX provider_preferences_provider ON provider_preferences(provider);
`,
  },
  {
    version: 3,
    name: 'local_identity_integrations_and_durable_actions',
    sql: `
CREATE TABLE local_identity (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  composio_user_id TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL
);

CREATE TABLE integration_config (
  app_type TEXT PRIMARY KEY CHECK (app_type IN ('gmail','googlecalendar','googledocs','github')),
  toolkit_slug TEXT NOT NULL,
  auth_config_id TEXT,
  updated_at TEXT NOT NULL
);

ALTER TABLE pending_actions RENAME TO pending_actions_v1;
CREATE TABLE pending_actions (
  id TEXT PRIMARY KEY,
  run_id TEXT REFERENCES runs(id) ON DELETE CASCADE,
  session_id TEXT,
  action_origin TEXT NOT NULL CHECK (action_origin IN ('local','composio')),
  action_type TEXT NOT NULL,
  summary TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  normalized_parameters_json TEXT NOT NULL,
  parameters_hash TEXT NOT NULL,
  action_hash TEXT NOT NULL,
  registry_version TEXT NOT NULL,
  capabilities_json TEXT,
  workspace_bookmark_id TEXT,
  status TEXT NOT NULL CHECK (status IN (
    'pending','approved','rejected','expired','executing','completed','failed'
  )),
  idempotency_key TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  decision_json TEXT,
  execution_request_id TEXT UNIQUE,
  result_json TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  resolved_at TEXT,
  executed_at TEXT
);
INSERT INTO pending_actions (
  id,run_id,action_origin,action_type,summary,payload_json,
  normalized_parameters_json,parameters_hash,action_hash,registry_version,
  status,idempotency_key,expires_at,created_at,resolved_at
)
SELECT
  id,run_id,'composio',action_type,summary,payload_json,payload_json,
  lower(hex(randomblob(32))),lower(hex(randomblob(32))),'1',
  status,lower(hex(randomblob(16))),datetime(created_at, '+5 minutes'),created_at,resolved_at
FROM pending_actions_v1;
DROP TABLE pending_actions_v1;
CREATE INDEX pending_actions_status_expiry ON pending_actions(status, expires_at);
CREATE INDEX pending_actions_run ON pending_actions(run_id, created_at);
`,
  },
] as const;
