import {
	Bot,
	ChevronDown,
	ChevronRight,
	Cog,
	Lightbulb,
	ListTodo,
	Sparkles,
} from "lucide-react";
import React, { useEffect, useMemo, useRef } from "react";
import ReactMarkdown from "react-markdown";
import type { Components } from "react-markdown";
import remarkGfm from "remark-gfm";

import type { AssistantStreamItemState } from "../../../../shared/assistant-stream-event";
import { cn } from "../../../lib/utils";
import type { StreamItem, StreamTurnState } from "../../workspace/model/useWorkspaceStore";

interface StreamingTimelineProps {
	turn: StreamTurnState;
	focusMode: boolean;
	shouldReduceMotion: boolean;
	onSetItemExpanded: (itemId: string, expanded: boolean, byUser: boolean) => void;
	onSetItemState: (itemId: string, state: AssistantStreamItemState) => void;
}

interface StreamingTimelineRowProps {
	item: StreamItem;
	focusMode: boolean;
	shouldReduceMotion: boolean;
	onSetItemExpanded: (itemId: string, expanded: boolean, byUser: boolean) => void;
	onSetItemState: (itemId: string, state: AssistantStreamItemState) => void;
}

export const TOOL_AUTO_EXPAND_MS = 2_000;
export const AUTO_COLLAPSE_DELAY_MS = 600;

/**
 * Shared animation configuration for the tool-detail expand/collapse motion.
 * Extracted so tests can verify the values without rendering.
 */
export const DETAIL_EXPAND_TRANSITION = {
	duration: 0.25,
	ease: [0.4, 0, 0.2, 1] as readonly [number, number, number, number],
} as const;

export const DETAIL_EXPAND_WRAPPER_STYLE = { overflow: "hidden" as const };

const getItemIcon = (item: StreamItem) => {
	if (item.type === "tool") {
		return Cog;
	}
	if (item.type === "plan") {
		return ListTodo;
	}
	if (item.type === "assistant_message") {
		return Bot;
	}
	if (item.state === "running") {
		return Sparkles;
	}
	return Lightbulb;
};

const getStateLabel = (state: AssistantStreamItemState): string => {
	if (state === "running") {
		return "running";
	}
	if (state === "completed") {
		return "completed";
	}
	if (state === "failed") {
		return "failed";
	}
	if (state === "cancelled") {
		return "cancelled";
	}
	if (state === "preview") {
		return "preview";
	}
	return "collapsed";
};

const getStateTone = (state: AssistantStreamItemState): string => {
	if (state === "failed" || state === "cancelled") {
		return "text-rose-200";
	}
	if (state === "completed" || state === "preview" || state === "collapsed") {
		return "text-emerald-100";
	}
	return "text-sky-100";
};

const StreamingTimelineRow = ({
	item,
	focusMode,
	shouldReduceMotion,
	onSetItemExpanded,
	onSetItemState,
}: StreamingTimelineRowProps): JSX.Element => {
	const Icon = getItemIcon(item);
	const summaryText = item.summary.trim().length > 0
		? item.summary
		: item.type === "assistant_message"
			? "Writing response..."
			: item.type === "tool"
				? "Running command..."
				: item.type === "plan"
					? "Planning..."
					: "Thinking...";
	const detailText = useMemo(() => {
		if (item.type === "tool") {
			return [item.body.trim(), item.output.trim()].filter((entry) => entry.length > 0).join("\n\n");
		}

		return [item.body.trim(), item.output.trim()].filter((entry) => entry.length > 0).join("\n\n");
	}, [item.body, item.output, item.type]);
	const previewText = item.output.trim().length > 0
		? item.output.trim().replace(/\s+/g, " ").slice(0, 200)
		: item.body.trim().replace(/\s+/g, " ").slice(0, 200);
	const canToggle = detailText.length > 0;
	const showExpandedDetails = item.isExpanded && detailText.length > 0;
	const showPreview = item.state === "preview" && !item.isExpanded && previewText.length > 0;
	const assistantText = detailText.length > 0 ? detailText : summaryText;
	const assistantMarkdownComponents = useMemo<Components>(
		() => ({
			p: ({ children, ...props }) => (
				<p
					className={cn(
						focusMode ? "text-[15px] leading-7 text-slate-100" : "text-sm leading-6 text-slate-100",
						"[&_code]:text-inherit [&:not(:first-child)]:mt-3",
					)}
					{...props}
				>
					{children}
				</p>
			),
			ul: ({ children, ...props }) => <ul className="mb-2 mt-2 list-disc pl-5" {...props}>{children}</ul>,
			ol: ({ children, ...props }) => <ol className="mb-2 mt-2 list-decimal pl-5" {...props}>{children}</ol>,
			li: ({ children, ...props }) => <li className="mt-1" {...props}>{children}</li>,
			a: ({ children, href, ...props }) => (
				<a
					className="text-cyan-100 underline underline-offset-2 hover:text-white"
					href={href}
					rel="noreferrer noopener"
					target="_blank"
					{...props}
				>
					{children}
				</a>
			),
			code: (props) => {
				const { children, className, ...rest } = props;
				const inline = !className?.includes("language-");
				return inline ? (
					<code
						className={cn(
							"rounded bg-white/10 px-1.5 py-0.5 font-mono text-[13px] leading-none tracking-tight",
							focusMode ? "text-slate-100/95" : "text-cyan-100",
							className,
						)}
						{...rest}
					>
						{children}
					</code>
				) : (
					<code className={cn("block", className)} {...rest}>
						{children}
					</code>
				);
			},
			pre: ({ children, ...props }) => (
				<pre
					className={cn(
						"mb-3 mt-2 overflow-x-auto rounded-xl border border-white/15 bg-slate-950/75 p-3",
						focusMode ? "text-[13px] leading-6" : "text-[12px] leading-5",
					)}
					{...props}
				>
					{children}
				</pre>
			),
			blockquote: ({ children, ...props }) => (
				<blockquote className="mt-2 border-l-2 border-white/30 pl-3 italic" {...props}>
					{children}
				</blockquote>
			),
		}),
		[focusMode],
	);

	const prevStateRef = useRef(item.state);
	const autoCollapseTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

	useEffect(() => {
		if (item.type !== "tool" || shouldReduceMotion) {
			return;
		}

		if (item.state !== "running" || item.isExpanded || item.expandedByUser) {
			return;
		}

		const timer = setTimeout(() => {
			onSetItemExpanded(item.id, true, false);
		}, TOOL_AUTO_EXPAND_MS);

		return () => {
			clearTimeout(timer);
		};
	}, [
		item.expandedByUser,
		item.id,
		item.isExpanded,
		item.state,
		item.type,
		onSetItemExpanded,
		shouldReduceMotion,
	]);

	useEffect(() => {
		const wasRunning = prevStateRef.current === "running";
		prevStateRef.current = item.state;

		if (!wasRunning) {
			return;
		}

		const justCompleted = item.state === "completed" || item.state === "collapsed";
		if (!justCompleted) {
			return;
		}

		if (item.expandedByUser || !item.isExpanded) {
			return;
		}

		if (autoCollapseTimerRef.current !== null) {
			clearTimeout(autoCollapseTimerRef.current);
		}

		autoCollapseTimerRef.current = setTimeout(() => {
			autoCollapseTimerRef.current = null;
			onSetItemExpanded(item.id, false, false);
		}, AUTO_COLLAPSE_DELAY_MS);

		return () => {
			if (autoCollapseTimerRef.current !== null) {
				clearTimeout(autoCollapseTimerRef.current);
				autoCollapseTimerRef.current = null;
			}
		};
	}, [
		item.expandedByUser,
		item.id,
		item.isExpanded,
		item.state,
		onSetItemExpanded,
	]);

	// Clear the auto-collapse timer when the item changes (e.g. user switches chat).
	useEffect(() => {
		return () => {
			if (autoCollapseTimerRef.current !== null) {
				clearTimeout(autoCollapseTimerRef.current);
				autoCollapseTimerRef.current = null;
			}
		};
	}, [item.id]);

	if (item.type === "assistant_message") {
		return (
			<article className="py-1">
				<ReactMarkdown components={assistantMarkdownComponents} remarkPlugins={[remarkGfm]}>
					{assistantText}
				</ReactMarkdown>
			</article>
		);
	}

	return (
		<article
			className={cn(
				"rounded-2xl border px-3 py-2.5",
				focusMode ? "border-white/10 bg-white/[0.03]" : "border-sky-300/20 bg-sky-500/[0.06]",
			)}
		>
			<div className="flex items-start gap-2.5">
				<Icon className={cn("mt-0.5 h-4 w-4 shrink-0", getStateTone(item.state))} />
				<div className="min-w-0 flex-1">
					<div className="flex items-start gap-3">
						<p
							className={cn(
								"min-w-0 flex-1 truncate text-sm leading-6",
								item.state === "running" ? "loading-shimmer-pure-text" : "",
								focusMode ? "text-slate-100" : "text-sky-50",
							)}
						>
							{summaryText}
						</p>
						<span
							className={cn(
								"mt-0.5 rounded-full border px-1.5 py-0.5 text-[10px] uppercase tracking-[0.16em] transition-all duration-200 ease-out",
								item.state === "failed" || item.state === "cancelled"
									? "border-rose-300/35 bg-rose-400/10 text-rose-100"
									: item.state === "completed" || item.state === "preview" || item.state === "collapsed"
										? "border-emerald-300/35 bg-emerald-400/10 text-emerald-100"
										: "border-sky-300/35 bg-sky-400/10 text-sky-100",
							)}
						>
							{getStateLabel(item.state)}
						</span>
					</div>

					{showPreview ? (
						<p className={cn("mt-1 text-xs leading-5 text-slate-300/90", focusMode ? "" : "text-sky-100/80")}>
							{previewText}
						</p>
					) : null}

					<div
						className={cn(
							"grid transition-[grid-template-rows,opacity] duration-[250ms] ease-[cubic-bezier(0.4,0,0.2,1)] motion-reduce:transition-none",
							showExpandedDetails
								? "grid-rows-[1fr] opacity-100"
								: "grid-rows-[0fr] opacity-0",
						)}
						style={DETAIL_EXPAND_WRAPPER_STYLE}
					>
						<div className="min-h-0 overflow-hidden">
							<pre
								className={cn(
									"mt-2 overflow-x-auto rounded-xl border border-white/15 bg-slate-950/80 p-2.5 text-[12px] leading-5 text-slate-100",
								)}
							>
								{detailText}
							</pre>
						</div>
					</div>
				</div>
				{canToggle ? (
					<button
						aria-label={item.isExpanded ? "Collapse stream item" : "Expand stream item"}
						className={cn(
							"rounded-md border border-white/15 bg-white/[0.03] p-1.5 text-slate-200 transition hover:bg-white/[0.07]",
						)}
						onClick={() => {
							const nextExpanded = !item.isExpanded;
							onSetItemExpanded(item.id, nextExpanded, true);
							if (nextExpanded && item.state === "collapsed") {
								onSetItemState(item.id, "completed");
							}
						}}
						type="button"
					>
						{item.isExpanded ? <ChevronDown className="h-3.5 w-3.5" /> : <ChevronRight className="h-3.5 w-3.5" />}
					</button>
				) : null}
			</div>
		</article>
	);
};

const StreamingTimelineImpl = ({
	turn,
	focusMode,
	shouldReduceMotion,
	onSetItemExpanded,
	onSetItemState,
}: StreamingTimelineProps): JSX.Element => {
	if (turn.itemOrder.length === 0) {
		return <></>;
	}

	return (
		<div className={cn("space-y-2")}>
			{turn.itemOrder
				.map((itemId) => turn.itemsById[itemId])
				.filter((item): item is StreamItem => Boolean(item))
				.filter((item) => {
					if (
						item.type === "reasoning" &&
						item.state !== "running" &&
						item.summary.trim().length === 0 &&
						item.body.trim().length === 0
					) {
						return false;
					}
					return true;
				})
				.map((item) => (
					<StreamingTimelineRow
						focusMode={focusMode}
						item={item}
						key={item.id}
						onSetItemExpanded={onSetItemExpanded}
						onSetItemState={onSetItemState}
						shouldReduceMotion={shouldReduceMotion}
					/>
				))}
		</div>
	);
};

export const StreamingTimeline = React.memo(StreamingTimelineImpl);
StreamingTimeline.displayName = "StreamingTimeline";
