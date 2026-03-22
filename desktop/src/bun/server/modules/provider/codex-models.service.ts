import {
	type CodexModelDescriptor,
	type CodexModelsCatalog,
	parseCodexReasoningEffort,
} from "../../../../shared/codex-model-config";
import { killProcess, resolveCommand } from "../../platform/index";

interface CodexAppServerResult {
	exitCode: number | null;
	stderr: string;
	stdout: string;
}

interface CodexAppServerListResponse {
	id?: unknown;
	result?: unknown;
}

interface CodexAppServerModelListResult {
	data?: unknown;
	nextCursor?: unknown;
}

type ExecuteCodexAppServer = (timeoutMs: number) => Promise<CodexAppServerResult>;

interface CodexModelsCacheEntry {
	cachedAtMs: number;
	value: CodexModelsCatalog;
}

const MODEL_LIST_REQUEST_ID = 2;
const DEFAULT_FETCH_TIMEOUT_MS = 20_000;
const DEFAULT_CACHE_TTL_MS = 60_000;

const isObject = (value: unknown): value is Record<string, unknown> =>
	typeof value === "object" && value !== null;

const readNonEmptyString = (value: unknown): string | null => {
	if (typeof value !== "string") {
		return null;
	}

	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : null;
};

const readReasoningOptions = (value: unknown) => {
	if (!Array.isArray(value)) {
		return [];
	}

	const options: CodexModelDescriptor["supportedReasoningEfforts"] = [];

	for (const entry of value) {
		if (!isObject(entry)) {
			continue;
		}

		const reasoningEffort = parseCodexReasoningEffort(entry.reasoningEffort);
		if (!reasoningEffort) {
			continue;
		}

		const description = typeof entry.description === "string" ? entry.description : "";
		options.push({
			description,
			reasoningEffort,
		});
	}

	return options;
};

const normalizeModel = (value: unknown): CodexModelDescriptor | null => {
	if (!isObject(value)) {
		return null;
	}

	const id = readNonEmptyString(value.id);
	const model = readNonEmptyString(value.model);
	const displayName = readNonEmptyString(value.displayName);
	const description = typeof value.description === "string" ? value.description : "";
	const defaultReasoningEffort = parseCodexReasoningEffort(value.defaultReasoningEffort);
	const supportedReasoningEfforts = readReasoningOptions(value.supportedReasoningEfforts);
	const isDefault = value.isDefault === true;

	if (!id || !model || !displayName || !defaultReasoningEffort || supportedReasoningEfforts.length === 0) {
		return null;
	}

	return {
		defaultReasoningEffort,
		description,
		displayName,
		id,
		isDefault,
		model,
		supportedReasoningEfforts,
	};
};

const parseResponseLine = (line: string): CodexAppServerListResponse | null => {
	const trimmed = line.trim();
	if (!trimmed) {
		return null;
	}

	try {
		return JSON.parse(trimmed) as CodexAppServerListResponse;
	} catch {
		return null;
	}
};

const parseModelListResult = (value: unknown): CodexModelsCatalog => {
	if (!isObject(value)) {
		return {
			models: [],
			nextCursor: null,
		};
	}

	const list = value as CodexAppServerModelListResult;
	const models = Array.isArray(list.data) ? list.data.map(normalizeModel).filter((entry) => entry !== null) : [];
	const nextCursor = typeof list.nextCursor === "string" ? list.nextCursor : null;

	return {
		models,
		nextCursor,
	};
};

const buildAppServerStdinPayload = (): string => {
	const initializePayload = {
		id: 1,
		jsonrpc: "2.0",
		method: "initialize",
		params: {
			capabilities: {
				experimentalApi: true,
			},
			clientInfo: {
				name: "remotecode",
				title: "RemoteCode",
				version: "1.0.0",
			},
		},
	};
	const modelListPayload = {
		id: MODEL_LIST_REQUEST_ID,
		jsonrpc: "2.0",
		method: "model/list",
		params: {
			includeHidden: false,
		},
	};

	return [JSON.stringify(initializePayload), JSON.stringify(modelListPayload), ""].join("\n");
};

const readStreamText = async (stream: ReadableStream<Uint8Array> | null): Promise<string> => {
	if (!stream) {
		return "";
	}

	return await new Response(stream).text();
};

const readStdoutUntilModelListResponse = async (
	stream: ReadableStream<Uint8Array> | null,
): Promise<string> => {
	if (!stream) {
		throw new Error("codex app-server did not provide stdout stream");
	}

	const reader = stream.getReader();
	const decoder = new TextDecoder();
	let buffer = "";
	let collected = "";

	while (true) {
		const { done, value } = await reader.read();
		if (done) {
			break;
		}

		const chunk = decoder.decode(value, { stream: true });
		collected += chunk;
		buffer += chunk;

		const lines = buffer.split("\n");
		buffer = lines.pop() ?? "";

		for (const line of lines) {
			const parsed = parseResponseLine(line);
			if (parsed?.id === MODEL_LIST_REQUEST_ID) {
				return collected;
			}
		}
	}

	const flushChunk = decoder.decode();
	if (flushChunk) {
		collected += flushChunk;
		buffer += flushChunk;
	}

	const lastLine = buffer.trim();
	if (lastLine) {
		const parsed = parseResponseLine(lastLine);
		if (parsed?.id === MODEL_LIST_REQUEST_ID) {
			return collected;
		}
	}

	throw new Error("codex model/list response was not found");
};

const defaultExecuteCodexAppServer: ExecuteCodexAppServer = async (timeoutMs: number) => {
	const codexCommand = resolveCommand("codex");
	const subprocess = Bun.spawn({
		cmd: [codexCommand, "app-server", "--listen", "stdio://"],
		env: process.env,
		stderr: "pipe",
		stdin: "pipe",
		stdout: "pipe",
	});
	const stderrPromise = readStreamText(subprocess.stderr);

	let timedOut = false;
	let completed = false;
	const timer = setTimeout(() => {
		timedOut = true;
		try {
			killProcess(subprocess, "force");
		} catch {
			// process may have already exited
		}
	}, timeoutMs);

	try {
		const stdinPayload = buildAppServerStdinPayload();
		subprocess.stdin.write(stdinPayload);
		const stdout = await readStdoutUntilModelListResponse(subprocess.stdout);
		completed = true;

		try {
			killProcess(subprocess, "graceful");
		} catch {
			// process may have already exited
		}
		await subprocess.exited.catch(() => null);
		const stderr = await stderrPromise;
		return {
			exitCode: 0,
			stderr,
			stdout,
		};
	} catch (error) {
		try {
			killProcess(subprocess, "force");
		} catch {
			// process may have already exited
		}

		const [stderr, exitCode] = await Promise.all([stderrPromise, subprocess.exited.catch(() => null)]);

		const errorMessage = error instanceof Error ? error.message : "failed to load codex model list";
		return {
			exitCode: timedOut ? null : exitCode,
			stderr: stderr.trim() || errorMessage,
			stdout: "",
		};
	} finally {
		clearTimeout(timer);
		if (!completed) {
			try {
				subprocess.stdin.end();
			} catch {
				// stream may already be closed
			}
		}
	}
};

export class CodexModelsServiceError extends Error {
	readonly statusCode: number;

	constructor(message: string, statusCode: number) {
		super(message);
		this.name = "CodexModelsServiceError";
		this.statusCode = statusCode;
	}
}

export class CodexModelsService {
	private cache: CodexModelsCacheEntry | null = null;

	constructor(
		private readonly executeCodexAppServer: ExecuteCodexAppServer = defaultExecuteCodexAppServer,
		private readonly cacheTtlMs = DEFAULT_CACHE_TTL_MS,
		private readonly timeoutMs = DEFAULT_FETCH_TIMEOUT_MS,
		private readonly now = () => Date.now(),
	) {}

	private hasFreshCache(): boolean {
		if (!this.cache) {
			return false;
		}

		return this.now() - this.cache.cachedAtMs < this.cacheTtlMs;
	}

	private setCache(value: CodexModelsCatalog): void {
		this.cache = {
			cachedAtMs: this.now(),
			value,
		};
	}

	private parseModelListFromStdout(stdout: string): CodexModelsCatalog {
		for (const line of stdout.split("\n")) {
			const parsed = parseResponseLine(line);
			if (!parsed || parsed.id !== MODEL_LIST_REQUEST_ID) {
				continue;
			}

			if ("result" in parsed) {
				return parseModelListResult(parsed.result);
			}

			throw new CodexModelsServiceError("codex model/list request failed", 503);
		}

		throw new CodexModelsServiceError("codex model/list response was not found", 503);
	}

	async getModelsCatalog(): Promise<CodexModelsCatalog> {
		if (this.hasFreshCache()) {
			return this.cache!.value;
		}

		try {
			const response = await this.executeCodexAppServer(this.timeoutMs);
			if (response.exitCode !== 0) {
				throw new CodexModelsServiceError(
					response.stderr.trim() || `codex app-server exited with code ${String(response.exitCode)}`,
					503,
				);
			}

			const parsed = this.parseModelListFromStdout(response.stdout);
			this.setCache(parsed);
			return parsed;
		} catch (error) {
			if (this.cache) {
				return this.cache.value;
			}

			if (error instanceof CodexModelsServiceError) {
				throw error;
			}

			throw new CodexModelsServiceError(
				error instanceof Error ? error.message : "failed to load codex model list",
				503,
			);
		}
	}
}
