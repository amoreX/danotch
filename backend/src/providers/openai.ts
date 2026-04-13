import OpenAI from 'openai';
import type {
  LLMProvider,
  CanonicalMessage,
  CanonicalTool,
  CanonicalContentBlock,
  CanonicalToolUseBlock,
  CanonicalToolResultBlock,
  StreamResult,
  CompletionResult,
} from './types.js';

export class OpenAIProvider implements LLMProvider {
  private client: OpenAI;
  readonly providerName: string;
  readonly modelId: string;

  constructor(apiKey: string, modelId: string, baseURL?: string) {
    this.client = new OpenAI({ apiKey, ...(baseURL ? { baseURL } : {}) });
    this.providerName = baseURL ? 'openrouter' : 'openai';
    this.modelId = modelId;
  }

  async stream(params: {
    messages: CanonicalMessage[];
    tools?: CanonicalTool[];
    systemPrompt: string;
    maxTokens: number;
    onText?: (text: string) => void;
  }): Promise<StreamResult> {
    const apiMessages = toOpenAIMessages(params.messages, params.systemPrompt);
    const apiTools = params.tools?.length ? params.tools.map(toOpenAITool) : undefined;

    const stream = await this.client.chat.completions.create({
      model: this.modelId,
      max_tokens: params.maxTokens,
      messages: apiMessages,
      ...(apiTools ? { tools: apiTools } : {}),
      stream: true,
      stream_options: { include_usage: true },
    });

    let fullText = '';
    const toolCallAccumulator = new Map<number, { id: string; name: string; arguments: string }>();
    let usage = { inputTokens: 0, outputTokens: 0 };
    let finishReason = '';

    for await (const chunk of stream) {
      const choice = chunk.choices?.[0];

      if (choice?.delta?.content) {
        fullText += choice.delta.content;
        params.onText?.(choice.delta.content);
      }

      if (choice?.delta?.tool_calls) {
        for (const tc of choice.delta.tool_calls) {
          const existing = toolCallAccumulator.get(tc.index);
          if (existing) {
            if (tc.function?.arguments) {
              existing.arguments += tc.function.arguments;
            }
          } else {
            toolCallAccumulator.set(tc.index, {
              id: tc.id ?? '',
              name: tc.function?.name ?? '',
              arguments: tc.function?.arguments ?? '',
            });
          }
        }
      }

      if (choice?.finish_reason) {
        finishReason = choice.finish_reason;
      }

      if (chunk.usage) {
        usage = {
          inputTokens: chunk.usage.prompt_tokens ?? 0,
          outputTokens: chunk.usage.completion_tokens ?? 0,
        };
      }
    }

    // Build canonical content blocks
    const content: CanonicalContentBlock[] = [];

    if (fullText) {
      content.push({ type: 'text', text: fullText });
    }

    for (const [, tc] of toolCallAccumulator) {
      let input: Record<string, unknown> = {};
      try {
        input = JSON.parse(tc.arguments);
      } catch {
        input = { raw: tc.arguments };
      }
      content.push({
        type: 'tool_use',
        id: tc.id,
        name: tc.name,
        input,
      });
    }

    const stopReason =
      finishReason === 'tool_calls'
        ? ('tool_use' as const)
        : finishReason === 'length'
          ? ('max_tokens' as const)
          : ('end_turn' as const);

    return { content, stopReason, usage };
  }

  async complete(params: {
    messages: CanonicalMessage[];
    systemPrompt: string;
    maxTokens: number;
  }): Promise<CompletionResult> {
    const apiMessages = toOpenAIMessages(params.messages, params.systemPrompt);

    const response = await this.client.chat.completions.create({
      model: this.modelId,
      max_tokens: params.maxTokens,
      messages: apiMessages,
    });

    const text = response.choices[0]?.message?.content ?? '';

    return {
      text,
      usage: {
        inputTokens: response.usage?.prompt_tokens ?? 0,
        outputTokens: response.usage?.completion_tokens ?? 0,
      },
    };
  }
}

// ── Canonical → OpenAI conversion ──

function toOpenAIMessages(
  messages: CanonicalMessage[],
  systemPrompt: string
): OpenAI.ChatCompletionMessageParam[] {
  const result: OpenAI.ChatCompletionMessageParam[] = [
    { role: 'system', content: systemPrompt },
  ];

  for (const msg of messages) {
    if (typeof msg.content === 'string') {
      result.push({ role: msg.role, content: msg.content });
      continue;
    }

    if (msg.role === 'assistant') {
      const textParts = msg.content.filter((b) => b.type === 'text');
      const toolUseParts = msg.content.filter(
        (b): b is CanonicalToolUseBlock => b.type === 'tool_use'
      );

      const textContent =
        textParts.map((b) => (b.type === 'text' ? b.text : '')).join('') || null;

      if (toolUseParts.length > 0) {
        result.push({
          role: 'assistant',
          content: textContent,
          tool_calls: toolUseParts.map((b) => ({
            id: b.id,
            type: 'function' as const,
            function: {
              name: b.name,
              arguments: JSON.stringify(b.input),
            },
          })),
        });
      } else {
        result.push({ role: 'assistant', content: textContent });
      }
    } else if (msg.role === 'user') {
      const toolResults = msg.content.filter(
        (b): b is CanonicalToolResultBlock => b.type === 'tool_result'
      );
      const textParts = msg.content.filter((b) => b.type === 'text');

      // OpenAI uses separate "tool" role messages for tool results
      for (const block of toolResults) {
        result.push({
          role: 'tool',
          tool_call_id: block.tool_use_id,
          content: block.content,
        });
      }

      // Any remaining text goes as a user message
      const text = textParts.map((b) => (b.type === 'text' ? b.text : '')).join('');
      if (text) {
        result.push({ role: 'user', content: text });
      }
    }
  }

  return result;
}

function toOpenAITool(tool: CanonicalTool): OpenAI.ChatCompletionTool {
  return {
    type: 'function',
    function: {
      name: tool.name,
      description: tool.description,
      parameters: tool.input_schema as OpenAI.FunctionParameters,
    },
  };
}
