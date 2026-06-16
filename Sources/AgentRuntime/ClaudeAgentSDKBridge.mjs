import { createSdkMcpServer, query, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import { execFile, execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
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
// AskUserQuestion arrives through canUseTool (even in bypassPermissions). We hold
// the canUseTool resolver here, surface the questions as a user_input_request, and
// resolve with { behavior: 'allow', updatedInput: { answers } } once answered.
const pendingAskUserQuestions = new Map();
const SUPPORTED_IMAGE_MIME_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
]);
// Compress tool output once it exceeds ~1KB OR ~10 lines, matching the distill
// policy the agent is told to follow (compress >~1KB or >~10 lines). The skip
// guard below uses AND so output is compressed when EITHER threshold is exceeded.
const TOKEN_SAVER_MIN_BYTES = 1024;
const TOKEN_SAVER_MIN_LINES = 10;
const TOKEN_SAVER_STORE_MIN_BYTES = 2048;
const TOKEN_SAVER_HOOK_TIMEOUT_MS = 1000;
// Exact-byte tools are the ONLY carve-out: distilling file content / edit echoes
// would break the agent's verbatim edits (the distill policy itself says "skip
// when you need the exact bytes"). Every OTHER tool is compressed (no allowlist).
const TOKEN_SAVER_EXCLUDED_TOOLS = new Set(['read', 'edit', 'write', 'multiedit', 'notebookedit']);
// Per-tool compression contracts. Tools not listed here fall back to
// TOKEN_SAVER_DEFAULT_PROFILE — i.e. EVERY non-excluded tool is distilled.
const TOKEN_SAVER_DEFAULT_PROFILE = 'moderate';
const TOKEN_SAVER_PROFILES = new Map([
  ['grep', 'conservative'],
  ['glob', 'conservative'],
  ['bash', 'moderate'],
  ['webfetch', 'aggressive'],
]);

function emit(object) {
  process.stdout.write(JSON.stringify(object) + '\n');
}

function normalizeToolName(toolName) {
  return String(toolName || '').trim().replace(/[-_]/g, '').toLowerCase();
}

function lineCount(text) {
  return String(text || '').split('\n').length;
}

function extractToolOutputText(value) {
  if (value == null) return '';
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    return value.map(extractToolOutputText).filter(Boolean).join('\n');
  }
  if (typeof value !== 'object') return String(value);
  if (Array.isArray(value.content)) return extractToolOutputText(value.content);
  for (const key of ['text', 'output', 'stdout', 'stderr', 'result']) {
    if (typeof value[key] === 'string') return value[key];
  }
  return '';
}

function replaceToolOutputText(value, text) {
  if (typeof value === 'string') return text;
  if (Array.isArray(value)) return [{ type: 'text', text }];
  if (value && typeof value === 'object') {
    if (Array.isArray(value.content)) return { ...value, content: [{ type: 'text', text }] };
    for (const key of ['text', 'output', 'stdout', 'stderr', 'result']) {
      if (typeof value[key] === 'string') return { ...value, [key]: text };
    }
  }
  return text;
}

function tokenSaverToolDecision(toolName, output) {
  const normalized = normalizeToolName(toolName);
  // Every tool compresses (no allowlist); only the exact-byte tools and
  // sub-threshold output are skipped.
  const profile = TOKEN_SAVER_PROFILES.get(normalized) || TOKEN_SAVER_DEFAULT_PROFILE;
  let skipReason = null;
  if (TOKEN_SAVER_EXCLUDED_TOOLS.has(normalized)) skipReason = 'excluded_tool';
  else if (Buffer.byteLength(output || '', 'utf8') <= TOKEN_SAVER_MIN_BYTES && lineCount(output) <= TOKEN_SAVER_MIN_LINES) skipReason = 'below_threshold';
  return { profile, shouldCompress: skipReason == null, skipReason };
}

function tokenSaverContractQuestion(toolName, toolInput, profile) {
  const args = summarizeToolInput(toolInput);
  const suffix = args ? ` Context: ${args}.` : '';
  if (profile === 'conservative') {
    return `Compress search output without dropping any match line. Preserve paths, line numbers, matched text, and quoted strings verbatim; only collapse duplicate/context noise.${suffix}`;
  }
  if (profile === 'moderate') {
    return `Compress command output. Preserve exit codes, failing test names, errors, warnings, assertions, numbers, paths, and quoted strings verbatim; collapse repeated progress noise.${suffix}`;
  }
  if (profile === 'aggressive') {
    return `Compress fetched web content for the current task. Preserve URLs, titles, code, API signatures, numbers, and quoted strings verbatim; keep retrieve-worthy details explicit.${suffix}`;
  }
  // Default contract for any other tool: compress conservatively without dropping
  // anything the agent might need verbatim.
  return `Compress this tool output for the current task. Preserve errors, warnings, exit codes, identifiers, numbers, paths, and quoted strings verbatim; collapse only repeated or noise lines.${suffix}`;
}

function summarizeToolInput(toolInput) {
  if (!toolInput || typeof toolInput !== 'object') return '';
  const parts = [];
  for (const key of ['command', 'pattern', 'path', 'glob', 'url']) {
    if (typeof toolInput[key] === 'string' && toolInput[key].trim()) parts.push(`${key}=${toolInput[key].trim()}`);
  }
  return parts.join(' | ').slice(0, 500);
}

function loadTokenSaverState() {
  const override = current.env.REMOTE_CODE_DISTILL_STATE_PATH;
  const candidates = override ? [override] : [];
  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(fs.readFileSync(candidate, 'utf8'));
      if (parsed.base_url && parsed.auth_token) {
        return { baseURL: String(parsed.base_url), authToken: String(parsed.auth_token) };
      }
    } catch (_) {
      // fail open
    }
  }
  return null;
}

async function postTokenSaverDistill(state, body) {
  if (typeof fetch !== 'function') return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TOKEN_SAVER_HOOK_TIMEOUT_MS);
  try {
    const response = await fetch(`${state.baseURL}/v1/distill`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${state.authToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    if (!response.ok) return null;
    const decoded = await response.json();
    return typeof decoded.output === 'string' ? decoded.output : null;
  } catch (_) {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function tokenSaverPostToolUse(input) {
  if (current.env.RC_TOKEN_SAVER_POST_TOOL_USE !== '1') return {};
  if (!input || input.hook_event_name !== 'PostToolUse') return {};
  const rawOutput = extractToolOutputText(input.tool_response);
  const decision = tokenSaverToolDecision(input.tool_name, rawOutput);
  if (!decision.shouldCompress) return {};
  const state = loadTokenSaverState();
  if (!state) return {};
  const output = await postTokenSaverDistill(state, {
    // The sidecar's DistillRequest requires a UUID `id`; without it the POST is
    // rejected 400 and this hook fails open silently — recording zero Token Saver
    // savings for Claude. Always send one so tool-output distillation is counted.
    id: randomUUID(),
    mode: 'commandOutput',
    priority: 1,
    input: rawOutput,
    question: tokenSaverContractQuestion(input.tool_name, input.tool_input, decision.profile),
    provider: current.env.REMOTE_CODE_AGENT_PROVIDER || 'claude',
    recordSavings: true,
    runMode: 'optimize',
    maxOutputCharacters: Math.max(512, Math.min(rawOutput.length, 12000)),
    cacheState: 'tool_output_hooked',
    reversibleStoreMinBytes: TOKEN_SAVER_STORE_MIN_BYTES,
  });
  if (!output || output.length >= rawOutput.length) return {};
  return {
    continue: true,
    hookSpecificOutput: {
      hookEventName: 'PostToolUse',
      updatedMCPToolOutput: replaceToolOutputText(input.tool_response, output),
    },
  };
}

function tokenSaverHooks() {
  return {
    PostToolUse: [{
      matcher: '*',
      timeout: Math.ceil(TOKEN_SAVER_HOOK_TIMEOUT_MS / 1000),
      hooks: [tokenSaverPostToolUse],
    }],
  };
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

function isAskUserQuestion(toolName) {
  return normalizeToolName(toolName) === 'askuserquestion';
}

// Human-readable summary for the work log / accessibility. The host renders the
// structured `questions`, but a plain prompt keeps non-structured consumers sane.
function askUserQuestionPrompt(input) {
  const questions = (input && Array.isArray(input.questions)) ? input.questions : [];
  if (questions.length === 1) return questions[0].question || 'Claude needs your input';
  if (questions.length > 1) {
    return questions
      .map((q) => (q && q.header ? `${q.header}: ${q.question || ''}` : (q && q.question) || ''))
      .join('\n');
  }
  return 'Claude needs your input';
}

// Map the host's answer back into the canUseTool PermissionResult the SDK expects.
// Answers are keyed by question text; multi-select answers are comma-joined. A
// non-JSON answer is treated as a freeform `response` (the SDK's "Other" path).
// Cancellation is not handled here — it flows through drainPendingCallbacks on
// interrupt/close, which denies the pending tool.
function askUserQuestionResult(command, input) {
  const updatedInput = { ...(input || {}) };
  if (command.answers && typeof command.answers === 'object') {
    updatedInput.answers = command.answers;
  } else if (typeof command.text === 'string' && command.text.trim()) {
    try {
      const parsed = JSON.parse(command.text);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        updatedInput.answers = parsed;
      } else {
        updatedInput.response = command.text;
      }
    } catch {
      updatedInput.response = command.text;
    }
  } else {
    updatedInput.answers = {};
  }
  return { behavior: 'allow', updatedInput, toolUseID: command.request_id };
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
      hooks: tokenSaverHooks(),
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
        // AskUserQuestion is an interactive question, not a permission gate: route
        // it as a structured user_input_request (never an Approve/Decline card) and
        // return the user's choice as the canUseTool result. This also keeps it
        // working in bypassPermissions/full-access mode, where the SDK still calls
        // canUseTool for AskUserQuestion.
        if (isAskUserQuestion(toolName)) {
          emit({
            type: 'user_input_request',
            request_id: requestId,
            ask_user_question: true,
            prompt: askUserQuestionPrompt(input),
            questions: (input && input.questions) || [],
          });
          return await new Promise((resolve) => {
            pendingAskUserQuestions.set(requestId, { resolve, input: input || {} });
          });
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

// Resolve every in-flight callback promise (deny / cancel) so an interrupt or
// close cannot leave the SDK async generator awaiting a host answer forever.
function drainPendingCallbacks() {
  for (const [id, ask] of pendingAskUserQuestions) {
    ask.resolve({ behavior: 'deny', message: 'cancelled', interrupt: true, toolUseID: id });
  }
  pendingAskUserQuestions.clear();
  for (const [id, resolve] of pendingPermissions) {
    resolve({ behavior: 'deny', message: 'cancelled', interrupt: true, toolUseID: id });
  }
  pendingPermissions.clear();
  for (const [, resolve] of pendingUserInputs) {
    resolve({ action: 'cancel' });
  }
  pendingUserInputs.clear();
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

let pendingCommandText = '';

function recoverableCommandJSONError(error) {
  const message = String(error?.message || error);
  return message.includes('Unterminated string in JSON')
    || message.includes('Unexpected end of JSON input')
    || message.includes('Unexpected end of JSON');
}

function parseCommandLine(line) {
  const text = pendingCommandText ? `${pendingCommandText}\\n${line}` : line;
  try {
    const command = JSON.parse(text);
    pendingCommandText = '';
    return command;
  } catch (error) {
    if (recoverableCommandJSONError(error)) {
      pendingCommandText = text;
      return null;
    }
    pendingCommandText = '';
    emit({
      type: 'error',
      error: { message: `Invalid Claude SDK bridge command JSON: ${String(error?.message || error)}` },
    });
    return null;
  }
}

for await (const line of rl) {
  if (!line.trim() && !pendingCommandText) continue;
  const command = parseCommandLine(line);
  if (!command) continue;
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
    const ask = pendingAskUserQuestions.get(command.request_id);
    if (ask) {
      pendingAskUserQuestions.delete(command.request_id);
      ask.resolve(askUserQuestionResult(command, ask.input));
    } else {
      const resolver = pendingUserInputs.get(command.request_id);
      if (resolver) {
        pendingUserInputs.delete(command.request_id);
        resolver(userInputResult(command));
      }
    }
  } else if (command.type === 'rc_interrupt') {
    if (activeQuery?.interrupt) await activeQuery.interrupt();
    // Settle any in-flight callback promises so the SDK generator cannot hang
    // awaiting an answer/permission the user just interrupted.
    drainPendingCallbacks();
  } else if (command.type === 'rc_close') {
    drainPendingCallbacks();
    if (activeQuery?.close) activeQuery.close();
    process.exit(0);
  }
}

if (pendingCommandText) {
  emit({
    type: 'error',
    error: { message: 'Invalid Claude SDK bridge command JSON: input ended before the JSON command was complete' },
  });
}
