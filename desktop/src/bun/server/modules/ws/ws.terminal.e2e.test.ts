import { dirname, join } from "node:path";
import { mkdtempSync, realpathSync, renameSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";

import { Database } from "bun:sqlite";
import { expect, test } from "bun:test";

import { createEdenClient, createEdenWsClient } from "../../eden-client";
import { createTestServer } from "../../shared/core/test-server";
import { terminalSessionBridgeTestHarness } from "../terminal-session/terminal-session.service";

type TerminalServerEvent =
	| {
			data: {
				chatId: string;
				cols: number;
				cwd: string;
				exitCode: number | null;
				exitedAt: string | null;
				rows: number;
				seq: number;
				sessionId: string;
				shell: string;
				snapshot: string;
				startedAt: string;
				status: "running" | "exited";
			};
			event: "terminal_session_snapshot";
	  }
	| {
			data: {
				chatId: string;
				data: string;
				seq: number;
				sessionId: string;
			};
			event: "terminal_output";
	  }
	| {
			data: {
				chatId: string;
				code?: string;
				message?: string;
				status?: "running" | "exited";
				sessionId?: string;
			};
			event: "terminal_session_state" | "error";
	  };

const parseTerminalEvent = (raw: unknown): TerminalServerEvent | null => {
	if (typeof raw === "string") {
		try {
			return parseTerminalEvent(JSON.parse(raw));
		} catch {
			return null;
		}
	}

	if (!raw || typeof raw !== "object") {
		return null;
	}

	const outer = raw as { data?: unknown; event?: unknown };
	if (typeof outer.event === "string" && outer.data && typeof outer.data === "object") {
		return {
			data: outer.data as TerminalServerEvent["data"],
			event: outer.event as TerminalServerEvent["event"],
		} as TerminalServerEvent;
	}

	if (!outer.data || typeof outer.data !== "object") {
		return null;
	}

	const nested = outer.data as { data?: unknown; event?: unknown };
	if (typeof nested.event !== "string" || !nested.data || typeof nested.data !== "object") {
		return null;
	}

	return {
		data: nested.data as TerminalServerEvent["data"],
		event: nested.event as TerminalServerEvent["event"],
	} as TerminalServerEvent;
};

const waitForCondition = async (
	predicate: () => boolean,
	timeoutMs = 10_000,
	label = "terminal condition",
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

const collectTerminalText = (events: TerminalServerEvent[]): string =>
	events
		.filter((event): event is Extract<TerminalServerEvent, { event: "terminal_output" }> => event.event === "terminal_output")
		.map((event) => event.data.data)
		.join("");

const bindTerminalEvents = (
	socket: Awaited<ReturnType<typeof createEdenWsClient>>,
	chatId: string,
	events: TerminalServerEvent[],
): void => {
	socket.subscribe((raw: unknown) => {
		const event = parseTerminalEvent(
			raw && typeof raw === "object" && "data" in (raw as Record<string, unknown>)
				? (raw as { data?: unknown }).data
				: raw,
		);
		if (!event || event.data.chatId !== chatId) {
			return;
		}

		events.push(event);
	});
};

const waitForTerminalText = async (events: TerminalServerEvent[], text: string, timeoutMs = 10_000): Promise<void> => {
	await waitForCondition(() => collectTerminalText(events).includes(text), timeoutMs, `terminal text ${text}`);
};

const sleep = async (durationMs: number): Promise<void> => {
	await new Promise((resolve) => {
		setTimeout(resolve, durationMs);
	});
};

test("terminal websocket session preserves cwd changes across commands", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-terminal-cwd-"));
	const resolvedWorkspaceRoot = realpathSync(workspaceRoot);
	const { baseUrl, cleanup, client } = await createTestServer();
	const expectedParent = dirname(resolvedWorkspaceRoot);

	let ws: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal cwd" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		ws = await createEdenWsClient(createEdenClient({ baseUrl }));
		const events: TerminalServerEvent[] = [];
		bindTerminalEvents(ws, chatId, events);

		ws.send({
			data: { chatId, cols: 100, rows: 30 },
			event: "join_terminal_session",
		});

		await waitForCondition(
			() => events.some((event) => event.event === "terminal_session_snapshot"),
			10_000,
			"initial terminal snapshot",
		);
		expect(
			events.some(
				(event) =>
					event.event === "terminal_session_snapshot"
					&& event.data.snapshot.includes("MacBook-Pro-de-Samuel"),
			),
		).toBe(true);

		ws.send({
			data: { chatId, data: "printf '__PWD1__%s__\\n' \"$PWD\"\r" },
			event: "terminal_input",
		});
		await waitForTerminalText(events, `__PWD1__${resolvedWorkspaceRoot}__`);

		ws.send({
			data: { chatId, data: "cd ..\rprintf '__PWD2__%s__\\n' \"$PWD\"\r" },
			event: "terminal_input",
		});
		await waitForTerminalText(events, `__PWD2__${expectedParent}__`);
	} finally {
		ws?.close();
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 20_000);

test("terminal websocket stays running after join without immediate input", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-terminal-idle-"));
	const { baseUrl, cleanup, client } = await createTestServer();

	let ws: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal idle" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		ws = await createEdenWsClient(createEdenClient({ baseUrl }));
		const events: TerminalServerEvent[] = [];
		bindTerminalEvents(ws, chatId, events);

		ws.send({
			data: { chatId, cols: 100, rows: 30 },
			event: "join_terminal_session",
		});

		await waitForCondition(
			() => events.some((event) => event.event === "terminal_session_snapshot"),
			10_000,
			"idle terminal snapshot",
		);

		await sleep(1_000);

		expect(
			events.some(
				(event) =>
					event.event === "terminal_session_state"
					&& event.data.status === "exited",
			),
		).toBe(false);
	} finally {
		ws?.close();
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 20_000);

test("terminal websocket streams long-running output and SIGINT keeps the shell alive", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-terminal-stream-"));
	const { baseUrl, cleanup, client } = await createTestServer();

	let ws: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal stream" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		ws = await createEdenWsClient(createEdenClient({ baseUrl }));
		const events: TerminalServerEvent[] = [];
		bindTerminalEvents(ws, chatId, events);

		ws.send({
			data: { chatId },
			event: "join_terminal_session",
		});
		await waitForCondition(
			() => events.some((event) => event.event === "terminal_session_snapshot"),
			10_000,
			"initial terminal snapshot",
		);

		ws.send({
			data: {
				chatId,
				data: "i=0; while :; do printf '__TICK__%s__\\n' \"$i\"; i=$((i+1)); sleep 0.2; done\r",
			},
			event: "terminal_input",
		});

		await waitForTerminalText(events, "__TICK__0__");
		await waitForTerminalText(events, "__TICK__1__");

		ws.send({
			data: { chatId, signal: "SIGINT" },
			event: "terminal_signal",
		});
		await sleep(500);
		ws.send({
			data: { chatId, data: "printf '__AFTER_INT__\\n'\r" },
			event: "terminal_input",
		});

		await waitForTerminalText(events, "__AFTER_INT__");
	} finally {
		ws?.close();
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 20_000);

test("terminal websocket reconnect restores snapshot without replaying old chunks and delete clears persisted snapshot", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-terminal-reconnect-"));
	const { baseUrl, cleanup, client, databasePath } = await createTestServer();

	let firstSocket: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;
	let secondSocket: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal reconnect" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		firstSocket = await createEdenWsClient(createEdenClient({ baseUrl }));
		const firstEvents: TerminalServerEvent[] = [];
		bindTerminalEvents(firstSocket, chatId, firstEvents);

		firstSocket.send({
			data: { chatId },
			event: "join_terminal_session",
		});
		await waitForCondition(
			() => firstEvents.some((event) => event.event === "terminal_session_snapshot"),
			10_000,
			"first terminal snapshot",
		);

		firstSocket.send({
			data: { chatId, data: "printf '__SNAP_A__\\n'\r" },
			event: "terminal_input",
		});
		await waitForTerminalText(firstEvents, "__SNAP_A__");
		firstSocket.close();

		secondSocket = await createEdenWsClient(createEdenClient({ baseUrl }));
		const secondEvents: TerminalServerEvent[] = [];
		bindTerminalEvents(secondSocket, chatId, secondEvents);

		secondSocket.send({
			data: { chatId },
			event: "join_terminal_session",
		});
		await waitForCondition(
			() =>
				secondEvents.some(
					(event) => event.event === "terminal_session_snapshot" && event.data.snapshot.includes("__SNAP_A__"),
				),
			10_000,
			"reconnect snapshot",
		);

		expect(collectTerminalText(secondEvents)).not.toContain("__SNAP_A__");

		secondSocket.send({
			data: { chatId, data: "printf '__SNAP_B__\\n'\r" },
			event: "terminal_input",
		});
		await waitForTerminalText(secondEvents, "__SNAP_B__");
		expect(collectTerminalText(secondEvents)).not.toContain("__SNAP_A__");

		secondSocket.send({
			data: { chatId, data: "exit\r" },
			event: "terminal_input",
		});
		await waitForCondition(
			() =>
				secondEvents.some(
					(event) => event.event === "terminal_session_state" && event.data.status === "exited",
				),
			10_000,
			"terminal exited state",
		);

		const deleteResult = await client.v1.chats({ id: chatId }).delete();
		expect((deleteResult.data as { deleted: boolean }).deleted).toBe(true);

		const database = new Database(databasePath);
		try {
			const remaining = database
				.prepare("SELECT COUNT(1) AS count FROM terminal_sessions WHERE chatId = ?")
				.get(chatId) as { count: number };
			expect(remaining.count).toBe(0);
		} finally {
			database.close();
		}
	} finally {
		firstSocket?.close();
		secondSocket?.close();
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 20_000);

test("terminal websocket starts when only PYTHON fallback is configured", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-terminal-python-fallback-"));
	const shimRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-terminal-python-shim-"));
	const pythonShimPath = join(shimRoot, "python");
	symlinkSync("/usr/bin/python3", pythonShimPath);

	const originalPython3 = process.env.PYTHON3;
	const originalPython = process.env.PYTHON;
	const originalPath = process.env.PATH;

	process.env.PYTHON3 = "/definitely-missing-python3";
	process.env.PYTHON = pythonShimPath;
	process.env.PATH = "/usr/bin:/bin";

	const { baseUrl, cleanup, client } = await createTestServer();

	let ws: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal python fallback" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		ws = await createEdenWsClient(createEdenClient({ baseUrl }));
		const events: TerminalServerEvent[] = [];
		bindTerminalEvents(ws, chatId, events);

		ws.send({
			data: { chatId, cols: 100, rows: 30 },
			event: "join_terminal_session",
		});

		await waitForCondition(
			() => events.some((event) => event.event === "terminal_session_snapshot"),
			10_000,
			"python fallback terminal snapshot",
		);

		ws.send({
			data: { chatId, data: "printf '__PYTHON_FALLBACK_OK__\\n'\r" },
			event: "terminal_input",
		});

		await waitForTerminalText(events, "__PYTHON_FALLBACK_OK__");
	} finally {
		if (originalPython3 === undefined) {
			delete process.env.PYTHON3;
		} else {
			process.env.PYTHON3 = originalPython3;
		}

		if (originalPython === undefined) {
			delete process.env.PYTHON;
		} else {
			process.env.PYTHON = originalPython;
		}

		if (originalPath === undefined) {
			delete process.env.PATH;
		} else {
			process.env.PATH = originalPath;
		}

		ws?.close();
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
		rmSync(shimRoot, { force: true, recursive: true });
	}
}, 20_000);

test("terminal websocket starts when bundled bridge file is missing and extracted fallback is used", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-terminal-embedded-bridge-"));
	const candidatePath = terminalSessionBridgeTestHarness.getCandidateBridgePath();
	const backupPath = `${candidatePath}.bak-e2e`;
	const { baseUrl, cleanup, client } = await createTestServer();

	let ws: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	renameSync(candidatePath, backupPath);
	terminalSessionBridgeTestHarness.clearCachedBridgePath();

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal extracted bridge" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		ws = await createEdenWsClient(createEdenClient({ baseUrl }));
		const events: TerminalServerEvent[] = [];
		bindTerminalEvents(ws, chatId, events);

		ws.send({
			data: { chatId, cols: 100, rows: 30 },
			event: "join_terminal_session",
		});

		await waitForCondition(
			() => events.some((event) => event.event === "terminal_session_snapshot"),
			10_000,
			"embedded bridge terminal snapshot",
		);

		ws.send({
			data: { chatId, data: "printf '__EMBEDDED_BRIDGE_OK__\\n'\r" },
			event: "terminal_input",
		});

		await waitForTerminalText(events, "__EMBEDDED_BRIDGE_OK__");
	} finally {
		ws?.close();
		await cleanup();
		terminalSessionBridgeTestHarness.clearCachedBridgePath();
		rmSync(candidatePath, { force: true });
		renameSync(backupPath, candidatePath);
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 20_000);

test("terminal websocket rejects chats whose workspace path no longer exists", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-terminal-missing-workspace-"));
	const { baseUrl, cleanup, client } = await createTestServer();

	let ws: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal missing workspace" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		rmSync(workspaceRoot, { force: true, recursive: true });

		ws = await createEdenWsClient(createEdenClient({ baseUrl }));
		const events: TerminalServerEvent[] = [];
		bindTerminalEvents(ws, chatId, events);

		ws.send({
			data: { chatId, cols: 100, rows: 30 },
			event: "join_terminal_session",
		});

		await waitForCondition(
			() => events.some((event) => event.event === "error" && event.data.code === "project_not_found"),
			10_000,
			"missing workspace error",
		);
		expect(events.some((event) => event.event === "terminal_session_snapshot")).toBe(false);
	} finally {
		ws?.close();
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 20_000);

test("terminal websocket discards persisted exited snapshots and starts a fresh session", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-terminal-stale-snapshot-"));
	const { baseUrl, cleanup, client, databasePath } = await createTestServer();

	let ws: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal stale snapshot" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		const database = new Database(databasePath);
		try {
			database
				.prepare(`
					insert into terminal_sessions (
						chatId, cols, cwd, exitCode, exitedAt, rows, seq, sessionId, shell, snapshot, startedAt, status, updatedAt
					) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
				`)
				.run(
					chatId,
					80,
					workspaceRoot,
					1,
					new Date().toISOString(),
					24,
					0,
					"stale-session",
					"/bin/zsh",
					"stale prompt",
					new Date().toISOString(),
					"exited",
					new Date().toISOString(),
				);
		} finally {
			database.close();
		}

		ws = await createEdenWsClient(createEdenClient({ baseUrl }));
		const events: TerminalServerEvent[] = [];
		bindTerminalEvents(ws, chatId, events);

		ws.send({
			data: { chatId, cols: 100, rows: 30 },
			event: "join_terminal_session",
		});

		await waitForCondition(
			() =>
				events.some(
					(event) =>
						event.event === "terminal_session_snapshot"
						&& event.data.status === "running"
						&& event.data.sessionId !== "stale-session",
				),
			10_000,
			"fresh snapshot after persisted exited snapshot",
		);
	} finally {
		ws?.close();
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 20_000);
