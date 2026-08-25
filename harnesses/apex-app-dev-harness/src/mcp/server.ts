// SPDX-License-Identifier: MIT
// MCP primitive (ADR-022) — stdio server for apex-app-harness.

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ListResourcesRequestSchema,
  ReadResourceRequestSchema,
  ListPromptsRequestSchema,
  GetPromptRequestSchema,
  ErrorCode,
  McpError,
} from '@modelcontextprotocol/sdk/types.js';

import { TOOLS } from './tools.js';
import { RESOURCES } from './resources.js';
import { PROMPTS } from './prompts.js';
import { decide, withTimeout, POLICY } from './policy.js';
import { audit } from './audit.js';

import { createRequire } from 'node:module';

export const SERVER_NAME = 'apex-app-harness';
/** Read from package.json so it cannot drift from the published version. */
export const SERVER_VERSION: string =
  (createRequire(import.meta.url)('../../package.json') as { version: string }).version;

/**
 * The gated dispatch path every tool call takes:
 *   tool lookup -> policy decision -> (approval gate) -> timeout-bounded run -> audit.
 * Exported separately from the transport so tests can drive it directly.
 */
export async function dispatch(
  name: string,
  args: Record<string, unknown>,
  state: { callsThisTurn: number },
): Promise<unknown> {
  const tool = TOOLS.find((t) => t.name === name);
  if (!tool) {
    await audit({ ts: new Date().toISOString(), tool: name, decision: 'error', reason: 'unknown tool' });
    throw new McpError(ErrorCode.MethodNotFound, `unknown tool: ${name}`);
  }

  if (state.callsThisTurn >= POLICY.maxToolCallsPerTurn) {
    const reason = `tool call budget exhausted (${POLICY.maxToolCallsPerTurn} per turn)`;
    await audit({ ts: new Date().toISOString(), tool: name, decision: 'denied', reason });
    throw new McpError(ErrorCode.InvalidRequest, reason);
  }

  const decision = decide(tool.ctx);
  if (!decision.allowed) {
    await audit({ ts: new Date().toISOString(), tool: name, decision: 'denied', reason: decision.reason });
    throw new McpError(ErrorCode.InvalidRequest, `denied: ${decision.reason}`);
  }
  if (decision.requiresApproval) {
    // The harness never self-approves a dangerous tool. The host owns that
    // prompt; we refuse and say why rather than running it unattended.
    const reason = 'dangerous tool requires explicit user approval via the host';
    await audit({ ts: new Date().toISOString(), tool: name, decision: 'approval-required', reason });
    throw new McpError(ErrorCode.InvalidRequest, reason);
  }

  state.callsThisTurn += 1;
  const started = Date.now();
  try {
    const output = await withTimeout(() => tool.run(args));
    await audit({
      ts: new Date().toISOString(),
      tool: name,
      decision: 'allowed',
      reason: decision.reason,
      durationMs: Date.now() - started,
    });
    return output;
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    await audit({
      ts: new Date().toISOString(),
      tool: name,
      decision: 'error',
      reason,
      durationMs: Date.now() - started,
    });
    throw err instanceof McpError ? err : new McpError(ErrorCode.InternalError, reason);
  }
}

export function createServer(): Server {
  const server = new Server(
    { name: SERVER_NAME, version: SERVER_VERSION },
    { capabilities: { tools: {}, resources: {}, prompts: {} } },
  );

  // Per-connection budget. Reset when the client reconnects.
  const state = { callsThisTurn: 0 };

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: TOOLS.map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema as { type: 'object' },
    })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const output = await dispatch(req.params.name, req.params.arguments ?? {}, state);
    return { content: [{ type: 'text' as const, text: JSON.stringify(output, null, 2) }] };
  });

  server.setRequestHandler(ListResourcesRequestSchema, async () => ({
    resources: RESOURCES.map((r) => ({ uri: r.uri, name: r.name, mimeType: r.mimeType })),
  }));

  server.setRequestHandler(ReadResourceRequestSchema, async (req) => {
    const resource = RESOURCES.find((r) => r.uri === req.params.uri);
    if (!resource) throw new McpError(ErrorCode.InvalidParams, `unknown resource: ${req.params.uri}`);
    return { contents: [{ uri: resource.uri, mimeType: resource.mimeType, text: await resource.read() }] };
  });

  server.setRequestHandler(ListPromptsRequestSchema, async () => ({
    prompts: PROMPTS.map((p) => ({ name: p.name, description: p.description })),
  }));

  server.setRequestHandler(GetPromptRequestSchema, async (req) => {
    const prompt = PROMPTS.find((p) => p.name === req.params.name);
    if (!prompt) throw new McpError(ErrorCode.InvalidParams, `unknown prompt: ${req.params.name}`);
    return {
      description: prompt.description,
      messages: [{ role: 'user' as const, content: { type: 'text' as const, text: prompt.template } }],
    };
  });

  return server;
}

/** MCP server for apex-app-harness (local / stdio). */
export async function start(): Promise<void> {
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // stdout belongs to the protocol — diagnostics go to stderr only.
  console.error(
    `[${SERVER_NAME}] MCP server ready —`,
    TOOLS.length, 'tools,', RESOURCES.length, 'resources,', PROMPTS.length, 'prompts',
  );
}
