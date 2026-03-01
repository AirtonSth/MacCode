export interface ApiError {
	code: string;
	message: string;
	payload: unknown;
	status: number;
}

export interface EdenApiResult<T> {
	data: T | null;
	error: ApiError | null;
	status: number;
}

interface EdenErrorWrapper {
	value?: {
		error?: string;
		message?: string;
	};
}

interface EdenResponseLike {
	data?: unknown;
	error?: unknown;
	status?: number;
}

const isObject = (value: unknown): value is Record<string, unknown> =>
	typeof value === "object" && value !== null;

const toErrorMessage = (value: unknown, fallback: string): string => {
	if (!isObject(value)) {
		return fallback;
	}

	const error = value.error;
	if (typeof error === "string" && error.trim().length > 0) {
		return error;
	}

	const message = value.message;
	if (typeof message === "string" && message.trim().length > 0) {
		return message;
	}

	return fallback;
};

const createApiError = (status: number, errorPayload: unknown): ApiError => {
	const fallback = status > 0 ? `HTTP_${status}` : "NETWORK";
	const payload = isObject(errorPayload) && "value" in errorPayload
		? (errorPayload as EdenErrorWrapper).value
		: errorPayload;

	return {
		code: fallback,
		message: toErrorMessage(payload, fallback),
		payload,
		status,
	};
};

export const toEdenApiResult = <T>(response: EdenResponseLike): EdenApiResult<T> => {
	const status = typeof response.status === "number" ? response.status : 0;
	const hasError = Boolean(response.error);

	if (hasError) {
		return {
			data: null,
			error: createApiError(status, response.error),
			status,
		};
	}

	return {
		data: (response.data as T | undefined) ?? null,
		error: null,
		status,
	};
};

export const unwrapEdenData = <T>(response: EdenResponseLike): T => {
	const result = toEdenApiResult<T>(response);

	if (!result.data) {
		throw result.error ?? createApiError(result.status, null);
	}

	return result.data;
};
