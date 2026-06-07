import { createSdkMcpServer, query, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import { execFile, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import readline from 'node:readline';

const execFileAsync = promisify(execFile);

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

let queue = [];
let waiters = [];
let activeQuery = null;
let current = {
  cwd: process.cwd(),
  model: undefined,
  permissionMode: 'default',
  resume: undefined,
  resumeSessionAt: undefined,
  sessionId: undefined,
  env: process.env,
  settings: undefined,
};
const pendingPermissions = new Map();
const pendingUserInputs = new Map();
const SUPPORTED_IMAGE_MIME_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
]);

function emit(object) {
  process.stdout.write(JSON.stringify(object) + '\n');
}

function bridgeUserInputRequest(request) {
  const requestId = request.elicitationId || request.id || request.request_id || `elicitation-${Date.now()}`;
  emit({
    type: 'user_input_request',
    request_id: requestId,
    prompt: request.message || request.prompt || request.question || 'Input required',
    title: request.title,
    description: request.description,
    requested_schema: request.requestedSchema,
  });
  return new Promise((resolve) => {
    pendingUserInputs.set(requestId, resolve);
  });
}

function isExitPlanMode(toolName) {
  return String(toolName || '').replace(/[_-]/g, '').toLowerCase() === 'exitplanmode';
}

function emitPlanToolUse(toolName, input, toolUseID) {
  const requestId = toolUseID || `plan-${Date.now()}`;
  emit({
    type: 'assistant',
    message: {
      id: requestId,
      content: [{
        type: 'tool_use',
        id: requestId,
        name: toolName || 'ExitPlanMode',
        input: input || {},
      }],
    },
    session_id: current.sessionId,
  });
}

function attachmentBlock(attachment) {
  const path = attachment.path || attachment.file_path;
  if (!path) return null;
  const mimeType = attachment.mime_type || attachment.mimeType || '';
  const kind = attachment.kind || '';
  if (kind === 'image' || mimeType.startsWith('image/')) {
    if (!SUPPORTED_IMAGE_MIME_TYPES.has(mimeType)) {
      throw new Error(`Unsupported Claude image attachment type: ${mimeType || 'unknown'}`);
    }
    return {
      type: 'image',
      source: {
        type: 'base64',
        media_type: mimeType,
        data: fs.readFileSync(path).toString('base64'),
      },
    };
  }
  return {
    type: 'text',
    text: `[Attachment: ${attachment.display_name || attachment.displayName || path}]\n${path}`,
  };
}

function pushPrompt(text, attachments = []) {
  const content = [{ type: 'text', text }];
  for (const attachment of attachments) {
    const block = attachmentBlock(attachment);
    if (block) content.push(block);
  }
  const message = {
    type: 'user',
    message: {
      role: 'user',
      content,
    },
    parent_tool_use_id: null,
  };
  const waiter = waiters.shift();
  if (waiter) {
    waiter({ value: message, done: false });
  } else {
    queue.push(message);
  }
}

async function* promptStream() {
  while (true) {
    if (queue.length > 0) {
      yield queue.shift();
      continue;
    }
    const next = await new Promise((resolve) => waiters.push(resolve));
    if (next.done) return;
    yield next.value;
  }
}

function sdkPermissionMode(mode, interactionMode) {
  if (interactionMode === 'plan') return 'plan';
  switch (mode) {
    case 'auto_accept_edits': return 'acceptEdits';
    case 'full_access': return 'bypassPermissions';
    case 'supervised':
    default: return 'default';
  }
}

function ensureQuery() {
  if (activeQuery) return activeQuery;
  const mcpServers = e2eUserInputMcpServers();
  activeQuery = query({
    prompt: promptStream(),
    options: {
      cwd: current.cwd,
      model: current.model,
      resume: current.resume,
      resumeSessionAt: current.resumeSessionAt,
      sessionId: current.resume ? undefined : current.sessionId,
      permissionMode: current.permissionMode,
      tools: { type: 'preset', preset: 'claude_code' },
      mcpServers,
      settings: current.settings,
      // Load filesystem settings so the SDK discovers Agent Skills (e.g. the managed
      // /distill skill in ~/.claude/skills and project .claude/skills). Without this the
      // SDK can run in isolation mode and load no skills at all. Trade-off: this also
      // loads the user's CLAUDE.md, settings.json, and hooks into the session.
      settingSources: ['user', 'project'],
      allowDangerouslySkipPermissions: current.permissionMode === 'bypassPermissions',
      env: current.env,
      // Partial assistant snapshots can contain evolving thinking blocks. Replaying
      // those snapshots into the next Anthropic request can trip the API's
      // "thinking blocks must remain unchanged" validation.
      includePartialMessages: false,
      includeHookEvents: true,
      canUseTool: async (toolName, input, options) => {
        const requestId = options.toolUseID || `permission-${Date.now()}`;
        if (current.permissionMode === 'plan' && isExitPlanMode(toolName)) {
          emitPlanToolUse(toolName, input, requestId);
          return {
            behavior: 'deny',
            message: 'RemoteCode captured the proposed plan. Stop now and wait for the user to approve implementation.',
            interrupt: true,
            toolUseID: requestId,
          };
        }
        emit({
          type: 'permission_request',
          request_id: requestId,
          tool_name: toolName,
          tool_input: input,
          title: options.title,
          description: options.description,
          display_name: options.displayName,
        });
        return await new Promise((resolve) => {
          pendingPermissions.set(requestId, resolve);
        });
      },
      onElicitation: async (request) => {
        return await bridgeUserInputRequest(request);
      },
    },
  });
  (async () => {
    try {
      for await (const message of activeQuery) {
        emit(message);
      }
    } catch (error) {
      emit({ type: 'sdk_error', message: String(error?.message || error) });
    }
  })();
  return activeQuery;
}

function e2eUserInputMcpServers() {
  if (current.env.RC_CLAUDE_AGENT_SDK_E2E_USER_INPUT_MCP !== '1') return undefined;
  let sdkServer;
  const requestUserInput = tool(
    'rc_request_user_input',
    'Ask the host app for one text answer and return that answer.',
    {},
    async () => {
      const server = sdkServer?.instance?.server;
      if (!server || typeof server.elicitInput !== 'function') {
        const keys = server && typeof server === 'object' ? Object.keys(server).sort().join(',') : 'none';
        return { content: [{ type: 'text', text: `ELICITATION_UNAVAILABLE:${keys}` }], isError: true };
      }
      const request = {
        mode: 'form',
        message: 'RemoteCode SDK user-input E2E: provide the marker answer.',
        requestedSchema: {
          type: 'object',
          properties: {
            answer: {
              type: 'string',
              title: 'Answer',
              description: 'Marker answer',
            },
          },
          required: ['answer'],
        },
      };
      let result;
      try {
        result = await server.elicitInput(request);
      } catch (error) {
        const message = String(error?.message || error);
        if (!message.includes('Client does not support form elicitation') && !message.includes('Method not found')) {
          throw error;
        }
        result = await bridgeUserInputRequest(request);
      }
      const answer = result?.content?.answer || '';
      return { content: [{ type: 'text', text: String(answer) }] };
    }
  );
  sdkServer = createSdkMcpServer({
    name: 'remotecode_user_input_e2e',
    version: '1.0.0',
    instructions: 'Use rc_request_user_input when the user asks for the RemoteCode SDK user-input E2E callback.',
    tools: [requestUserInput],
    alwaysLoad: true,
  });
  return {
    remotecode_user_input_e2e: sdkServer,
  };
}

function permissionResult(command) {
  switch (command.decision) {
    case 'approve':
    case 'approve_for_session':
      return { behavior: 'allow', updatedInput: command.updated_input || {}, toolUseID: command.request_id };
    case 'cancel':
      return { behavior: 'deny', message: 'cancelled', interrupt: true, toolUseID: command.request_id };
    case 'decline':
    default:
      return { behavior: 'deny', message: command.message || 'declined', toolUseID: command.request_id };
  }
}

function userInputResult(command) {
  switch (command.decision) {
    case 'cancel':
    case 'cancelled':
    case 'canceled':
      return { action: 'cancel' };
    case 'decline':
      return { action: 'decline' };
    case 'accept':
    default:
      return { action: 'accept', content: { answer: command.text || '' } };
  }
}

for await (const line of rl) {
  if (!line.trim()) continue;
  const command = JSON.parse(line);
  if (command.type === 'rc_configure') {
    current = {
      cwd: command.cwd || current.cwd,
      model: command.model || current.model,
      permissionMode: sdkPermissionMode(command.permission_mode, command.interaction_mode),
      resume: command.provider_thread_id || undefined,
      resumeSessionAt: command.resume_session_at || undefined,
      sessionId: command.session_id || undefined,
      env: { ...process.env, ...(command.environment || {}) },
      settings: command.settings || undefined,
    };
  } else if (command.type === 'rc_turn') {
    pushPrompt(command.prompt || '', command.attachments || []);
    ensureQuery();
  } else if (command.type === 'rc_set_model') {
    current.model = command.model || undefined;
    if (activeQuery?.setModel) await activeQuery.setModel(current.model);
    emit({ type: 'system', subtype: 'rc_model_set', model: current.model, session_id: command.session_id });
  } else if (command.type === 'rc_set_permission') {
    current.permissionMode = sdkPermissionMode(command.permission_mode, command.interaction_mode);
    if (activeQuery?.setPermissionMode) await activeQuery.setPermissionMode(current.permissionMode);
    emit({ type: 'system', subtype: 'rc_permission_set', permissionMode: current.permissionMode, session_id: command.session_id });
  } else if (command.type === 'permission_response') {
    const resolver = pendingPermissions.get(command.request_id);
    if (resolver) {
      pendingPermissions.delete(command.request_id);
      resolver(permissionResult(command));
    }
  } else if (command.type === 'user_input_response') {
    const resolver = pendingUserInputs.get(command.request_id);
    if (resolver) {
      pendingUserInputs.delete(command.request_id);
      resolver(userInputResult(command));
    }
  } else if (command.type === 'rc_interrupt') {
    if (activeQuery?.interrupt) await activeQuery.interrupt();
  } else if (command.type === 'rc_close') {
    if (activeQuery?.close) activeQuery.close();
    process.exit(0);
  }
}
