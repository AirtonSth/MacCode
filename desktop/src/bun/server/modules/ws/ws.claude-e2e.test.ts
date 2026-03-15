import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { createEdenClient, createEdenWsClient } from "../../eden-client";
import { createTestServer } from "../../shared/core/test-server";

interface ClaudeAvailability {
	available: boolean;
	reason: string;
}

const getClaudeAvailability = (): ClaudeAvailability => {
	try {
		const result = Bun.spawnSync({
			cmd: ["claude", "--version"],
			stderr: "pipe",
			stdout: "pipe",
		});

		if ((result.exitCode ?? 1) !== 0) {
			return { available: false, reason: "claude CLI not found" };
		}

		return { available: true, reason: "" };
	} catch {
		return { available: false, reason: "claude CLI not available" };
	}
};

type ServerEvent =
	| {
			data: {
				chatId: string;
				delta?: string;
				diffAdded?: number;
				diffRemoved?: number;
				status?: "pending" | "running" | "completed" | "failed";
				code?: string;
				message?: string;
				event?: unknown;
				eventId?: number;
			};
			event: "assistant_delta" | "assistant_done" | "assistant_event" | "chat_updated" | "error";
	  };

const parseEvent = (raw: unknown): ServerEvent | null => {
	if (typeof raw === "string") {
		try {
			return parseEvent(JSON.parse(raw));
		} catch {
			return null;
		}
	}

	if (!raw || typeof raw !== "object") {
		return null;
	}

	const asOuter = raw as { data?: unknown; event?: unknown };
	if (typeof asOuter.event === "string" && asOuter.data && typeof asOuter.data === "object") {
		return {
			data: asOuter.data as ServerEvent["data"],
			event: asOuter.event as ServerEvent["event"],
		};
	}

	if (!asOuter.data || typeof asOuter.data !== "object") {
		return null;
	}

	const nested = asOuter.data as { data?: unknown; event?: unknown };
	if (typeof nested.event !== "string" || !nested.data || typeof nested.data !== "object") {
		return null;
	}

	return {
		data: nested.data as ServerEvent["data"],
		event: nested.event as ServerEvent["event"],
	};
};

const waitForCondition = async (
	predicate: () => boolean,
	timeoutMs = 60_000,
	label = "ws condition",
): Promise<void> => {
	await new Promise<void>((resolve, reject) => {
		const startedAt = performance.now();
		const timer = setInterval(() => {
			if (predicate()) {
				clearInterval(timer);
				resolve();
				return;
			}

			if (performance.now() - startedAt >= timeoutMs) {
				clearInterval(timer);
				reject(new Error(`timed out waiting for ${label}`));
			}
		}, 25);
	});
};

const claudeAvailability = getClaudeAvailability();
const claudeTest = test.skipIf(!claudeAvailability.available);
const skipReasonSuffix = claudeAvailability.available ? "" : ` (skip: ${claudeAvailability.reason})`;

claudeTest(`Claude provider e2e: sends message, receives streaming events, creates assistant message in DB${skipReasonSuffix}`, async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-claude-flow-"));
	const { baseUrl, cleanup, client } = await createTestServer();

	let ws: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({
			title: "claude-e2e",
			provider: "claude",
		});
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		ws = await createEdenWsClient(createEdenClient({ baseUrl }));
		const events: ServerEvent[] = [];

		ws.subscribe((raw: unknown) => {
			const event = parseEvent((raw as { data: unknown }).data);
			if (!event || event.data.chatId !== chatId) {
				return;
			}
			events.push(event);
		});

		ws.send({
			data: {
				chatId,
				permissionMode: "full",
				model: "claude-haiku-4-5-20251001",
				text: "Reply with exactly: claude-e2e-ok",
			},
			event: "user_message",
		});

		await waitForCondition(
			() =>
				(events.some((event) => event.event === "assistant_done") &&
					events.some((event) => event.event === "chat_updated" && event.data.status === "completed")) ||
				events.some((event) => event.event === "error"),
			120_000,
			"claude assistant_done or error",
		);

		// Check for errors
		const providerError = events.find((event) => event.event === "error");
		if (providerError) {
			console.error("[claude-e2e] ERROR:", JSON.stringify(providerError.data));
		}
		expect(providerError).toBeUndefined();

		// Verify event sequence
		const runningIndex = events.findIndex(
			(event) => event.event === "chat_updated" && event.data.status === "running",
		);
		const doneIndex = events.findIndex((event) => event.event === "assistant_done");
		const completedIndex = events.findIndex(
			(event) => event.event === "chat_updated" && event.data.status === "completed",
		);

		expect(runningIndex).toBeGreaterThanOrEqual(0);
		expect(doneIndex).toBeGreaterThan(runningIndex);
		expect(completedIndex).toBeGreaterThan(doneIndex);

		// Verify streaming deltas were received
		const deltas = events
			.filter((event) => event.event === "assistant_delta")
			.map((event) => event.data.delta ?? "");
		expect(deltas.length).toBeGreaterThan(0);

		// Verify structured streaming events were received
		const assistantEvents = events.filter((event) => event.event === "assistant_event");
		expect(assistantEvents.length).toBeGreaterThan(0);

		// Verify the assistant message is persisted in DB
		const messages = await client.v1.chats({ id: chatId }).messages.get();
		const storedMessages = (messages.data as { messages: { content: string; role: "user" | "assistant" }[] })
			.messages;

		expect(storedMessages).toHaveLength(2);
		const userMessage = storedMessages.find((item) => item.role === "user");
		const assistantMessage = storedMessages.find((item) => item.role === "assistant");

		expect(userMessage?.content).toBe("Reply with exactly: claude-e2e-ok");
		expect(assistantMessage).toBeDefined();
		expect(assistantMessage!.content.toLowerCase()).toContain("claude-e2e-ok");
	} finally {
		ws?.close();
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 180_000);
