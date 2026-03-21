import "@xterm/xterm/css/xterm.css";

import { FitAddon } from "@xterm/addon-fit";
import { Terminal as XTerm } from "@xterm/xterm";
import { useEffect, useLayoutEffect, useRef } from "react";
import type {
	ClipboardEvent as ReactClipboardEvent,
	KeyboardEvent as ReactKeyboardEvent,
} from "react";

import type { TerminalViewport } from "@remotecode/contracts";

import { cn } from "../../../lib/utils";
import type { ThreadTerminalPtyChatState } from "../model/useThreadTerminalPtySession";

interface ThreadTerminalPtyPanelProps {
	chatId: string;
	className?: string;
	onInput: (data: string) => void;
	onInterrupt: () => void;
	onResize: (viewport: TerminalViewport) => void;
	onRestart: () => void;
	state: ThreadTerminalPtyChatState;
}

const resizeDebounceMs = 120;

type TerminalKeyEvent = {
	altKey: boolean;
	ctrlKey: boolean;
	key: string;
	metaKey: boolean;
};

const translateKeyEventToTerminalData = (event: TerminalKeyEvent): string | null => {
	if (event.metaKey || event.altKey) {
		return null;
	}

	if (event.ctrlKey) {
		if (event.key === " " || event.key === "Spacebar") {
			return "\0";
		}

		if (event.key.length === 1) {
			const upperKey = event.key.toUpperCase();
			const code = upperKey.charCodeAt(0);
			if (code >= 64 && code <= 95) {
				return String.fromCharCode(code - 64);
			}
		}
	}

	switch (event.key) {
		case "ArrowDown":
			return "\u001b[B";
		case "ArrowLeft":
			return "\u001b[D";
		case "ArrowRight":
			return "\u001b[C";
		case "ArrowUp":
			return "\u001b[A";
		case "Backspace":
			return "\u007f";
		case "Delete":
			return "\u001b[3~";
		case "End":
			return "\u001b[F";
		case "Enter":
			return "\r";
		case "Escape":
			return "\u001b";
		case "Home":
			return "\u001b[H";
		case "Tab":
			return "\t";
		default:
			return event.key.length === 1 ? event.key : null;
	}
};

const readVisibleTerminalBuffer = (term: XTerm): string => {
	const lines: string[] = [];
	const buffer = term.buffer.active;

	for (let lineIndex = 0; lineIndex < buffer.length; lineIndex += 1) {
		const line = buffer.getLine(lineIndex);
		if (!line) {
			continue;
		}

		lines.push(line.translateToString(true));
	}

	return lines.join("\n").trim();
};

export const ThreadTerminalPtyPanel = ({
	chatId,
	className,
	onInput,
	onInterrupt,
	onResize,
	onRestart,
	state,
}: ThreadTerminalPtyPanelProps): JSX.Element => {
	const containerRef = useRef<HTMLDivElement | null>(null);
	const termRef = useRef<XTerm | null>(null);
	const fitAddonRef = useRef<FitAddon | null>(null);
	const keyboardInputRef = useRef<HTMLTextAreaElement | null>(null);
	const inputHandlerRef = useRef(onInput);
	const resizeHandlerRef = useRef(onResize);
	const lastSnapshotRef = useRef<string>("");
	const lastSessionIdRef = useRef<string | null>(null);
	const lastOutputIdRef = useRef<string | null>(null);
	const lastOutputDataRef = useRef("");
	const resizeTimeoutRef = useRef<number | null>(null);
	const keyboardCaptureEnabledRef = useRef(false);

	const focusTerminal = () => {
		keyboardInputRef.current?.focus({ preventScroll: true });
	};

	const syncVisibleBufferText = () => {
		const terminalSurface = containerRef.current;
		const term = termRef.current;
		if (!terminalSurface || !term) {
			return;
		}

		terminalSurface.setAttribute("data-terminal-buffer-text", readVisibleTerminalBuffer(term));
	};

	const handleKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
		if (event.currentTarget !== event.target) {
			return;
		}

		const data = translateKeyEventToTerminalData(event);
		if (!data) {
			return;
		}

		event.preventDefault();
		inputHandlerRef.current(data);
	};

	const handlePaste = (event: ReactClipboardEvent<HTMLDivElement>) => {
		if (event.currentTarget !== event.target) {
			return;
		}

		const text = event.clipboardData.getData("text");
		if (!text) {
			return;
		}

		event.preventDefault();
		inputHandlerRef.current(text);
	};

	useEffect(() => {
		inputHandlerRef.current = onInput;
	}, [onInput]);

	useEffect(() => {
		resizeHandlerRef.current = onResize;
	}, [onResize]);

	useLayoutEffect(() => {
		const container = containerRef.current;
		if (!container) {
			return;
		}

		const term = new XTerm({
			allowProposedApi: true,
			convertEol: false,
			cursorBlink: true,
			fontFamily: "\"SF Mono\", ui-monospace, Menlo, monospace",
			fontSize: 13,
			rows: state.rows,
			screenReaderMode: true,
			scrollback: 5_000,
			theme: {
				background: "#020617",
				foreground: "#e2e8f0",
			},
		});
		const fitAddon = new FitAddon();
		term.loadAddon(fitAddon);
		let resizeObserver: ResizeObserver | null = null;
		let disposable: { dispose: () => void } | null = null;
		let resizeAnimationFrame: number | null = null;
		let mounted = false;

		const emitResize = () => {
			fitAddon.fit();
			resizeHandlerRef.current({
				cols: term.cols,
				rows: term.rows,
			});
		};

		const mountTerminal = () => {
			if (mounted) {
				return;
			}

			const { height, width } = container.getBoundingClientRect();
			if (width < 1 || height < 1) {
				resizeAnimationFrame = window.requestAnimationFrame(mountTerminal);
				return;
			}

			mounted = true;
			term.open(container);
			termRef.current = term;
			fitAddonRef.current = fitAddon;
			emitResize();
			syncVisibleBufferText();
			focusTerminal();

			resizeObserver = new ResizeObserver(() => {
				if (resizeTimeoutRef.current !== null) {
					window.clearTimeout(resizeTimeoutRef.current);
				}

				resizeTimeoutRef.current = window.setTimeout(() => {
					resizeTimeoutRef.current = null;
					emitResize();
				}, resizeDebounceMs);
			});
			resizeObserver.observe(container);

			disposable = term.onData((data) => {
				inputHandlerRef.current(data);
			});
		};

		const handleWindowPointerDown = (event: PointerEvent) => {
			const target = event.target;
			keyboardCaptureEnabledRef.current = target instanceof Node ? container.contains(target) : false;
			if (keyboardCaptureEnabledRef.current) {
				const activeElement = document.activeElement;
				if (activeElement instanceof HTMLElement && !container.contains(activeElement)) {
					activeElement.blur();
				}
				focusTerminal();
			}
		};

		const handleWindowKeyDown = (event: KeyboardEvent) => {
			if (!keyboardCaptureEnabledRef.current) {
				return;
			}

			const target = event.target;
			if (target instanceof HTMLElement && !container.contains(target) && target !== document.body) {
				return;
			}

			const data = translateKeyEventToTerminalData(event);
			if (!data) {
				return;
			}

			event.preventDefault();
			inputHandlerRef.current(data);
		};

		const handleWindowPaste = (event: ClipboardEvent) => {
			if (!keyboardCaptureEnabledRef.current) {
				return;
			}

			const target = event.target;
			if (target instanceof HTMLElement && !container.contains(target) && target !== document.body) {
				return;
			}

			const text = event.clipboardData?.getData("text");
			if (!text) {
				return;
			}

			event.preventDefault();
			inputHandlerRef.current(text);
		};

		mountTerminal();
		window.addEventListener("pointerdown", handleWindowPointerDown, true);
		window.addEventListener("keydown", handleWindowKeyDown, true);
		window.addEventListener("paste", handleWindowPaste, true);

		return () => {
			if (resizeAnimationFrame !== null) {
				window.cancelAnimationFrame(resizeAnimationFrame);
			}
			resizeObserver?.disconnect();
			disposable?.dispose();
			if (resizeTimeoutRef.current !== null) {
				window.clearTimeout(resizeTimeoutRef.current);
				resizeTimeoutRef.current = null;
			}
			window.removeEventListener("pointerdown", handleWindowPointerDown, true);
			window.removeEventListener("keydown", handleWindowKeyDown, true);
			window.removeEventListener("paste", handleWindowPaste, true);
			keyboardCaptureEnabledRef.current = false;
			term.dispose();
			termRef.current = null;
			fitAddonRef.current = null;
		};
	}, [chatId]);

	useEffect(() => {
		const term = termRef.current;
		if (!term) {
			return;
		}

		if (state.sessionId !== lastSessionIdRef.current || state.snapshot !== lastSnapshotRef.current) {
			lastSessionIdRef.current = state.sessionId;
			lastSnapshotRef.current = state.snapshot;
			lastOutputIdRef.current = null;
			lastOutputDataRef.current = "";
			term.reset();
			syncVisibleBufferText();
			if (state.snapshot.length > 0) {
				term.write(state.snapshot, () => {
					syncVisibleBufferText();
				});
			}
		}
	}, [state.sessionId, state.snapshot]);

	useEffect(() => {
		const term = termRef.current;
		if (!term || !state.lastOutput || state.lastOutput.id === lastOutputIdRef.current) {
			return;
		}

		lastOutputIdRef.current = state.lastOutput.id;
		const nextOutputData = state.lastOutput.data;
		const outputDelta =
			nextOutputData.startsWith(lastOutputDataRef.current)
				? nextOutputData.slice(lastOutputDataRef.current.length)
				: nextOutputData;
		lastOutputDataRef.current = nextOutputData;
		if (outputDelta.length === 0) {
			return;
		}

		term.write(outputDelta, () => {
			syncVisibleBufferText();
		});
	}, [state.lastOutput]);

	useEffect(() => {
		const term = termRef.current;
		if (!term) {
			return;
		}

		if (term.cols === state.cols && term.rows === state.rows) {
			return;
		}

		term.resize(state.cols, state.rows);
		syncVisibleBufferText();
	}, [state.cols, state.rows]);

	useEffect(() => {
		focusTerminal();
	}, [state.sessionId]);

	return (
		<section
			className={cn(
				"flex h-full min-h-0 flex-col overflow-hidden rounded-xl border border-white/10 bg-slate-950/90",
				className,
			)}
			data-testid="thread-terminal-panel"
		>
			<header className="flex items-center justify-between border-b border-white/10 px-3 py-2 text-xs text-slate-300">
				<div className="flex min-w-0 items-center gap-3">
					<span className="font-semibold uppercase tracking-[0.12em] text-slate-200">Terminal</span>
					<span className="truncate text-slate-400" data-testid="thread-terminal-cwd">
						{state.cwd ?? "Connecting..."}
					</span>
				</div>
				<div className="flex items-center gap-2">
					<span className="text-slate-400" data-testid="thread-terminal-status">
						{state.status}
					</span>
					<button
						className="rounded border border-white/10 px-2 py-1 text-slate-200 transition hover:bg-white/5"
						data-testid="thread-terminal-interrupt"
						onClick={onInterrupt}
						type="button"
					>
						Interrupt
					</button>
					<button
						className="rounded border border-white/10 px-2 py-1 text-slate-200 transition hover:bg-white/5"
						data-testid="thread-terminal-restart"
						onClick={onRestart}
						type="button"
					>
						Restart
					</button>
				</div>
			</header>

			<div className="min-h-0 flex-1">
				<div className="relative h-full w-full">
					<div
						className="h-full w-full cursor-text px-2 py-2"
						data-testid="thread-terminal-surface"
						onKeyDown={handleKeyDown}
						onMouseDown={() => {
							window.requestAnimationFrame(() => {
								focusTerminal();
							});
						}}
						onPaste={handlePaste}
						ref={containerRef}
						tabIndex={0}
					/>
					<textarea
						aria-label="Terminal input"
						autoCapitalize="off"
						autoComplete="off"
						autoCorrect="off"
						className="pointer-events-none absolute inset-0 z-10 h-full w-full resize-none border-0 bg-transparent text-transparent caret-transparent outline-none"
						data-testid="thread-terminal-keyboard-input"
						onChange={(event) => {
							event.currentTarget.value = "";
						}}
						onKeyDown={(event) => {
							const data = translateKeyEventToTerminalData(event);
							if (!data) {
								return;
							}

							event.preventDefault();
							inputHandlerRef.current(data);
						}}
						onPaste={(event) => {
							const text = event.clipboardData.getData("text");
							if (!text) {
								return;
							}

							event.preventDefault();
							inputHandlerRef.current(text);
						}}
						ref={keyboardInputRef}
						spellCheck={false}
					/>
				</div>
			</div>
		</section>
	);
};
