import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { FakeProviderResult, FakeProviderRunOptions } from "../../shared/core/server.types";

const providerPath = join(
	dirname(fileURLToPath(import.meta.url)),
	"..",
	"..",
	"..",
	"providers",
	"fake-codex-provider.mjs",
);

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
		if (!existsSync(providerPath)) {
			return {
				assistantText: "",
				diffAdded: 0,
				diffRemoved: 0,
				error: "fake provider missing",
				status: "failed",
			};
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

		const proc = Bun.spawn({
			cmd: command,
			stderr: "pipe",
			stdout: "pipe",
		});

		const decoder = new TextDecoder();

		let assistantText = "";
		let diffAdded = 0;
		let diffRemoved = 0;
		let hasFailure = false;
		let failureMessage: string | undefined;

		let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;

		try {
			if (proc.stdout) {
				const out = proc.stdout as ReadableStream<Uint8Array>;

				reader = out.getReader();

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

			if (proc.stderr) {
				const stderr = await new Response(proc.stderr).text();

				if (stderr && !hasFailure) {
					hasFailure = true;
					failureMessage = stderr.trim();
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

			if (proc.stdout) {
				try {
					proc.stdout.cancel();
				} catch {
					// no-op on best-effort cleanup
				}
			}

			if (proc.stderr) {
				try {
					proc.stderr.cancel();
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
