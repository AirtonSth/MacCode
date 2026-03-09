import {
	createContext,
	useCallback,
	useContext,
	useEffect,
	useMemo,
	useState,
} from "react";

import {
	createPrivateClient,
	type DesktopMobileConnectQrPayloadDto,
	type PrivateSessionDto,
	PrivateApiError,
} from "@remotecode/contracts";

import { useApiConfig } from "./api-config-provider";
import { ApiConfigStore, toApiConfig } from "./api-config-store";
import { PrivateSessionStore, type PersistedPrivateSessionRecord } from "./private-session-store";

interface PrivateSessionContextValue {
	activateConnector: (input: {
		backendUrl: string;
		connectorId: string;
		sessionRecordOverride?: PersistedPrivateSessionRecord;
	}) => Promise<void>;
	clearPendingQrPayload: () => Promise<void>;
	clearSessionRecord: () => Promise<void>;
	isLoaded: boolean;
	pendingQrPayload: DesktopMobileConnectQrPayloadDto | null;
	refreshSession: () => Promise<PrivateSessionDto | null>;
	sessionRecord: PersistedPrivateSessionRecord | null;
	setPendingQrPayload: (payload: DesktopMobileConnectQrPayloadDto) => Promise<void>;
	setSessionRecord: (input: PersistedPrivateSessionRecord) => Promise<void>;
}

export const toPrivateApiConfig = (input: {
	backendUrl: string;
	connectorId: string;
	session: PrivateSessionDto;
}) => toApiConfig({
	accessToken: input.session.accessToken,
	backendUrl: input.backendUrl,
	connectorId: input.connectorId,
	kind: "private",
});

export const refreshPrivateSessionRecord = async (input: {
	createClient?: typeof createPrivateClient;
	sessionRecord: PersistedPrivateSessionRecord | null;
}): Promise<PersistedPrivateSessionRecord | null> => {
	if (!input.sessionRecord) {
		return null;
	}

	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.sessionRecord.backendUrl,
	});
	const session = await client.refresh({
		refreshToken: input.sessionRecord.session.refreshToken,
	});
	return {
		backendUrl: input.sessionRecord.backendUrl,
		session,
	};
};

const PrivateSessionContext = createContext<PrivateSessionContextValue | null>(null);

export const PrivateSessionProvider = ({
	children,
}: {
	children: React.ReactNode;
}) => {
	const { config, update } = useApiConfig();
	const [isLoaded, setIsLoaded] = useState(false);
	const [pendingQrPayloadState, setPendingQrPayloadState] = useState<DesktopMobileConnectQrPayloadDto | null>(null);
	const [sessionRecordState, setSessionRecordState] = useState<PersistedPrivateSessionRecord | null>(null);

	const reload = useCallback(async () => {
		const state = await PrivateSessionStore.read();
		setPendingQrPayloadState(state.pendingQrPayload);
		setSessionRecordState(state.sessionRecord);
		setIsLoaded(true);
	}, []);

	useEffect(() => {
		void reload();
	}, [reload]);

	const setSessionRecord = useCallback(async (input: PersistedPrivateSessionRecord) => {
		const persisted = await PrivateSessionStore.saveSessionRecord(input);
		setSessionRecordState(persisted);
	}, []);

	const clearSessionRecord = useCallback(async () => {
		await PrivateSessionStore.clearSessionRecord();
		setSessionRecordState(null);
		if (config.activeTarget.kind === "private") {
			await update(ApiConfigStore.defaultConfig);
		}
	}, [config.activeTarget.kind, update]);

	const setPendingQrPayload = useCallback(async (payload: DesktopMobileConnectQrPayloadDto) => {
		await PrivateSessionStore.savePendingQrPayload(payload);
		setPendingQrPayloadState(payload);
	}, []);

	const clearPendingQrPayload = useCallback(async () => {
		await PrivateSessionStore.clearPendingQrPayload();
		setPendingQrPayloadState(null);
	}, []);

	const activateConnector = useCallback(async (input: {
		backendUrl: string;
		connectorId: string;
		sessionRecordOverride?: PersistedPrivateSessionRecord;
	}) => {
		const currentSessionRecord = input.sessionRecordOverride ?? sessionRecordState;
		if (!currentSessionRecord || currentSessionRecord.backendUrl !== input.backendUrl) {
			throw new Error("private_session_missing_for_backend");
		}

		await update(toPrivateApiConfig({
			backendUrl: input.backendUrl,
			connectorId: input.connectorId,
			session: currentSessionRecord.session,
		}));
	}, [sessionRecordState, update]);

	const refreshSession = useCallback(async () => {
		try {
			const nextRecord = await refreshPrivateSessionRecord({
				sessionRecord: sessionRecordState,
			});
			if (!nextRecord) {
				return null;
			}

			await PrivateSessionStore.saveSessionRecord(nextRecord);
			setSessionRecordState(nextRecord);
			if (config.activeTarget.kind === "private" && config.activeTarget.backendUrl === nextRecord.backendUrl) {
				await update(toPrivateApiConfig({
					backendUrl: nextRecord.backendUrl,
					connectorId: config.activeTarget.connectorId,
					session: nextRecord.session,
				}));
			}
			return nextRecord.session;
		} catch (error) {
			if (!(error instanceof PrivateApiError) || error.status !== 401) {
				throw error;
			}

			await clearSessionRecord();
			return null;
		}
	}, [clearSessionRecord, config.activeTarget, sessionRecordState, update]);

	const value = useMemo<PrivateSessionContextValue>(() => ({
		activateConnector,
		clearPendingQrPayload,
		clearSessionRecord,
		isLoaded,
		pendingQrPayload: pendingQrPayloadState,
		refreshSession,
		sessionRecord: sessionRecordState,
		setPendingQrPayload,
		setSessionRecord,
	}), [
		activateConnector,
		clearPendingQrPayload,
		clearSessionRecord,
		isLoaded,
		pendingQrPayloadState,
		refreshSession,
		sessionRecordState,
		setPendingQrPayload,
		setSessionRecord,
	]);

	return (
		<PrivateSessionContext.Provider value={value}>
			{children}
		</PrivateSessionContext.Provider>
	);
};

export const usePrivateSession = (): PrivateSessionContextValue => {
	const context = useContext(PrivateSessionContext);
	if (!context) {
		throw new Error("PrivateSessionProvider is required");
	}

	return context;
};
