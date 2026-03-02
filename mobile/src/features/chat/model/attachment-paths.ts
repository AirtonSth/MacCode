const ABSOLUTE_PATH_PATTERN = /^(?:\/|[A-Za-z]:[\\/]|\\\\)/u;

const stripWrappingQuotes = (value: string): string => value.trim().replace(/^["']+|["']+$/u, "");

const decodeFileUriToPath = (value: string): string | null => {
	if (!value.toLowerCase().startsWith("file://")) {
		return null;
	}

	try {
		const payload = decodeURIComponent(value.slice("file://".length));
		if (payload.length === 0) {
			return null;
		}

		if (/^\/[A-Za-z]:\//u.test(payload)) {
			return payload.slice(1);
		}

		if (/^[A-Za-z]:[\\/]/u.test(payload)) {
			return payload;
		}

		return payload.startsWith("/") ? payload : `/${payload}`;
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
