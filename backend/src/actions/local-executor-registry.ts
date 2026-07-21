import { createHash } from 'node:crypto';

export const LOCAL_EXECUTOR_REGISTRY_VERSION = '1' as const;
export const LOCAL_EXECUTOR_ACTIONS = [
  'workspace.inspect',
  'workspace.search',
  'workspace.read_file',
  'workspace.run_tests',
  'shell.execute',
] as const;

export interface LocalExecutionCapabilities {
  workspace_mode: 'read_only' | 'read_write';
  egress_destinations: string[];
  sensitive_file_access: boolean;
  sensitive_output_disclosure: boolean;
  result_upload: boolean;
  limits: {
    cpu_count: number;
    memory_bytes: number;
    disk_bytes: number;
    process_count: number;
    output_bytes: number;
    timeout_seconds: number;
  };
}

function exact(value: Record<string, unknown>, keys: string[]): void {
  if (
    Object.keys(value).length !== keys.length
    || keys.some((key) => !(key in value))
  ) throw new Error('local action fields do not exactly match registry v1');
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('local action value must be an object');
  }
  return value as Record<string, unknown>;
}

function string(value: unknown, maximum: number): string {
  if (typeof value !== 'string' || value.length === 0 || Buffer.byteLength(value) > maximum) {
    throw new Error('local action string is invalid');
  }
  return value;
}

function integer(value: unknown, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new Error('local action integer is outside its bound');
  }
  return value as number;
}

function relativePath(value: unknown): string {
  const result = string(value, 1_024);
  if (
    result === '.'
    || result.startsWith('/')
    || result.includes('\0')
    || result.split('/').includes('..')
  ) throw new Error('workspace path is not normalized and relative');
  return result;
}

export function validateLocalCapabilities(input: unknown): LocalExecutionCapabilities {
  const value = object(input);
  exact(value, [
    'workspace_mode',
    'egress_destinations',
    'sensitive_file_access',
    'sensitive_output_disclosure',
    'result_upload',
    'limits',
  ]);
  if (value.workspace_mode !== 'read_only' && value.workspace_mode !== 'read_write') {
    throw new Error('workspace mode is invalid');
  }
  if (!Array.isArray(value.egress_destinations) || value.egress_destinations.length !== 0) {
    throw new Error('network is unavailable for local VM execution');
  }
  if (
    typeof value.sensitive_file_access !== 'boolean'
    ||
    typeof value.sensitive_output_disclosure !== 'boolean'
    || typeof value.result_upload !== 'boolean'
  ) throw new Error('result disclosure policy is invalid');
  const limits = object(value.limits);
  exact(limits, [
    'cpu_count', 'memory_bytes', 'disk_bytes', 'process_count',
    'output_bytes', 'timeout_seconds',
  ]);
  return {
    workspace_mode: value.workspace_mode,
    egress_destinations: [],
    sensitive_file_access: value.sensitive_file_access,
    sensitive_output_disclosure: value.sensitive_output_disclosure,
    result_upload: value.result_upload,
    limits: {
      cpu_count: integer(limits.cpu_count, 1, 4),
      memory_bytes: integer(limits.memory_bytes, 128 * 1_024 * 1_024, 4 * 1_024 ** 3),
      disk_bytes: integer(limits.disk_bytes, 256 * 1_024 * 1_024, 8 * 1_024 ** 3),
      process_count: integer(limits.process_count, 1, 256),
      output_bytes: integer(limits.output_bytes, 1, 4 * 1_024 * 1_024),
      timeout_seconds: integer(limits.timeout_seconds, 1, 1_800),
    },
  };
}

export function validateLocalAction(
  registryVersion: string,
  actionType: string,
  input: unknown,
  capabilitiesInput: unknown,
): {
  normalizedParameters: Record<string, unknown>;
  capabilities: LocalExecutionCapabilities;
  parametersHash: string;
  actionHash: string;
  highRiskShell: boolean;
} {
  if (registryVersion !== LOCAL_EXECUTOR_REGISTRY_VERSION) {
    throw new Error('local executor registry version mismatch');
  }
  const parameters = object(input);
  const capabilities = validateLocalCapabilities(capabilitiesInput);
  switch (actionType) {
    case 'workspace.inspect':
      exact(parameters, ['path', 'depth']);
      relativePath(parameters.path);
      integer(parameters.depth, 1, 8);
      break;
    case 'workspace.search':
      exact(parameters, ['query', 'path', 'max_results']);
      string(parameters.query, 500);
      relativePath(parameters.path);
      integer(parameters.max_results, 1, 1_000);
      break;
    case 'workspace.read_file':
      exact(parameters, ['path', 'max_bytes']);
      relativePath(parameters.path);
      integer(parameters.max_bytes, 1, capabilities.limits.output_bytes);
      break;
    case 'workspace.run_tests': {
      exact(parameters, ['runner', 'arguments']);
      if (parameters.runner !== 'swift' && parameters.runner !== 'npm') {
        throw new Error('test runner is not allowlisted');
      }
      if (
        !Array.isArray(parameters.arguments)
        || parameters.arguments.length > 20
        || parameters.arguments.some((argument) => {
          const value = string(argument, 200);
          return value === '--prefix' || value === '--global' || value.includes('\0');
        })
      ) throw new Error('test arguments are invalid');
      break;
    }
    case 'shell.execute':
      exact(parameters, ['command']);
      if (string(parameters.command, 4_096).includes('\0')) {
        throw new Error('shell command contains NUL');
      }
      break;
    default:
      throw new Error('unknown local executor action');
  }
  const parametersText = postgresJSON(parameters);
  const parametersHash = createHash('sha256').update(parametersText).digest('hex');
  return {
    normalizedParameters: parameters,
    capabilities,
    parametersHash,
    actionHash: createHash('sha256')
      .update(`${registryVersion}\n${actionType}\n${parametersText}`)
      .digest('hex'),
    highRiskShell: actionType === 'shell.execute',
  };
}

function postgresJSON(value: unknown): string {
  if (value === null) return 'null';
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'boolean' || typeof value === 'number') return String(value);
  if (Array.isArray(value)) return `[${value.map(postgresJSON).join(', ')}]`;
  const entries = Object.entries(object(value)).sort(([left], [right]) => left.localeCompare(right));
  return `{${entries.map(([key, child]) => `${JSON.stringify(key)}: ${postgresJSON(child)}`).join(', ')}}`;
}
