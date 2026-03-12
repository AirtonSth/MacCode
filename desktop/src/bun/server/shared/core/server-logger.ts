const ANSI = {
	reset: "\x1b[0m",
	bold: "\x1b[1m",
	dim: "\x1b[2m",
	red: "\x1b[31m",
	green: "\x1b[32m",
	yellow: "\x1b[33m",
	blue: "\x1b[34m",
	magenta: "\x1b[35m",
	cyan: "\x1b[36m",
	gray: "\x1b[90m",
};

type LogLevel = "debug" | "error" | "info" | "success" | "warn";

const colorByLevel: Record<LogLevel, string> = {
	debug: ANSI.magenta,
	error: ANSI.red,
	info: ANSI.cyan,
	success: ANSI.green,
	warn: ANSI.yellow,
};

const iconByLevel: Record<LogLevel, string> = {
	debug: "DBG",
	error: "ERR",
	info: "INF",
	success: "OK ",
	warn: "WRN",
};

const supportsColor = Boolean(process.stdout?.isTTY);

const paint = (value: string, color: string): string =>
	supportsColor ? `${color}${value}${ANSI.reset}` : value;

const nowTimestamp = (): string => {
	const value = new Date();
	const hours = String(value.getHours()).padStart(2, "0");
	const minutes = String(value.getMinutes()).padStart(2, "0");
	const seconds = String(value.getSeconds()).padStart(2, "0");
	const milliseconds = String(value.getMilliseconds()).padStart(3, "0");
	return `${hours}:${minutes}:${seconds}.${milliseconds}`;
};

const formatScalar = (value: unknown): string => {
	if (value === null) {
		return "null";
	}

	if (value === undefined) {
		return "undefined";
	}

	if (typeof value === "string") {
		return value;
	}

	if (typeof value === "number" || typeof value === "boolean") {
		return String(value);
	}

	try {
		return JSON.stringify(value);
	} catch {
		return String(value);
	}
};

const formatDetails = (details: Record<string, unknown> | undefined): string[] => {
	if (!details) {
		return [];
	}

	return Object.entries(details).map(([key, value]) => `  ${paint("•", ANSI.gray)} ${paint(key, ANSI.bold)}: ${formatScalar(value)}`);
};

const log = (level: LogLevel, scope: string, message: string, details?: Record<string, unknown>): void => {
	const timestamp = paint(nowTimestamp(), ANSI.gray);
	const levelText = paint(iconByLevel[level], colorByLevel[level]);
	const scopeText = paint(`[${scope}]`, ANSI.blue);
	const messageText = level === "error" ? paint(message, ANSI.red) : message;
	const lines = [`${timestamp} ${levelText} ${scopeText} ${messageText}`, ...formatDetails(details)];
	console.log(lines.join("\n"));
};

export const serverLogger = {
	banner: (title: string, details?: Record<string, unknown>): void => {
		const separator = paint("=".repeat(Math.max(title.length + 8, 40)), ANSI.gray);
		console.log(separator);
		console.log(`${paint("RemoteCode", ANSI.bold)} ${paint(title, ANSI.cyan)}`);
		for (const line of formatDetails(details)) {
			console.log(line);
		}
		console.log(separator);
	},

	createRequestId: (prefix: string): string =>
		`${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,

	debug: (scope: string, message: string, details?: Record<string, unknown>): void => {
		log("debug", scope, message, details);
	},

	error: (scope: string, message: string, details?: Record<string, unknown>): void => {
		log("error", scope, message, details);
	},

	info: (scope: string, message: string, details?: Record<string, unknown>): void => {
		log("info", scope, message, details);
	},

	success: (scope: string, message: string, details?: Record<string, unknown>): void => {
		log("success", scope, message, details);
	},

	traceDurationMs: (startedAt: number): number => Date.now() - startedAt,

	warn: (scope: string, message: string, details?: Record<string, unknown>): void => {
		log("warn", scope, message, details);
	},
};

export const maskEmailForLogs = (value: string | null | undefined): string | null => {
	if (!value) {
		return null;
	}

	const normalized = value.trim();
	if (!normalized.includes("@")) {
		return normalized.length <= 2 ? "***" : `${normalized.slice(0, 2)}***`;
	}

	const [local, domain] = normalized.split("@");
	const localPreview = local.length <= 2 ? `${local.slice(0, 1)}***` : `${local.slice(0, 2)}***`;
	return `${localPreview}@${domain}`;
};

export const maskTokenForLogs = (value: string | null | undefined): string | null => {
	if (!value) {
		return null;
	}

	const normalized = value.trim();
	if (normalized.length <= 8) {
		return "***";
	}

	return `${normalized.slice(0, 4)}...${normalized.slice(-4)}`;
};

export const toLogErrorDetails = (error: unknown): Record<string, unknown> => {
	if (!(error instanceof Error)) {
		return {
			error: formatScalar(error),
		};
	}

	const status = (error as { status?: unknown }).status;
	const cause = (error as { cause?: unknown }).cause;

	return {
		error: error.message,
		name: error.name,
		status: typeof status === "number" ? status : undefined,
		cause: cause ? formatScalar(cause) : undefined,
	};
};
