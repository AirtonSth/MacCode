const ABSOLUTE_PATH_PATTERN = /^(?:\/|[A-Za-z]:[\\/]|\\\\)/u;

type FileWithOptionalPath = File & { path?: string };

export type DataTransferLike = {
	files?: ArrayLike<FileWithOptionalPath> | null;
	getData?: (format: string) => string;
};

const stripWrappingQuotes = (value: string): string => {
	return value.trim().replace(/^["']+|["']+$/gu, "");
};

const decodeFileUriToPath = (value: string): string | null => {
	if (!value.toLowerCase().startsWith("file://")) {
		return null;
	}

	try {
		const parsed = new URL(value);
		const decodedPath = decodeURIComponent(parsed.pathname);

		if (/^\/[A-Za-z]:\//u.test(decodedPath)) {
			return decodedPath.slice(1);
		}

		if (parsed.host.length > 0) {
			return `//${parsed.host}${decodedPath}`;
		}

		return decodedPath;
	} catch {
		return null;
	}
};

const dedupePaths = (paths: string[]): string[] => {
	const unique = new Set<string>();
	const ordered: string[] = [];

	for (const path of paths) {
		if (unique.has(path)) {
			continue;
		}

		unique.add(path);
		ordered.push(path);
	}

	return ordered;
};

const collectPathCandidates = (candidate: unknown, sink: string[]): void => {
	if (typeof candidate === "string") {
		const normalized = normalizeAttachmentPath(candidate);
		if (normalized) {
			sink.push(normalized);
		}
		return;
	}

	if (Array.isArray(candidate)) {
		for (const item of candidate) {
			collectPathCandidates(item, sink);
		}
		return;
	}

	if (!candidate || typeof candidate !== "object") {
		return;
	}

	if ("paths" in candidate) {
		collectPathCandidates((candidate as { paths?: unknown }).paths, sink);
	}
};

const splitPayloadLines = (value: string): string[] => {
	return value
		.split(/\r?\n/gu)
		.map((line) => line.trim())
		.filter((line) => line.length > 0);
};

const safeReadDataTransfer = (dataTransfer: DataTransferLike, format: string): string => {
	try {
		return dataTransfer.getData?.(format) ?? "";
	} catch {
		return "";
	}
};

const collectPathsFromTextPayload = (payload: string, sink: string[]): void => {
	for (const line of splitPayloadLines(payload)) {
		if (line.startsWith("#")) {
			continue;
		}

		const normalized = normalizeAttachmentPath(line);
		if (normalized) {
			sink.push(normalized);
		}
	}
};

export const normalizeAttachmentPath = (candidate: string): string | null => {
	const stripped = stripWrappingQuotes(candidate);
	if (stripped.length === 0) {
		return null;
	}

	const decodedUriPath = decodeFileUriToPath(stripped);
	const normalized = decodedUriPath ?? stripped;

	if (!ABSOLUTE_PATH_PATTERN.test(normalized)) {
		return null;
	}

	return normalized;
};

export const extractAttachmentPathsFromPickerResult = (result: unknown): string[] => {
	const candidates: string[] = [];
	collectPathCandidates(result, candidates);
	return dedupePaths(candidates);
};

export const extractAttachmentPathsFromDataTransfer = (dataTransfer: DataTransferLike | null | undefined): string[] => {
	if (!dataTransfer) {
		return [];
	}

	const candidates: string[] = [];

	const files = dataTransfer.files;
	if (files) {
		for (let index = 0; index < files.length; index += 1) {
			const path = files[index]?.path;
			if (typeof path !== "string") {
				continue;
			}

			const normalized = normalizeAttachmentPath(path);
			if (normalized) {
				candidates.push(normalized);
			}
		}
	}

	collectPathsFromTextPayload(safeReadDataTransfer(dataTransfer, "text/uri-list"), candidates);
	collectPathsFromTextPayload(safeReadDataTransfer(dataTransfer, "text/plain"), candidates);

	return dedupePaths(candidates);
};

export const appendAttachmentPathsToMessage = (message: string, rawPaths: string[]): string => {
	const normalizedPaths = dedupePaths(
		rawPaths
			.map((path) => normalizeAttachmentPath(path))
			.filter((path): path is string => typeof path === "string"),
	);

	if (normalizedPaths.length === 0) {
		return message;
	}

	if (message.length === 0) {
		return normalizedPaths.join(" ");
	}

	const separator = /\s$/u.test(message) ? "" : " ";
	return `${message}${separator}${normalizedPaths.join(" ")}`;
};
