/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

import { shouldLockProviderSelection } from "./provider-selection";

describe("shouldLockProviderSelection", () => {
	it("locks the provider once the selected thread already has messages", () => {
		expect(shouldLockProviderSelection({
			hasStreamingText: false,
			hasStreamingTurn: false,
			messageCount: 1,
			providerThreadId: null,
			turnCount: 0,
		})).toBe(true);
	});

	it("locks the provider while a streamed response is visible", () => {
		expect(shouldLockProviderSelection({
			hasStreamingText: true,
			hasStreamingTurn: false,
			messageCount: 0,
			providerThreadId: null,
			turnCount: 0,
		})).toBe(true);
	});

	it("locks the provider for hydrated threads with a provider thread id", () => {
		expect(shouldLockProviderSelection({
			hasStreamingText: false,
			hasStreamingTurn: false,
			messageCount: 0,
			providerThreadId: "thread-42",
			turnCount: 0,
		})).toBe(true);
	});

	it("keeps the provider editable for empty draft threads", () => {
		expect(shouldLockProviderSelection({
			hasStreamingText: false,
			hasStreamingTurn: false,
			messageCount: 0,
			providerThreadId: null,
			turnCount: 0,
		})).toBe(false);
	});
});
