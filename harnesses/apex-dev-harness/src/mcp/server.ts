// SPDX-License-Identifier: MIT
// MCP stdio server — the same engine, available to the agent without asking.

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema, ListToolsRequestSchema, ErrorCode, McpError,
} from '@modelcontextprotocol/sdk/types.js';

import { findRepoRoot } from '../repo.js';
import { route } from '../route.js';
import { gate } from '../gate.js';
import { check } from '../check.js';
import { doctor } from '../doctor.js';

export interface McpTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  run: (args: Record<string, unknown>) => Promise<unknown>;
}

function requireRoot(): string {
  const root = findRepoRoot();
  if (!root) throw new Error('no apex-app checkout found; set APEX_REPO_ROOT');
  return root;
}

function str(args: Record<string, unknown>, key: string): string {
  const v = args[key];
  if (typeof v !== 'string' || !v.trim()) throw new Error(`\`${key}\` is required and must be a non-empty string`);
  return v;
}

export const TOOLS: McpTool[] = [
  {
    name: 'apex_route',
    description:
      'Where does this work go? Returns lane, surface-ledger status and its routing sentence, MWG target, required skills, parity surfaces, and import-guard notes for a path or route. Call this BEFORE building any operator-facing surface.',
    inputSchema: {
      type: 'object',
      properties: { query: { type: 'string', description: 'A repo-relative file path or an app route.' } },
      required: ['query'], additionalProperties: false,
    },
    run: async (args) => route(requireRoot(), str(args, 'query')),
  },
  {
    name: 'apex_gate',
    description:
      'What does the current diff owe before the work can be called done? Computes obligations (manifest regeneration, guard suites, style checks), runs them, and returns a verdict. Call this BEFORE claiming a task or phase is complete.',
    inputSchema: {
      type: 'object',
      properties: {
        base: { type: 'string', description: 'Git ref to diff against (default HEAD).' },
        message: { type: 'string', description: 'Completion report or commit message, scanned for watchlist vocabulary.' },
      },
      additionalProperties: false,
    },
    run: async (args) => gate(requireRoot(), {
      base: typeof args.base === 'string' ? args.base : undefined,
      message: typeof args.message === 'string' ? args.message : undefined,
    }),
  },
  {
    name: 'apex_check',
    description: 'Would this edit violate a blocking guardrail? Returns allow, or the rule id and reason for a refusal.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Repo-relative path to be edited.' },
        content: { type: 'string', description: 'The proposed new content, if any.' },
      },
      required: ['path'], additionalProperties: false,
    },
    run: async (args) => check(requireRoot(), str(args, 'path'), typeof args.content === 'string' ? args.content : null),
  },
  {
    name: 'apex_doctor',
    description: 'What can the harness see? Truth-file parse coverage, wrapped-command availability, hook install state.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    run: async () => doctor(findRepoRoot()),
  },
];

export function createServer(): Server {
  const server = new Server(
    { name: 'apex-dev-harness', version: '0.1.0' },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: TOOLS.map((t) => ({
      name: t.name, description: t.description, inputSchema: t.inputSchema as { type: 'object' },
    })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const tool = TOOLS.find((t) => t.name === req.params.name);
    if (!tool) throw new McpError(ErrorCode.MethodNotFound, `unknown tool: ${req.params.name}`);
    try {
      const out = await tool.run(req.params.arguments ?? {});
      return { content: [{ type: 'text' as const, text: JSON.stringify(out, null, 2) }] };
    } catch (err) {
      throw new McpError(ErrorCode.InternalError, err instanceof Error ? err.message : String(err));
    }
  });

  return server;
}

export async function start(): Promise<void> {
  await createServer().connect(new StdioServerTransport());
  console.error('[apex-dev-harness] MCP server ready —', TOOLS.length, 'tools');
}
