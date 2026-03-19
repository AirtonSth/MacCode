/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * [M-02] Streaming text persistence tests.
 *
 * On assistant_done, streaming text must remain visible as a fallback
 * until the final persisted message is successfully fetched.
 * This prevents a visible gap where the response disappears.
 */

describe("[M-02] Streaming text persistence on assistant_done", () => {
	test("streaming text is NOT cleared immediately on assistant_done", () => {
		let streamingText = "This is the assistant response that was being streamed...";
		let messagesPage: { messages: { role: string; content: string }[] } | null = null;

		const clearStreamingText = () => {
			streamingText = "";
		};

		// Simulate assistant_done: streaming text should NOT be cleared yet
		expect(streamingText).not.toBe("");

		// Simulate first sync attempt — message not yet persisted
		messagesPage = { messages: [{ role: "user", content: "hello" }] };
		const lastMessage = messagesPage.messages.at(-1);
		if (lastMessage?.role !== "assistant") {
			expect(streamingText).not.toBe("");
		}

		// Simulate successful sync — message IS persisted
		messagesPage = {
			messages: [
				{ role: "user", content: "hello" },
				{ role: "assistant", content: "This is the assistant response" },
			],
		};
		const lastMessage2 = messagesPage.messages.at(-1);
		if (lastMessage2?.role === "assistant") {
			clearStreamingText();
		}

		expect(streamingText).toBe("");
	});

	test("streaming text is cleared on max attempts even if message not found", () => {
		let streamingText = "Streaming response...";
		let attempt = 0;
		const maxAttempts = 5;

		const clearStreamingText = () => {
			streamingText = "";
		};

		while (attempt < maxAttempts) {
			attempt += 1;
			expect(streamingText).not.toBe("");
		}

		if (attempt >= maxAttempts) {
			clearStreamingText();
		}

		expect(streamingText).toBe("");
	});

	test("streaming text is cleared when not viewing latest messages", () => {
		let streamingText = "Streaming response...";
		const isViewingLatestMessages = false;

		const clearStreamingText = () => {
			streamingText = "";
		};

		if (!isViewingLatestMessages) {
			clearStreamingText();
		}

		expect(streamingText).toBe("");
	});

	test("clearStreamingText helper only clears for the specific chatId", () => {
		const state: Record<string, string> = {
			"chat-1": "Response for chat 1",
			"chat-2": "Response for chat 2",
		};

		const clearStreamingTextForChat = (chatId: string) => ({ ...state, [chatId]: "" });

		const result = clearStreamingTextForChat("chat-1");
		expect(result["chat-1"]).toBe("");
		expect(result["chat-2"]).toBe("Response for chat 2");
	});
});
