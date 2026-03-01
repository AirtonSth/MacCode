import { AnimatePresence, motion } from "framer-motion";
import {
	Bot,
	ChevronDown,
	ChevronRight,
	Cog,
	Lightbulb,
	ListTodo,
	Sparkles,
} from "lucide-react";
import { useEffect, useMemo } from "react";

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

const TOOL_AUTO_EXPAND_MS = 2_000;
const TOOL_COLLAPSE_DELAY_MS = 200;

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
		if (item.type !== "tool") {
			return;
		}

		if (item.state !== "completed" || !item.isExpanded || item.expandedByUser) {
			return;
		}

		if (shouldReduceMotion) {
			onSetItemExpanded(item.id, false, false);
			onSetItemState(item.id, "collapsed");
			return;
		}

		onSetItemState(item.id, "preview");
		const timer = setTimeout(() => {
			onSetItemExpanded(item.id, false, false);
			onSetItemState(item.id, "collapsed");
		}, TOOL_COLLAPSE_DELAY_MS);

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
		onSetItemState,
		shouldReduceMotion,
	]);

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
					<div className="flex items-start justify-between gap-3">
						<p
							className={cn(
								"text-sm leading-6",
								item.state === "running" ? "loading-shimmer-pure-text" : "",
								focusMode ? "text-slate-100" : "text-sky-50",
							)}
						>
							{summaryText}
						</p>
						<span
							className={cn(
								"mt-0.5 rounded-full border px-1.5 py-0.5 text-[10px] uppercase tracking-[0.16em]",
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

					<AnimatePresence initial={false}>
						{showExpandedDetails ? (
							<motion.pre
								animate={shouldReduceMotion ? undefined : { opacity: 1, height: "auto" }}
								className={cn(
									"mt-2 overflow-x-auto rounded-xl border border-white/15 bg-slate-950/80 p-2.5 text-[12px] leading-5 text-slate-100",
								)}
								exit={shouldReduceMotion ? undefined : { opacity: 0, height: 0 }}
								initial={shouldReduceMotion ? undefined : { opacity: 0, height: 0 }}
							>
								{detailText}
							</motion.pre>
						) : null}
					</AnimatePresence>
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

export const StreamingTimeline = ({
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
