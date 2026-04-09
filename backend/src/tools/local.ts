import type Anthropic from '@anthropic-ai/sdk';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

function stripHtml(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<[^>]*>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function toErrorMessage(err: unknown): string {
  return err instanceof Error ? err.message : 'Unknown error';
}

// ── Tool Definitions ──

export const localTools: Anthropic.Tool[] = [
  {
    name: 'bash_execute',
    description:
      'Execute a shell command on the user\'s local machine and return the output. Use for: checking files, running scripts, getting system info, installing packages, etc. Commands run in a bash shell. Be careful with destructive commands.',
    input_schema: {
      type: 'object' as const,
      properties: {
        command: {
          type: 'string',
          description: 'The bash command to execute. Keep it concise. Avoid interactive commands.',
        },
        cwd: {
          type: 'string',
          description: 'Optional working directory. Defaults to home directory.',
        },
      },
      required: ['command'],
    },
  },
  {
    name: 'web_search',
    description:
      'Search the web for current information. Use when the user asks about recent events, current data, prices, weather, news, or anything that requires up-to-date information. Returns search result snippets.',
    input_schema: {
      type: 'object' as const,
      properties: {
        query: {
          type: 'string',
          description: 'The search query.',
        },
      },
      required: ['query'],
    },
  },
  {
    name: 'web_fetch',
    description:
      'Fetch the text content of a specific URL. Use when you need to read a webpage, API endpoint, or online resource.',
    input_schema: {
      type: 'object' as const,
      properties: {
        url: {
          type: 'string',
          description: 'The URL to fetch.',
        },
      },
      required: ['url'],
    },
  },
];

// ── Tool Handlers ──

export async function executeLocalTool(
  toolName: string,
  input: Record<string, unknown>
): Promise<string> {
  switch (toolName) {
    case 'bash_execute':
      return bashExecute(input);
    case 'web_search':
      return webSearch(input);
    case 'web_fetch':
      return webFetch(input);
    default:
      return JSON.stringify({ error: `Unknown tool: ${toolName}` });
  }
}

async function bashExecute(input: Record<string, unknown>): Promise<string> {
  const command = input.command as string;
  const cwd = (input.cwd as string) || process.env.HOME || '/';

  console.log(`[tool:bash] $ ${command}`);

  try {
    const { stdout, stderr } = await execAsync(command, {
      cwd,
      timeout: 30_000,
      maxBuffer: 1024 * 1024, // 1MB
      shell: '/bin/bash',
    });

    const output = stdout.trim();
    const errors = stderr.trim();

    let result = '';
    if (output) result += output;
    if (errors) result += (result ? '\n\nSTDERR:\n' : '') + errors;

    return result.slice(0, 5000) || '(no output)';
  } catch (err: any) {
    const msg = err.stderr?.trim() || err.stdout?.trim() || err.message;
    return `Error (exit ${err.code ?? '?'}): ${msg}`.slice(0, 2000);
  }
}

async function webSearch(input: Record<string, unknown>): Promise<string> {
  const query = input.query as string;
  console.log(`[tool:web_search] "${query}"`);

  try {
    // Use DuckDuckGo HTML lite for search results
    const encoded = encodeURIComponent(query);
    const resp = await fetch(`https://html.duckduckgo.com/html/?q=${encoded}`, {
      headers: {
        'User-Agent': 'Danotch/1.0',
      },
    });

    const html = await resp.text();

    // Parse result snippets from DDG HTML
    const results: string[] = [];
    const snippetRegex = /<a class="result__a"[^>]*>([^<]+)<\/a>[\s\S]*?<a class="result__snippet"[^>]*>([\s\S]*?)<\/a>/g;
    let match;
    while ((match = snippetRegex.exec(html)) !== null && results.length < 5) {
      const title = match[1].replace(/<[^>]*>/g, '').trim();
      const snippet = match[2].replace(/<[^>]*>/g, '').trim();
      if (title && snippet) {
        results.push(`**${title}**\n${snippet}`);
      }
    }

    if (results.length === 0) {
      // Fallback: try to extract any text content
      const textContent = stripHtml(html);
      return `Search results for "${query}":\n${textContent.slice(0, 2000)}`;
    }

    return `Search results for "${query}":\n\n${results.join('\n\n')}`;
  } catch (err) {
    return `Search failed: ${toErrorMessage(err)}`;
  }
}

async function webFetch(input: Record<string, unknown>): Promise<string> {
  const url = input.url as string;
  console.log(`[tool:web_fetch] ${url}`);

  try {
    const resp = await fetch(url, {
      headers: { 'User-Agent': 'Danotch/1.0' },
      signal: AbortSignal.timeout(15_000),
    });

    const contentType = resp.headers.get('content-type') || '';

    if (contentType.includes('json')) {
      const json = await resp.json();
      return JSON.stringify(json, null, 2).slice(0, 5000);
    }

    const html = await resp.text();
    const text = stripHtml(html);

    return text.slice(0, 5000) || '(empty page)';
  } catch (err) {
    return `Fetch failed: ${toErrorMessage(err)}`;
  }
}
