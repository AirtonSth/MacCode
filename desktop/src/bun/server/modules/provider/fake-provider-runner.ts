import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { FakeProviderResult, FakeProviderRunOptions } from "../../shared/core/server.types";

const fakeProviderFile = "fake-codex-provider.mjs";

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

const chunkText = (value: string, size = 20): string[] => {
	const chunks: string[] = [];

	for (let index = 0; index < value.length; index += size) {
		chunks.push(value.slice(index, index + size));
	}

	return chunks;
};

const resolveFakeProviderPath = (): string | null => {
	const moduleDir = dirname(fileURLToPath(import.meta.url));
	const cwd = process.cwd();
	const candidateBases = new Set<string>([moduleDir, cwd]);
	let moduleCursor = moduleDir;
	let cwdCursor = cwd;

	for (let index = 0; index < 5; index += 1) {
		const next = dirname(moduleCursor);

		if (next === moduleCursor) {
			break;
		}

		candidateBases.add(next);
		moduleCursor = next;
	}

	for (let index = 0; index < 5; index += 1) {
		const next = dirname(cwdCursor);

		if (next === cwdCursor) {
			break;
		}

		candidateBases.add(next);
		cwdCursor = next;
	}

	const candidates = Array.from(candidateBases).flatMap((base) => [
		join(base, "src", "bun", "providers", fakeProviderFile),
		join(base, "providers", fakeProviderFile),
	]);

	return candidates.find(existsSync) ?? null;
};

const runFallbackFakeProvider = async ({
	onDelta,
	text,
}: Pick<FakeProviderRunOptions, "onDelta" | "text">): Promise<FakeProviderResult> => {
	const assistantText = `Echo: ${text}`;

	for (const chunk of chunkText(assistantText)) {
		await sleep(10);
		onDelta(chunk);
	}

	return {
		assistantText,
		diffAdded: assistantText.length,
		diffRemoved: Math.max(0, assistantText.length - 1),
		status: "completed",
	};
};

interface ProviderEventMap {
	delta?: unknown;
	diffAdded?: number;
	diffRemoved?: number;
	error?: string;
	item?: {
		content?: unknown;
		delta?: unknown;
		text?: unknown;
		type?: string;
	};
	message?: string;
	text?: unknown;
	type:
		| "item.delta"
		| "turn.completed"
		| "item.completed"
		| "process.failed"
		| "thread.started"
		| "turn.started"
		| "item.started"
		| string;
	usage?: {
		diff?: {
			added?: number;
			removed?: number;
		};
	};
}

const extractString = (...values: unknown[]): string | null => {
	for (const value of values) {
		if (typeof value === "string" && value.length > 0) {
			return value;
		}
	}

	return null;
};

const extractDiffFromPayload = (
	payload: ProviderEventMap,
): { diffAdded: number; diffRemoved: number } | null => {
	if (typeof payload.diffAdded === "number" && typeof payload.diffRemoved === "number") {
		return {
			diffAdded: payload.diffAdded,
			diffRemoved: payload.diffRemoved,
		};
	}

	const { usage } = payload;

	if (usage?.diff) {
		const diffAdded = typeof usage.diff.added === "number" ? usage.diff.added : undefined;
		const diffRemoved = typeof usage.diff.removed === "number" ? usage.diff.removed : undefined;

		if (diffAdded !== undefined && diffRemoved !== undefined) {
			return {
				diffAdded,
				diffRemoved,
			};
		}
	}

	return null;
};

const emitEventFromLine = (line: string, onDelta: (delta: string) => void): FakeProviderResult | null => {
	const trimmed = line.trim();

	if (!trimmed) {
		return null;
	}

	let payload: ProviderEventMap;

	try {
		payload = JSON.parse(trimmed) as ProviderEventMap;
	} catch {
		return null;
	}

	if (payload.type === "item.delta") {
		const item = payload.item as { [key: string]: unknown } | undefined;
		const delta = extractString(payload.delta, item?.delta, payload.text, item?.text);

		if (delta) {
			onDelta(delta);
		}
	}

	if (payload.type === "turn.completed") {
		const diff = extractDiffFromPayload(payload);
		const diffAdded = diff?.diffAdded ?? 0;
		const diffRemoved = diff?.diffRemoved ?? 0;

		return {
			assistantText: "",
			diffAdded,
			diffRemoved,
			status: "completed",
		};
	}

	if (payload.type === "item.completed") {
		const { item } = payload;
		const text = extractString(payload.text, item?.text);

		if (text && item?.type === "assistant_message") {
			return {
				assistantText: text,
				diffAdded: 0,
				diffRemoved: 0,
				status: "completed",
			};
		}
	}

	if (payload.type === "process.failed") {
		const message =
			extractString(payload.message, (payload as { error?: string }).error) || "provider failed";

		return {
			assistantText: "",
			diffAdded: 0,
			diffRemoved: 0,
			error: message,
			status: "failed",
		};
	}

	return null;
};

export const FakeProviderRunner = {
	async run({ chatId, onDelta, text }: FakeProviderRunOptions): Promise<FakeProviderResult> {
		const providerPath = resolveFakeProviderPath();

		if (!providerPath) {
			return runFallbackFakeProvider({ onDelta, text });
		}

		const command = [
			"node",
			providerPath,
			"--chat-id",
			chatId,
			"--text",
			text,
			...(process.env.REMOTECODE_FAKE_PROVIDER_FORCE_FAIL === "1" ? ["--fail"] : []),
		];

		let proc: ReturnType<typeof Bun.spawn> | undefined;

		try {
			proc = Bun.spawn({
				cmd: command,
				stderr: "pipe",
				stdout: "pipe",
			});
		} catch (error) {
			return {
				assistantText: "",
				diffAdded: 0,
				diffRemoved: 0,
				error: `fake provider failed to start: ${error instanceof Error ? error.message : "unknown"}`,
				status: "failed",
			};
		}

		if (!proc) {
			return {
				assistantText: "",
				diffAdded: 0,
				diffRemoved: 0,
				error: "fake provider failed to start",
				status: "failed",
			};
		}

			const decoder = new TextDecoder();
			const stdout = proc.stdout instanceof ReadableStream ? proc.stdout : null;
			const stderr = proc.stderr instanceof ReadableStream ? proc.stderr : null;

		let assistantText = "";
		let diffAdded = 0;
		let diffRemoved = 0;
		let hasFailure = false;
		let failureMessage: string | undefined;

		let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;

		try {
				if (stdout) {
					reader = stdout.getReader();

				let pending = "";

				while (true) {
					const { done, value } = await reader.read();

					if (done) {
						break;
					}

					pending += decoder.decode(value);

					const lines = pending.split("\n");

					pending = lines.pop() ?? "";

					for (const line of lines) {
						const event = emitEventFromLine(line, (delta) => {
							assistantText += delta;
							onDelta(delta);
						});

						if (!event) {
							continue;
						}

						if (event.status === "failed") {
							hasFailure = true;
							failureMessage = event.error;
						}

						if (event.status === "completed" && event.assistantText) {
							assistantText = event.assistantText;
						}

						if (event.diffAdded !== 0) {
							diffAdded = event.diffAdded;
						}

						if (event.diffRemoved !== 0) {
							diffRemoved = event.diffRemoved;
						}
					}
				}
			}

				if (stderr) {
					const stderrText = await new Response(stderr).text();

					if (stderrText && !hasFailure) {
						hasFailure = true;
						failureMessage = stderrText.trim();
					}
				}

			await proc.exited;
		} finally {
			if (reader) {
				try {
					reader.releaseLock();
				} catch {
					// no-op: best-effort cleanup
				}
			}

				if (stdout) {
					try {
						await stdout.cancel();
					} catch {
						// no-op on best-effort cleanup
					}
				}

				if (stderr) {
					try {
						await stderr.cancel();
					} catch {
						// no-op on best-effort cleanup
					}
				}
		}

		if (proc.exitCode !== 0 || hasFailure) {
			return {
				assistantText,
				diffAdded,
				diffRemoved,
				error: failureMessage || `provider process failed with code ${proc.exitCode}`,
				status: "failed",
			};
		}

		if (!assistantText) {
			return {
				assistantText: "",
				diffAdded,
				diffRemoved,
				error: "provider produced empty response",
				status: "failed",
			};
		}

		return {
			assistantText,
			diffAdded,
			diffRemoved,
			status: "completed",
		};
	},
};

export const runFakeProvider = async (options: FakeProviderRunOptions): Promise<FakeProviderResult> =>
	await FakeProviderRunner.run(options);
