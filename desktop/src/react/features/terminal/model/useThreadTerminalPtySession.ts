import { useRef, useState } from "react";

import {
	createTerminalSessionController,
	type ServerWsEvent,
	type TerminalSessionChatState,
	type TerminalSessionState,
	type TerminalViewport,
} from "@remotecode/contracts";

export interface ThreadTerminalPtySessionDependencies {
	join: (chatId: string, viewport?: TerminalViewport) => void;
	leave: (chatId: string) => void;
	restart: (chatId: string, viewport?: TerminalViewport) => void;
	sendInput: (chatId: string, data: string) => void;
	sendResize: (chatId: string, viewport: TerminalViewport) => void;
	sendSignal: (chatId: string, signal: "SIGINT" | "SIGTERM") => void;
}

export interface UseThreadTerminalPtySessionResult {
	applyServerEvent: (event: ServerWsEvent) => void;
	restart: (chatId: string, viewport?: TerminalViewport) => void;
	sendInput: (chatId: string, data: string) => void;
	sendResize: (chatId: string, viewport: TerminalViewport) => void;
	sendSignal: (chatId: string, signal: "SIGINT" | "SIGTERM") => void;
	setOpen: (chatId: string, open: boolean, viewport?: TerminalViewport) => void;
	state: TerminalSessionState;
}

export const useThreadTerminalPtySession = (
	dependencies: ThreadTerminalPtySessionDependencies,
): UseThreadTerminalPtySessionResult => {
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
	const [, forceRender] = useState(0);

	const subscriptionRef = useRef(false);
	if (!subscriptionRef.current) {
		subscriptionRef.current = true;
		controllerRef.current.subscribe(() => {
			forceRender((value) => value + 1);
		});
	}

	return {
		applyServerEvent: controllerRef.current.applyServerEvent,
		restart: controllerRef.current.restart,
		sendInput: controllerRef.current.sendInput,
		sendResize: controllerRef.current.sendResize,
		sendSignal: controllerRef.current.sendSignal,
		setOpen: controllerRef.current.setOpen,
		state: controllerRef.current.getState(),
	};
};

export type ThreadTerminalPtyChatState = TerminalSessionChatState;
