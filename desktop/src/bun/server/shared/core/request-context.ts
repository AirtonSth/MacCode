export interface MutationRequestMetadata {
	clientId: string | null;
	requestId: string | null;
}

const readHeader = (request: Request, header: string): string | null => {
	const value = request.headers.get(header)?.trim();
	return value && value.length > 0 ? value : null;
};

export const readMutationRequestMetadata = (request: Request): MutationRequestMetadata => {
	return {
		clientId: readHeader(request, "x-remotecode-client-id"),
		requestId: readHeader(request, "x-remotecode-request-id"),
	};
};
