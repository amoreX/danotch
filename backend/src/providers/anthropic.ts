import Anthropic from '@anthropic-ai/sdk';
import type {
  LLMProvider,
  CanonicalMessage,
  CanonicalTool,
  CanonicalContentBlock,
  StreamResult,
  CompletionResult,
} from './types.js';

export class AnthropicProvider implements LLMProvider {
  private client: Anthropic;
  readonly providerName = 'anthropic';
  readonly modelId: string;

  constructor(apiKey: string, modelId: string) {
    this.client = new Anthropic({ apiKey });
    this.modelId = modelId;
  }

  async stream(params: {
    messages: CanonicalMessage[];
    tools?: CanonicalTool[];
    systemPrompt: string;
    maxTokens: number;
    onText?: (text: string) => void;
  }): Promise<StreamResult> {
    const apiMessages = params.messages.map(toAnthropicMessage);
    const apiTools = params.tools?.map(toAnthropicTool);

    const stream = await this.client.messages.stream({
      model: this.modelId,
      max_tokens: params.maxTokens,
      system: params.systemPrompt,
      messages: apiMessages,
      ...(apiTools && apiTools.length > 0 ? { tools: apiTools } : {}),
    });

    if (params.onText) {
      stream.on('text', params.onText);
    }

    const finalMessage = await stream.finalMessage();

    const content: CanonicalContentBlock[] = finalMessage.content.map((block) => {
      if (block.type === 'text') {
        return { type: 'text' as const, text: block.text };
      }
      if (block.type === 'tool_use') {
        return {
          type: 'tool_use' as const,
          id: block.id,
          name: block.name,
          input: block.input as Record<string, unknown>,
        };
      }
      return { type: 'text' as const, text: '' };
    });

    return {
      content,
      stopReason: finalMessage.stop_reason === 'tool_use' ? 'tool_use' : 'end_turn',
      usage: {
        inputTokens: finalMessage.usage?.input_tokens ?? 0,
        outputTokens: finalMessage.usage?.output_tokens ?? 0,
      },
    };
  }

  async complete(params: {
    messages: CanonicalMessage[];
    systemPrompt: string;
    maxTokens: number;
  }): Promise<CompletionResult> {
    const apiMessages = params.messages.map(toAnthropicMessage);

    const response = await this.client.messages.create({
      model: this.modelId,
      max_tokens: params.maxTokens,
      system: params.systemPrompt,
      messages: apiMessages,
    });

    const text = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === 'text')
      .map((b) => b.text)
      .join('');

    return {
      text,
      usage: {
        inputTokens: response.usage?.input_tokens ?? 0,
        outputTokens: response.usage?.output_tokens ?? 0,
      },
    };
  }
}

// ── Canonical → Anthropic conversion ──

function toAnthropicMessage(msg: CanonicalMessage): Anthropic.MessageParam {
  if (typeof msg.content === 'string') {
    return { role: msg.role, content: msg.content };
  }

  const blocks: Anthropic.ContentBlockParam[] = msg.content.map((block) => {
    if (block.type === 'text') {
      return { type: 'text' as const, text: block.text };
    }
    if (block.type === 'tool_use') {
      return {
        type: 'tool_use' as const,
        id: block.id,
        name: block.name,
        input: block.input,
      };
    }
    if (block.type === 'tool_result') {
      return {
        type: 'tool_result' as const,
        tool_use_id: block.tool_use_id,
        content: block.content,
      };
    }
    return { type: 'text' as const, text: '' };
  });

  return { role: msg.role, content: blocks };
}

function toAnthropicTool(tool: CanonicalTool): Anthropic.Tool {
  return {
    name: tool.name,
    description: tool.description,
    input_schema: tool.input_schema as Anthropic.Tool.InputSchema,
  };
}
