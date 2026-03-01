import { expect, test } from "bun:test";

import {
	appendAttachmentPathsToMessage,
	extractAttachmentPathsFromDataTransfer,
	extractAttachmentPathsFromPickerResult,
	normalizeAttachmentPath,
} from "./attachment-paths";

test("normalizeAttachmentPath accepts absolute unix and windows paths", () => {
	expect(normalizeAttachmentPath("/Users/sam/Downloads/codex.txt")).toBe("/Users/sam/Downloads/codex.txt");
	expect(normalizeAttachmentPath("C:\\Users\\sam\\Downloads\\codex.txt")).toBe("C:\\Users\\sam\\Downloads\\codex.txt");
});

test("normalizeAttachmentPath decodes file URIs and rejects relative paths", () => {
	expect(normalizeAttachmentPath("file:///Users/sam/Downloads/codex%20notes.txt")).toBe(
		"/Users/sam/Downloads/codex notes.txt",
	);
	expect(normalizeAttachmentPath("./Downloads/codex.txt")).toBeNull();
});

test("extractAttachmentPathsFromPickerResult flattens nested payloads and deduplicates", () => {
	const result = extractAttachmentPathsFromPickerResult([
		"/Users/sam/Downloads/codex.txt",
		{ paths: ["/Users/sam/Documents", "relative/path"] },
		{ paths: [{ paths: ["/Users/sam/Downloads/codex.txt"] }] },
	]);

	expect(result).toEqual(["/Users/sam/Downloads/codex.txt", "/Users/sam/Documents"]);
});

test("extractAttachmentPathsFromDataTransfer reads file paths, uri list and plain text", () => {
	const result = extractAttachmentPathsFromDataTransfer({
		files: [
			{ path: "/Users/sam/Downloads/codex.txt" },
			{ path: "/Users/sam/Documents" },
		] as unknown as ArrayLike<File & { path?: string }>,
		getData: (format: string) => {
			if (format === "text/uri-list") {
				return "file:///Users/sam/Downloads/codex.txt\n#ignored comment";
			}

			if (format === "text/plain") {
				return "/Users/sam/Work/project\nnot/absolute";
			}

			return "";
		},
	});

	expect(result).toEqual([
		"/Users/sam/Downloads/codex.txt",
		"/Users/sam/Documents",
		"/Users/sam/Work/project",
	]);
});

test("appendAttachmentPathsToMessage appends deduplicated absolute paths", () => {
	const nextMessage = appendAttachmentPathsToMessage("Analyze the text", [
		"/Users/sam/Downloads/codex.txt",
		"/Users/sam/Downloads/codex.txt",
		"relative/path",
		"/Users/sam/Documents",
	]);

	expect(nextMessage).toBe("Analyze the text /Users/sam/Downloads/codex.txt /Users/sam/Documents");
});

test("appendAttachmentPathsToMessage preserves message when no valid absolute path exists", () => {
	expect(appendAttachmentPathsToMessage("Analyze the text", ["relative/path"])).toBe("Analyze the text");
});
