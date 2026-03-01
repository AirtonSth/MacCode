import { expect, test } from "bun:test";

import {
	appendAttachmentPathsToMessage,
	extractAttachmentPathsFromDataTransfer,
	extractAttachmentPathsFromPickerResult,
} from "./attachment-paths";

test("attachment flow appends picker paths and dropped paths to the same composer message", () => {
	const pickerPayload = {
		paths: ["/Users/sam/Downloads/codex.txt", "/Users/sam/Documents/notes"],
	};
	const droppedPayload = {
		files: [{ path: "/Users/sam/Projects/remotecode.io" }] as unknown as ArrayLike<File & { path?: string }>,
		getData: (format: string) => {
			if (format === "text/plain") {
				return "/Users/sam/Downloads/codex.txt";
			}
			return "";
		},
	};

	let message = "Analyze the text";
	message = appendAttachmentPathsToMessage(message, extractAttachmentPathsFromPickerResult(pickerPayload));
	message = appendAttachmentPathsToMessage(message, extractAttachmentPathsFromDataTransfer(droppedPayload));

	expect(message).toBe(
		"Analyze the text /Users/sam/Downloads/codex.txt /Users/sam/Documents/notes /Users/sam/Projects/remotecode.io",
	);
});

test("attachment flow keeps existing spacing when appending selected paths", () => {
	const message = appendAttachmentPathsToMessage("Analyze the text ", [
		"/Users/sam/Downloads/codex.txt",
	]);

	expect(message).toBe("Analyze the text /Users/sam/Downloads/codex.txt");
});
