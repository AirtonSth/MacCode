const baseUrl = process.argv[2];
const chatId = process.argv[3];
const text = process.argv[4];
const token = process.env.RC_E2E_TOKEN ?? "local-dev-token";

if (!baseUrl || !chatId || !text) {
	console.error("Usage: bun run send-chat-message.ts <baseUrl> <chatId> <text>");
	process.exit(1);
}

const wsUrl = new URL("/v1/ws", baseUrl);
wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";
wsUrl.searchParams.set("token", token);

const socket = new WebSocket(wsUrl);
const timeout = setTimeout(() => {
	console.error("Timed out waiting for assistant_done.");
	socket.close();
	process.exit(1);
}, 30_000);

const closeSuccess = () => {
	clearTimeout(timeout);
	socket.close();
	process.exit(0);
};

const closeFailure = (message: string) => {
	clearTimeout(timeout);
	console.error(message);
	socket.close();
	process.exit(1);
};

socket.addEventListener("open", () => {
	socket.send(JSON.stringify({
		data: { chatId },
		event: "join_chat",
	}));
	socket.send(JSON.stringify({
		data: { chatId, text },
		event: "user_message",
	}));
});

socket.addEventListener("message", (event) => {
	if (typeof event.data !== "string") {
		return;
	}

	try {
		const payload = JSON.parse(event.data) as {
			data?: { chatId?: string; code?: string; message?: string };
			event?: string;
		};
		if (payload.event === "error") {
			closeFailure(payload.data?.message ?? "WebSocket send failed.");
			return;
		}

		if (payload.event === "assistant_done" && payload.data?.chatId === chatId) {
			closeSuccess();
		}
	} catch (error) {
		closeFailure(error instanceof Error ? error.message : "Unable to parse websocket payload.");
	}
});

socket.addEventListener("error", () => {
	closeFailure("WebSocket connection failed.");
});
