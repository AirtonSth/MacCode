import { useRef, useState } from "react";

import {
	createTerminalSessionController,
	type TerminalSessionChatState,
	type TerminalSessionState,
	type TerminalViewport,
} from "@remotecode/contracts";

import type { ServerWsEvent } from "../../../shared/api/types";

type TerminalServerWsEvent = Extract<
	ServerWsEvent,
	{ event: "terminal_session_snapshot" | "terminal_output" | "terminal_session_state" }
>;

export interface TerminalPtySessionDependencies {
	join: (chatId: string, viewport?: TerminalViewport) => void;
	leave: (chatId: string) => void;
	restart: (chatId: string, viewport?: TerminalViewport) => void;
	sendInput: (chatId: string, data: string) => void;
	sendResize: (chatId: string, viewport: TerminalViewport) => void;
	sendSignal: (chatId: string, signal: "SIGINT" | "SIGTERM") => void;
}

export interface UseTerminalPtySessionResult {
	applyServerEvent: (event: TerminalServerWsEvent) => void;
	restart: (chatId: string, viewport?: TerminalViewport) => void;
	sendInput: (chatId: string, data: string) => void;
	sendResize: (chatId: string, viewport: TerminalViewport) => void;
	sendSignal: (chatId: string, signal: "SIGINT" | "SIGTERM") => void;
	setOpen: (chatId: string, open: boolean, viewport?: TerminalViewport) => void;
	state: TerminalSessionState;
}

export const useTerminalPtySession = (
	dependencies: TerminalPtySessionDependencies,
): UseTerminalPtySessionResult => {
	const dependenciesRef = useRef(dependencies);
	dependenciesRef.current = dependencies;

	const controllerRef = useRef(
		createTerminalSessionController(() => ({
			join: (chatId, viewport) => {
				dependenciesRef.current.join(chatId, viewport);
			},
			leave: (chatId) => {
				dependenciesRef.current.leave(chatId);
			},
			restart: (chatId, viewport) => {
				dependenciesRef.current.restart(chatId, viewport);
			},
			sendInput: (chatId, data) => {
				dependenciesRef.current.sendInput(chatId, data);
			},
			sendResize: (chatId, viewport) => {
				dependenciesRef.current.sendResize(chatId, viewport);
			},
			sendSignal: (chatId, signal) => {
				dependenciesRef.current.sendSignal(chatId, signal);
			},
		})),
	);
	const [renderVersion, setRenderVersion] = useState(0);
	void renderVersion;

	const isSubscribedRef = useRef(false);
	if (!isSubscribedRef.current) {
		isSubscribedRef.current = true;
		controllerRef.current.subscribe(() => {
			setRenderVersion((value) => value + 1);
		});
	}

	return {
		applyServerEvent: (event) => {
			controllerRef.current.applyServerEvent(event);
		},
		restart: controllerRef.current.restart,
		sendInput: controllerRef.current.sendInput,
		sendResize: controllerRef.current.sendResize,
		sendSignal: controllerRef.current.sendSignal,
		setOpen: controllerRef.current.setOpen,
		state: controllerRef.current.getState(),
	};
};

export type TerminalPtyChatState = TerminalSessionChatState;
