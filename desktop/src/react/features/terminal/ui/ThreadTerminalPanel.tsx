import { useEffect, useRef, useState } from "react";

import { cn } from "../../../lib/utils";
import type { TerminalDisplayItem } from "../model/useThreadTerminalSession";

interface ThreadTerminalPanelProps {
	chatId: string;
	className?: string;
	error: string | null;
	isExecuting: boolean;
	isLoading: boolean;
	items: TerminalDisplayItem[];
	onRun: (command: string) => void | Promise<void>;
}

export const statusLabel = (input: { isExecuting: boolean; isLoading: boolean }): string => {
	if (input.isExecuting) {
		return "Running";
	}

	if (input.isLoading) {
		return "Loading";
	}

	return "Idle";
};

export const ThreadTerminalPanel = ({
	chatId,
	className,
	error,
	isExecuting,
	isLoading,
	items,
	onRun,
}: ThreadTerminalPanelProps): JSX.Element => {
	const [command, setCommand] = useState("");
	const outputRef = useRef<HTMLDivElement | null>(null);

	useEffect(() => {
		setCommand("");
	}, [chatId]);

	useEffect(() => {
		const outputElement = outputRef.current;
		if (!outputElement) {
			return;
		}

		outputElement.scrollTop = outputElement.scrollHeight;
	}, [items]);

	return (
		<section
			className={cn(
				"flex h-full min-h-0 flex-col overflow-hidden rounded-xl border border-white/10 bg-slate-950/80",
				className,
			)}
		>
			<header className="flex items-center justify-between border-b border-white/10 px-3 py-2 text-xs text-slate-300">
				<div className="flex items-center gap-2">
					<span className="font-semibold uppercase tracking-[0.12em] text-slate-200">Terminal</span>
					{isLoading ? <span className="text-slate-400">Syncing history...</span> : null}
				</div>
				<span className="text-slate-400">{statusLabel({ isExecuting, isLoading })}</span>
			</header>

			<div className="min-h-0 flex-1 overflow-hidden">
				<div className="h-full overflow-y-auto px-3 py-2" ref={outputRef}>
					{items.length === 0 ? (
						<p className="font-mono text-xs text-slate-500">No terminal history yet.</p>
					) : (
						<div className="space-y-1 font-mono text-xs">
							{items.map((item) => (
								<div
									className={cn(
										"whitespace-pre-wrap break-words",
										item.kind === "command" ? "text-slate-100" : "",
										item.kind === "stdout" ? "text-sky-100" : "",
										item.kind === "stderr" ? "text-rose-200" : "",
									)}
									key={item.id}
								>
									{item.text}
								</div>
							))}
						</div>
					)}
				</div>
			</div>

			<div className="border-t border-white/10 p-3">
				<form
					onSubmit={(event) => {
						event.preventDefault();
						const nextCommand = command.trim();
						if (!nextCommand || isExecuting) {
							return;
						}

						void Promise.resolve(onRun(nextCommand));
						setCommand("");
					}}
				>
					<div className="flex items-center gap-2">
						<input
							aria-label="Terminal command"
							className="h-10 min-w-0 flex-1 rounded-md border border-white/10 bg-slate-900/80 px-3 font-mono text-sm text-slate-100 outline-none transition focus:border-sky-300/50"
							disabled={isExecuting}
							onChange={(event) => {
								setCommand(event.target.value);
							}}
							placeholder='Run command (example: ls -la)'
							type="text"
							value={command}
						/>
						<button
							className="h-10 shrink-0 rounded-md border border-sky-300/30 bg-sky-400/10 px-4 text-sm font-medium text-sky-100 transition hover:bg-sky-400/20 disabled:cursor-not-allowed disabled:opacity-60"
							disabled={isExecuting || command.trim().length === 0}
							type="submit"
						>
							{isExecuting ? "Running..." : "Run"}
						</button>
					</div>
				</form>
				{error ? <p className="mt-2 text-xs text-rose-300">{error}</p> : null}
			</div>
		</section>
	);
};
