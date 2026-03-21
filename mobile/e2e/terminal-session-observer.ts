import { readFileSync } from "node:fs";
import { join } from "node:path";

interface TerminalObserverState {
	baseUrl: string;
	chats: {
		active: {
			id: string;
			title: string;
		};
	};
	token?: string;
}

type ObserverMode = "roundtrip" | "wait-output";

const mode = process.argv[2] as ObserverMode | undefined;
const payload = process.argv[3] ?? "";
const expectedText = process.argv[4] ?? payload;
const timeoutMs = Number(process.argv[5] ?? 20_000);

if (mode !== "wait-output" && mode !== "roundtrip") {
	throw new Error("Usage: bun run ./e2e/terminal-session-observer.ts <wait-output|roundtrip> <payload> [expectedText] [timeoutMs]");
}

const statePath = process.env.RC_IOS_E2E_STATE_PATH ?? join(import.meta.dir, ".ios-e2e-state.json");
const state = JSON.parse(readFileSync(statePath, "utf8")) as TerminalObserverState;
const token = process.env.RC_E2E_TOKEN ?? state.token ?? "local-dev-token";
const wsUrl = `${state.baseUrl.replace(/^http/u, "ws")}/v1/ws?token=${encodeURIComponent(token)}`;

const complete = (socket: WebSocket, code: number) => {
	socket.close();
	process.exit(code);
};

const timer = setTimeout(() => {
	throw new Error(`Timed out waiting for terminal payload: ${expectedText}`);
}, timeoutMs);

const matchesExpectedText = (candidate: unknown): boolean =>
	typeof candidate === "string" && candidate.includes(expectedText);

const socket = new WebSocket(wsUrl);

socket.addEventListener("open", () => {
	socket.send(JSON.stringify({
		data: {
			chatId: state.chats.active.id,
		},
		event: "join_terminal_session",
	}));

	if (mode === "roundtrip") {
		socket.send(JSON.stringify({
			data: {
				chatId: state.chats.active.id,
				data: payload,
			},
			event: "terminal_input",
		}));
	}
});

socket.addEventListener("message", (event) => {
	const payloadMessage = JSON.parse(String(event.data)) as {
		data?: {
			data?: string;
			snapshot?: string;
		};
		event?: string;
	};

	if (payloadMessage.event === "terminal_output" && matchesExpectedText(payloadMessage.data?.data)) {
		clearTimeout(timer);
		complete(socket, 0);
		return;
	}

	if (payloadMessage.event === "terminal_session_snapshot" && matchesExpectedText(payloadMessage.data?.snapshot)) {
		clearTimeout(timer);
		complete(socket, 0);
	}
});

socket.addEventListener("error", (error) => {
	clearTimeout(timer);
	console.error("[terminal-session-observer] websocket error", error);
	process.exit(1);
});
