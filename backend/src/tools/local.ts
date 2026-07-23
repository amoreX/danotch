import type { CanonicalTool } from '../providers/types.js';
import { lookup } from 'node:dns/promises';
import { BlockList, isIP } from 'node:net';
import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
const MAX_RESULT_CHARS = 5000;
const MAX_SEARCH_CHARS = 2000;
const MAX_BODY_BYTES = 512 * 1024;
const REQUEST_TIMEOUT_MS = 15_000;
const MAX_REDIRECTS = 5;

const blockedAddresses = new BlockList();
for (const [network, prefix, family] of [
  ['0.0.0.0', 8, 'ipv4'], ['10.0.0.0', 8, 'ipv4'], ['100.64.0.0', 10, 'ipv4'],
  ['127.0.0.0', 8, 'ipv4'], ['169.254.0.0', 16, 'ipv4'], ['172.16.0.0', 12, 'ipv4'],
  ['192.0.0.0', 24, 'ipv4'], ['192.168.0.0', 16, 'ipv4'], ['198.18.0.0', 15, 'ipv4'],
  ['224.0.0.0', 4, 'ipv4'], ['240.0.0.0', 4, 'ipv4'],
  ['::', 128, 'ipv6'], ['::1', 128, 'ipv6'], ['fc00::', 7, 'ipv6'],
  ['fe80::', 10, 'ipv6'], ['ff00::', 8, 'ipv6'],
] as const) blockedAddresses.addSubnet(network, prefix, family);

export function isPrivateAddress(address: string): boolean {
  const family = isIP(address);
  if (family === 0) return true;
  if (family === 6) {
    const mapped = address.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/i)?.[1];
    if (mapped) return blockedAddresses.check(mapped, 'ipv4');
  }
  return blockedAddresses.check(address, family === 4 ? 'ipv4' : 'ipv6');
}

function parseWebUrl(urlString: string): URL {
  let parsed: URL;
  try {
    parsed = new URL(urlString);
  } catch {
    throw new Error('invalid_url');
  }

  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('unsupported_protocol');
  }
  if (parsed.username || parsed.password) throw new Error('url_credentials_forbidden');
  const hostname = parsed.hostname.toLowerCase();
  if (hostname === 'localhost' || hostname.endsWith('.localhost')) throw new Error('private_address');
  return parsed;
}

function stripHtml(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<[^>]*>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

async function secureRequest(urlString: string, redirects = 0): Promise<{
  body: string;
  contentType: string;
}> {
  if (redirects > MAX_REDIRECTS) throw new Error('redirect_limit');
  const parsed = parseWebUrl(urlString);
  const records = isIP(parsed.hostname)
    ? [{ address: parsed.hostname, family: isIP(parsed.hostname) as 4 | 6 }]
    : await lookup(parsed.hostname, { all: true, verbatim: true });
  if (records.length === 0 || records.some((record) => isPrivateAddress(record.address))) {
    throw new Error('private_address');
  }
  const selected = records[0];
  const request = parsed.protocol === 'https:' ? httpsRequest : httpRequest;

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => req.destroy(new Error('request_timeout')), REQUEST_TIMEOUT_MS);
    const req = request(parsed, {
      method: 'GET',
      headers: { 'User-Agent': 'Perch/1.0', Accept: 'text/html,application/json,text/plain;q=0.9' },
      lookup: (_hostname, _options, callback) => callback(null, selected.address, selected.family),
    }, (response) => {
      const location = response.headers.location;
      if (response.statusCode && response.statusCode >= 300 && response.statusCode < 400 && location) {
        response.resume();
        clearTimeout(timer);
        secureRequest(new URL(location, parsed).toString(), redirects + 1).then(resolve, reject);
        return;
      }
      const chunks: Buffer[] = [];
      let bytes = 0;
      response.on('data', (chunk: Buffer) => {
        bytes += chunk.length;
        if (bytes > MAX_BODY_BYTES) {
          response.destroy(new Error('response_too_large'));
          return;
        }
        chunks.push(chunk);
      });
      response.on('end', () => {
        clearTimeout(timer);
        resolve({
          body: Buffer.concat(chunks).toString('utf8'),
          contentType: String(response.headers['content-type'] ?? ''),
        });
      });
      response.on('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
    });
    req.setTimeout(REQUEST_TIMEOUT_MS, () => req.destroy(new Error('request_timeout')));
    req.on('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    req.end();
  });
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

  try {
    // Use DuckDuckGo HTML lite for search results
    const encoded = encodeURIComponent(query);
    const { body: html } = await secureRequest(`https://html.duckduckgo.com/html/?q=${encoded}`);

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
  } catch {
    return 'Search failed: remote content could not be retrieved';
  }
}

async function webFetch(input: Record<string, unknown>): Promise<string> {
  const url = input.url as string;

  try {
    const { body, contentType } = await secureRequest(url);

    if (contentType.includes('json')) {
      const json = JSON.parse(body);
      return JSON.stringify(json, null, 2).slice(0, MAX_RESULT_CHARS);
    }

    const text = stripHtml(body);

    return text.slice(0, MAX_RESULT_CHARS) || '(empty page)';
  } catch {
    return 'Fetch blocked or failed: remote content could not be retrieved';
  }
}
