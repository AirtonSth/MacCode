import { expect, test } from "bun:test";

import { runFakeProvider } from "./fake-provider-runner";

test("FakeProviderRunner returns completed with provider diff and text", async () => {
	const providerResult = await runFakeProvider({
		chatId: "unit-chat-id",

		onDelta: () => {
			// no-op
		},

		text: "hello",
	});

	expect(providerResult.status).toBe("completed");
	expect(providerResult.assistantText).toContain("Echo: hello");
	expect(providerResult.diffAdded).toBeGreaterThan(0);
	expect(providerResult.diffRemoved).toBeGreaterThanOrEqual(0);
	expect(providerResult.error).toBeUndefined();
});

test("FakeProviderRunner propagates failure when forced", async () => {
	const previous = process.env.REMOTECODE_FAKE_PROVIDER_FORCE_FAIL;

	process.env.REMOTECODE_FAKE_PROVIDER_FORCE_FAIL = "1";

	const providerResult = await runFakeProvider({
		chatId: "unit-chat-id-fail",

		onDelta: () => {
			// no-op
		},

		text: "hello",
	});

	expect(providerResult.status).toBe("failed");
	expect(providerResult.error).toBeTruthy();

	if (previous === undefined) {
		delete process.env.REMOTECODE_FAKE_PROVIDER_FORCE_FAIL;
	} else {
		process.env.REMOTECODE_FAKE_PROVIDER_FORCE_FAIL = previous;
	}
});
