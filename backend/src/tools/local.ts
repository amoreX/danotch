import type { CanonicalTool } from '../providers/types.js';
const MAX_RESULT_CHARS = 5000;
const MAX_SEARCH_CHARS = 2000;
const MAX_ERROR_CHARS = 2000;

const PRIVATE_IP_REGEX = /^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|169\.254\.|0\.0\.0\.0|::1|fc00:|fe80:)/i;

function isUnsafeUrl(urlString: string): string | null {
  let parsed: URL;
  try {
    parsed = new URL(urlString);
  } catch {
    return 'Invalid URL';
  }

  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return 'Only http:// and https:// URLs are allowed';
  }

  const hostname = parsed.hostname.toLowerCase();
  if (hostname === 'localhost' || hostname.endsWith('.localhost') || PRIVATE_IP_REGEX.test(hostname)) {
    return 'Private/internal addresses are not allowed';
  }

  return null;
}

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

export const hostedTools: CanonicalTool[] = [
  {
    name: 'web_search',
    description:
      'Search the web for current information. Use when the user asks about recent events, current data, prices, weather, news, or anything that requires up-to-date information. Returns search result snippets.',
    input_schema: {
      type: 'object',
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
      type: 'object',
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

export async function executeHostedTool(
  toolName: string,
  input: Record<string, unknown>
): Promise<string> {
  switch (toolName) {
    case 'web_search':
      return webSearch(input);
    case 'web_fetch':
      return webFetch(input);
    default:
      throw new Error(`Tool ${toolName} is not registered for hosted execution`);
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
        'User-Agent': 'Perch/1.0',
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
      return `Search results for "${query}":\n${textContent.slice(0, MAX_SEARCH_CHARS)}`;
    }

    return `Search results for "${query}":\n\n${results.join('\n\n')}`;
  } catch (err) {
    return `Search failed: ${toErrorMessage(err)}`;
  }
}

async function webFetch(input: Record<string, unknown>): Promise<string> {
  const url = input.url as string;
  console.log(`[tool:web_fetch] ${url}`);

  const unsafe = isUnsafeUrl(url);
  if (unsafe) {
    return `Fetch blocked: ${unsafe}`;
  }

  try {
    const resp = await fetch(url, {
      headers: { 'User-Agent': 'Perch/1.0' },
      signal: AbortSignal.timeout(15_000),
    });

    const contentType = resp.headers.get('content-type') || '';

    if (contentType.includes('json')) {
      const json = await resp.json();
      return JSON.stringify(json, null, 2).slice(0, MAX_RESULT_CHARS);
    }

    const html = await resp.text();
    const text = stripHtml(html);

    return text.slice(0, MAX_RESULT_CHARS) || '(empty page)';
  } catch (err) {
    return `Fetch failed: ${toErrorMessage(err)}`;
  }
}
