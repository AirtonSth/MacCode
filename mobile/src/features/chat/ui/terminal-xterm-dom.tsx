"use dom";

import "@xterm/xterm/css/xterm.css";

import { FitAddon } from "@xterm/addon-fit";
import { Terminal as XTerm } from "@xterm/xterm";
import { useEffect, useLayoutEffect, useRef } from "react";
import type { DOMProps } from "expo/dom";

interface TerminalXtermDomProps {
	chatId: string;
	dom?: DOMProps;
	isCtrlModeActive: boolean;
	lastOutputData: string;
	lastOutputId: string | null;
	onCtrlModeActiveChange?: (active: boolean) => Promise<void> | void;
	onInput: (data: string) => Promise<void> | void;
	onResize: (viewport: { cols: number; rows: number }) => Promise<void> | void;
	sessionId: string | null;
	snapshot: string;
}

const resizeDebounceMs = 120;

const toControlCharacter = (input: string): string | null => {
	if (input.length !== 1) {
		return null;
	}

	const upper = input.toUpperCase();
	const code = upper.codePointAt(0);
	if (code === undefined) {
		return null;
	}

	if (code >= 64 && code <= 95) {
		return String.fromCodePoint(code - 64);
	}

	if (code === 32) {
		return "\u0000";
	}

	return null;
};

export default function TerminalXtermDom({
	chatId,
	dom = undefined,
	isCtrlModeActive,
	lastOutputData,
	lastOutputId,
	onCtrlModeActiveChange = undefined,
	onInput,
	onResize,
	sessionId,
	snapshot,
}: TerminalXtermDomProps) {
	void dom;
	const containerRef = useRef<HTMLDivElement | null>(null);
	const terminalRef = useRef<XTerm | null>(null);
	const fitAddonRef = useRef<FitAddon | null>(null);
	const resizeTimeoutRef = useRef<ReturnType<typeof globalThis.setTimeout> | null>(null);
	const lastSnapshotRef = useRef<string>("");
	const lastSessionIdRef = useRef<string | null>(null);
	const lastOutputIdRef = useRef<string | null>(null);

	useLayoutEffect(() => {
		const container = containerRef.current;
		if (!container) {
			return undefined;
		}

		const terminal = new XTerm({
			allowProposedApi: true,
			convertEol: false,
			cursorBlink: true,
			fontFamily: "\"SF Mono\", Menlo, Monaco, Consolas, monospace",
			fontSize: 13,
			rows: 32,
			scrollback: 5_000,
			theme: {
				background: "#08101c",
				foreground: "#e7edf7",
			},
		});
		const fitAddon = new FitAddon();
		terminal.loadAddon(fitAddon);
		terminal.open(container);
		terminalRef.current = terminal;
		fitAddonRef.current = fitAddon;

		const emitResize = () => {
			fitAddon.fit();
			void onResize({
				cols: terminal.cols,
				rows: terminal.rows,
			});
		};

		globalThis.requestAnimationFrame(() => {
			emitResize();
			terminal.focus();
		});

		const resizeObserver = new ResizeObserver(() => {
			if (resizeTimeoutRef.current !== null) {
				globalThis.clearTimeout(resizeTimeoutRef.current);
			}

			resizeTimeoutRef.current = globalThis.setTimeout(() => {
				resizeTimeoutRef.current = null;
				emitResize();
			}, resizeDebounceMs);
		});
		resizeObserver.observe(container);

		const disposable = terminal.onData((data) => {
			if (isCtrlModeActive) {
				const firstCharacter = data[0] ?? "";
				const controlCharacter = toControlCharacter(firstCharacter);
				if (controlCharacter !== null) {
					void onInput(controlCharacter);
					if (data.length > 1) {
						void onInput(data.slice(1));
					}
				} else {
					void onInput(data);
				}
				void onCtrlModeActiveChange?.(false);
				return;
			}

			void onInput(data);
		});

		const handlePointerDown = () => {
			terminal.focus();
		};
		container.addEventListener("pointerdown", handlePointerDown);

		return () => {
			container.removeEventListener("pointerdown", handlePointerDown);
			disposable.dispose();
			resizeObserver.disconnect();
			if (resizeTimeoutRef.current !== null) {
				globalThis.clearTimeout(resizeTimeoutRef.current);
				resizeTimeoutRef.current = null;
			}
			terminal.dispose();
			terminalRef.current = null;
			fitAddonRef.current = null;
		};
	}, [chatId, isCtrlModeActive, onCtrlModeActiveChange, onInput, onResize]);

	useEffect(() => {
		const terminal = terminalRef.current;
		if (!terminal) {
			return;
		}

		if (sessionId !== lastSessionIdRef.current || snapshot !== lastSnapshotRef.current) {
			lastSessionIdRef.current = sessionId;
			lastSnapshotRef.current = snapshot;
			lastOutputIdRef.current = null;
			terminal.reset();
			if (snapshot.length > 0) {
				terminal.write(snapshot);
			}
			globalThis.requestAnimationFrame(() => {
				fitAddonRef.current?.fit();
			});
		}
	}, [sessionId, snapshot]);

	useEffect(() => {
		const terminal = terminalRef.current;
		if (!terminal || !lastOutputId || lastOutputId === lastOutputIdRef.current) {
			return;
		}

		lastOutputIdRef.current = lastOutputId;
		terminal.write(lastOutputData);
	}, [lastOutputData, lastOutputId]);

	return (
		<div
			style={{
				background: "#08101c",
				border: "1px solid rgba(255,255,255,0.08)",
				borderRadius: "16px",
				height: "100%",
				minHeight: 0,
				overflow: "hidden",
				width: "100%",
			}}
		>
			<div
				ref={containerRef}
				style={{
					height: "100%",
					padding: "10px 8px",
					width: "100%",
				}}
			/>
		</div>
	);
}
