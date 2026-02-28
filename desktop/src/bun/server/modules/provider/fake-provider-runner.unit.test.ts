import { expect, test } from "bun:test";

import { runFakeProvider } from "./fake-provider-runner";

test("runFakeProvider returns completed with provider text output", async () => {
	const result = await runFakeProvider({
		chatId: "provider-unit-chat",

		onDelta: () => {
			// no-op
		},

		text: "hello",
	});

	expect(result.status).toBe("completed");
	expect(result.assistantText).toContain("Echo: hello");
	expect(result.diffAdded).toBeGreaterThan(0);
	expect(result.error).toBeUndefined();
});
