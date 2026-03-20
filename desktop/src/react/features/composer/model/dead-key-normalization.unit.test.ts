import { describe, expect, test } from "bun:test";
import { normalizeDeadKeyCompositionValue } from "./dead-key-normalization";

describe("[D-68] dead-key normalization", () => {
	test("removes a duplicated standalone tilde before a composed Portuguese character", () => {
		expect(normalizeDeadKeyCompositionValue("N\u02DCão")).toBe("Não");
	});

	test("removes a duplicated acute accent before a composed vowel", () => {
		expect(normalizeDeadKeyCompositionValue("caf\u00B4é")).toBe("café");
	});

	test("keeps standalone punctuation when the following character is not already accented", () => {
		expect(normalizeDeadKeyCompositionValue("Use ~ for home")).toBe("Use ~ for home");
	});
});
