// ── Canonical types for provider-agnostic LLM interactions ──

export interface CanonicalTool {
  name: string;
  description: string;
  input_schema: Record<string, unknown>;
}

// Content blocks in messages
export interface CanonicalTextBlock {
  type: 'text';
  text: string;
}

export interface CanonicalToolUseBlock {
  type: 'tool_use';
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export interface CanonicalToolResultBlock {
  type: 'tool_result';
  tool_use_id: string;
  content: string;
}

export type CanonicalContentBlock =
  | CanonicalTextBlock
  | CanonicalToolUseBlock
  | CanonicalToolResultBlock;

export interface CanonicalMessage {
  role: 'user' | 'assistant';
  content: string | CanonicalContentBlock[];
}

// Provider stream/completion results
export interface StreamResult {
  content: CanonicalContentBlock[];
  stopReason: 'end_turn' | 'tool_use' | 'max_tokens';
  usage: { inputTokens: number; outputTokens: number };
}

export interface CompletionResult {
  text: string;
  usage: { inputTokens: number; outputTokens: number };
}

// Provider interface — all providers implement this
export interface LLMProvider {
  readonly providerName: string;
  readonly modelId: string;

  stream(params: {
    messages: CanonicalMessage[];
    tools?: CanonicalTool[];
    systemPrompt: string;
    maxTokens: number;
    onText?: (text: string) => void;
  }): Promise<StreamResult>;

  complete(params: {
    messages: CanonicalMessage[];
    systemPrompt: string;
    maxTokens: number;
  }): Promise<CompletionResult>;
}

export type ProviderType = 'anthropic' | 'openai' | 'openrouter';

export interface ProviderConfig {
  id: string;
  user_id: string;
  provider: ProviderType;
  api_key_encrypted: string;
  model_id: string;
  is_active: boolean;
  verified_at?: string;
}
