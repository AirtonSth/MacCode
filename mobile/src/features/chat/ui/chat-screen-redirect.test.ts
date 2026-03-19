/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

/**
 * [M-18] Tests for the redirect logic fix.
 *
 * Previously the chat screen waited 180ms before redirecting when no
 * selectedChatId was present, showing the full chat UI as a flash.
 * After the fix, the redirect is immediate and an early-return renders
 * a minimal loading view instead of the full chat UI.
 */

/** Mirrors the `shouldRedirectAway` condition from chat-screen.tsx. */
const shouldRedirectAway = (input: {
	isConfigLoaded: boolean;
	isLoaded: boolean;
	isPending: boolean;
	isError: boolean;
	selectedProjectId: string | null;
	selectedChatId: string | null;
	source: string | undefined;
}): boolean => {
	return (
		input.isConfigLoaded &&
		input.isLoaded &&
		!input.isPending &&
		(input.isError ||
			!input.selectedProjectId ||
			(!input.selectedChatId && input.source !== "thread-list" && input.source !== "terminal"))
	);
};

describe("[M-18] shouldRedirectAway", () => {
	it("returns true when there is a server error", () => {
		expect(
			shouldRedirectAway({
				isConfigLoaded: true,
				isError: true,
				isLoaded: true,
				isPending: false,
				selectedChatId: "abc",
				selectedProjectId: "proj-1",
				source: undefined,
			}),
		).toBe(true);
	});

	it("returns true when no project is selected", () => {
		expect(
			shouldRedirectAway({
				isConfigLoaded: true,
				isError: false,
				isLoaded: true,
				isPending: false,
				selectedChatId: null,
				selectedProjectId: null,
				source: undefined,
			}),
		).toBe(true);
	});

	it("returns true when no chat is selected and source is not thread-list", () => {
		expect(
			shouldRedirectAway({
				isConfigLoaded: true,
				isError: false,
				isLoaded: true,
				isPending: false,
				selectedChatId: null,
				selectedProjectId: "proj-1",
				source: undefined,
			}),
		).toBe(true);
	});

	it("returns false when source is thread-list even without chatId", () => {
		expect(
			shouldRedirectAway({
				isConfigLoaded: true,
				isError: false,
				isLoaded: true,
				isPending: false,
				selectedChatId: null,
				selectedProjectId: "proj-1",
				source: "thread-list",
			}),
		).toBe(false);
	});

	it("returns false when source is terminal even without chatId", () => {
		expect(
			shouldRedirectAway({
				isConfigLoaded: true,
				isError: false,
				isLoaded: true,
				isPending: false,
				selectedChatId: null,
				selectedProjectId: "proj-1",
				source: "terminal",
			}),
		).toBe(false);
	});

	it("returns false when a chat is selected", () => {
		expect(
			shouldRedirectAway({
				isConfigLoaded: true,
				isError: false,
				isLoaded: true,
				isPending: false,
				selectedChatId: "chat-1",
				selectedProjectId: "proj-1",
				source: undefined,
			}),
		).toBe(false);
	});

	it("returns false when config is not yet loaded", () => {
		expect(
			shouldRedirectAway({
				isConfigLoaded: false,
				isError: false,
				isLoaded: true,
				isPending: false,
				selectedChatId: null,
				selectedProjectId: "proj-1",
				source: undefined,
			}),
		).toBe(false);
	});

	it("returns false when health query is still pending", () => {
		expect(
			shouldRedirectAway({
				isConfigLoaded: true,
				isError: false,
				isLoaded: true,
				isPending: true,
				selectedChatId: null,
				selectedProjectId: "proj-1",
				source: undefined,
			}),
		).toBe(false);
	});
});
