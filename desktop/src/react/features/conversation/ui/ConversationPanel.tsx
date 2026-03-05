import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { AlertTriangle, Bot, ChevronDown, Loader2, Sparkles, User2 } from "lucide-react";
import { Badge } from "../../../components/ui/badge";
import { ScrollArea } from "../../../components/ui/scroll-area";
import ReactMarkdown from "react-markdown";
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { cn } from "../../../lib/utils";
import remarkGfm from "remark-gfm";
import type { Components } from "react-markdown";
import type { AssistantStreamItemState } from "../../../../shared/assistant-stream-event";
import type { ChatDTO, MessageDTO, StreamTurnState } from "../../workspace/model/useWorkspaceStore";
import { StreamingTimeline } from "./StreamingTimeline";

interface ConversationPanelProps {
	chat: ChatDTO | null;
	messages: MessageDTO[];
	streamHistoryTurns: StreamTurnState[];
	streamingText: string;
	streamingTurn: StreamTurnState | null;
	isWorking: boolean;
	loading: boolean;
	hasRestError: boolean;
	onSetStreamItemExpanded: (itemId: string, expanded: boolean, byUser: boolean) => void;
	onSetStreamItemState: (itemId: string, state: AssistantStreamItemState) => void;
	focusMode?: boolean;
}

export const ConversationPanel = ({
	chat,
	messages,
	streamHistoryTurns,
	streamingText,
	streamingTurn,
	isWorking,
	loading,
	hasRestError,
	onSetStreamItemExpanded,
	onSetStreamItemState,
	focusMode = false,
}: ConversationPanelProps): JSX.Element => {
	const shouldReduceMotion = Boolean(useReducedMotion());
	const hasMessages = messages.length > 0;
	const hasStreamingTimeline = Boolean(streamingTurn && streamingTurn.itemOrder.length > 0);
	const hasStreamingText = streamingText.trim().length > 0;
	const liveTurn = hasStreamingTimeline ? streamingTurn : null;
	const historicalTurns = useMemo(() => {
		if (!liveTurn) {
			return streamHistoryTurns;
		}

		return streamHistoryTurns.filter((turn) => turn.turnId !== liveTurn.turnId);
	}, [liveTurn, streamHistoryTurns]);
	const hasHistoricalRunDetails = historicalTurns.length > 0;
	const hasStreaming = hasStreamingTimeline || hasStreamingText;
	const hasContent = hasMessages || hasStreaming || isWorking;
	const [showRunDetails, setShowRunDetails] = useState(false);
	const [isAtBottom, setIsAtBottom] = useState(true);
	const scrollViewportRef = useRef<HTMLDivElement>(null);
	const stickToBottomRef = useRef(true);
	const bubbleMotion = shouldReduceMotion
		? {}
		: {
				animate: { opacity: 1, y: 0 },
				exit: { opacity: 0, y: -4 },
				initial: { opacity: 0, y: 8 },
				transition: { duration: 0.2, ease: "easeOut" as const },
			};
	const scrollToBottom = useCallback(
		(behavior: ScrollBehavior = "smooth") => {
			const viewport = scrollViewportRef.current;
			if (!viewport) {
				return;
			}
			viewport.scrollTo({
				top: viewport.scrollHeight,
				behavior: shouldReduceMotion ? "auto" : behavior,
			});
		},
		[shouldReduceMotion],
	);
	const handleViewportScroll = useCallback(() => {
		const viewport = scrollViewportRef.current;
		if (!viewport) {
			return;
		}
		const distanceFromBottom = viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
		const nextIsAtBottom = distanceFromBottom <= 24;
		stickToBottomRef.current = nextIsAtBottom;
		setIsAtBottom(nextIsAtBottom);
	}, []);
	useEffect(() => {
		stickToBottomRef.current = true;
		setIsAtBottom(true);
		setShowRunDetails(false);
	}, [chat?.id]);

	useLayoutEffect(() => {
		if (!hasContent) {
			return;
		}
		if (stickToBottomRef.current) {
			scrollToBottom("auto");
		}
	}, [hasContent, historicalTurns, liveTurn, messages, scrollToBottom, streamingText]);
	const messageTextClass = focusMode ? "text-[15px] leading-7" : "text-sm leading-6";
	const markdownComponents: Components = {
		h1: ({ children, ...props }) => <h1 className="mb-2 mt-3 text-lg font-semibold" {...props}>{children}</h1>,
		h2: ({ children, ...props }) => <h2 className="mb-2 mt-3 text-base font-semibold" {...props}>{children}</h2>,
		h3: ({ children, ...props }) => <h3 className="mb-1 mt-3 font-semibold" {...props}>{children}</h3>,
		p: ({ children, ...props }) => (
			<p className={cn(messageTextClass, "[&_code]:text-inherit [&:not(:first-child)]:mt-3")} {...props}>
				{children}
			</p>
		),
		ul: ({ children, ...props }) => <ul className="mb-2 mt-2 list-disc pl-5" {...props}>{children}</ul>,
		ol: ({ children, ...props }) => <ol className="mb-2 mt-2 list-decimal pl-5" {...props}>{children}</ol>,
		li: ({ children, ...props }) => <li className="mt-1" {...props}>{children}</li>,
		a: ({ children, href, ...props }) => (
			<a className="text-cyan-100 underline underline-offset-2 hover:text-white" href={href} rel="noreferrer noopener" target="_blank" {...props}>
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
		table: ({ children, ...props }) => (
			<div className="my-2 overflow-x-auto">
				<table className="w-full border-collapse text-left" {...props}>
					{children}
				</table>
			</div>
		),
		th: ({ children, ...props }) => <th className="border-b border-white/20 px-2 py-1 text-left text-xs font-semibold" {...props}>{children}</th>,
		td: ({ children, ...props }) => <td className="border-b border-white/10 px-2 py-1 align-top" {...props}>{children}</td>,
	};

	return (
		<section
			className={cn(
				"relative flex h-full min-h-0 flex-col overflow-hidden",
				focusMode
					? "bg-transparent"
					: "rounded-[28px] border border-white/10 bg-slate-950/55 backdrop-blur-2xl",
			)}
		>
			{focusMode ? null : (
					<header className="flex flex-wrap items-center justify-between gap-3 px-5 py-4">
					<div>
						<h2 className="m-0 text-sm font-semibold tracking-wide text-slate-100">
							{chat ? chat.title : "No chat selected"}
						</h2>
						<p className="mt-1 text-xs text-slate-400">
							{chat
								? "Thread stream and patch deltas from the assistant."
								: "Select a thread to start a conversation."}
						</p>
					</div>
					{chat ? (
						<div className="flex flex-wrap items-center gap-2">
							<Badge
								className={cn(
									"capitalize",
									chat.status === "running"
										? "border-sky-300/25 bg-sky-400/10 text-sky-100"
										: chat.status === "completed"
											? "border-emerald-300/25 bg-emerald-400/10 text-emerald-100"
											: chat.status === "failed"
												? "border-rose-300/25 bg-rose-400/10 text-rose-100"
												: "border-amber-300/25 bg-amber-400/10 text-amber-100",
								)}
								variant="outline"
							>
								{chat.status}
							</Badge>
							<Badge className="border-emerald-300/25 bg-emerald-400/10 text-emerald-100" variant="outline">
								+{chat.diffAdded}
							</Badge>
							<Badge className="border-rose-300/25 bg-rose-400/10 text-rose-100" variant="outline">
								-{chat.diffRemoved}
							</Badge>
						</div>
					) : null}
				</header>
			)}

			<div className="relative flex min-h-0 flex-1 flex-col">
				{loading ? (
					<p className={cn("text-xs text-slate-300/80", focusMode ? "px-4 py-3 sm:px-6" : "px-5 py-3")}>
						Loading messages...
					</p>
				) : null}

				{hasRestError ? (
					<div
						className={cn(
							"flex items-center gap-2 rounded-xl border border-amber-300/30 bg-amber-400/10 px-3 py-2 text-xs text-amber-100",
							focusMode ? "mx-4 mt-3 sm:mx-6" : "mx-5 mt-3",
						)}
					>
						<AlertTriangle className="h-3.5 w-3.5" />
						Some data may be outdated. Check errors in the activity log.
					</div>
				) : null}

				{!chat ? (
					<div className="m-5 grid place-items-center gap-2 rounded-2xl border border-dashed border-white/20 bg-white/[0.02] px-4 py-8 text-center">
						<Sparkles className="h-5 w-5 text-slate-300/70" />
						<p className="text-sm text-slate-200">Select a chat to start a conversation.</p>
					</div>
				) : null}

				{chat && !loading && !hasContent ? (
					<div
						className={cn(
							"grid place-items-center gap-2 px-4 py-8 text-center",
							focusMode
								? "mx-auto mt-8 max-w-xl rounded-2xl border border-white/10 bg-white/[0.02]"
								: "m-5 rounded-2xl border border-dashed border-white/20 bg-white/[0.02]",
						)}
					>
						<Bot className="h-5 w-5 text-slate-300/70" />
						<p className="text-sm text-slate-200">No messages yet. Send your first message.</p>
					</div>
				) : null}

				{hasContent ? (
					<>
						{hasHistoricalRunDetails ? (
							<div className={cn("px-5 pt-3", focusMode ? "sm:px-6" : "")}>
								<button
									className={cn(
										"rounded-lg border px-2.5 py-1 text-xs transition",
										showRunDetails
											? "border-sky-300/40 bg-sky-400/12 text-sky-100"
											: "border-white/15 bg-white/[0.03] text-slate-300 hover:text-slate-100",
									)}
									onClick={() => {
										setShowRunDetails((value) => !value);
									}}
									type="button"
								>
									{showRunDetails ? "Hide run details" : "Show run details"}
								</button>
							</div>
						) : null}
						<ScrollArea className="relative h-full" onViewportScroll={handleViewportScroll} viewportRef={scrollViewportRef}>
							<div
								aria-live="polite"
								className={cn(
									"mx-auto w-full max-w-3xl",
									focusMode ? "space-y-2 px-4 pb-8 pt-5 sm:px-6" : "space-y-3 px-5 pb-5 pt-4",
								)}
							>
								<AnimatePresence initial={false}>
									{messages.map((message) => (
										<motion.article
											className={cn(
												focusMode
													? message.role === "user"
														? "ml-auto w-fit max-w-[min(86%,40rem)] rounded-[1.35rem] border border-white/10 bg-white/[0.06] px-4 py-3 text-[15px] leading-7 text-slate-100 shadow-[0_10px_30px_rgba(2,6,23,0.16)]"
														: "w-full py-4 text-[15px] leading-7 text-slate-100"
													: cn(
															"max-w-[85ch] rounded-2xl border px-4 py-3 shadow-[0_18px_40px_rgba(2,6,23,0.35)]",
															message.role === "user"
																? "ml-auto border-cyan-300/25 bg-cyan-400/10 text-cyan-50"
																: "mr-auto border-white/10 bg-slate-900/85 text-slate-100",
														),
											)}
											key={message.id}
											{...bubbleMotion}
										>
											{focusMode ? null : (
												<div className="mb-2 flex items-center gap-2 text-[11px] uppercase tracking-[0.18em] text-slate-300/85">
													{message.role === "user" ? <User2 className="h-3.5 w-3.5" /> : <Bot className="h-3.5 w-3.5" />}
													{message.role}
												</div>
											)}
											<ReactMarkdown remarkPlugins={[remarkGfm]} components={markdownComponents}>
												{message.content}
											</ReactMarkdown>
										</motion.article>
									))}

									{liveTurn ? (
										<StreamingTimeline
											focusMode={focusMode}
											key={`stream-live-${liveTurn.turnId}`}
											onSetItemExpanded={onSetStreamItemExpanded}
											onSetItemState={onSetStreamItemState}
											shouldReduceMotion={shouldReduceMotion}
											turn={liveTurn}
										/>
									) : null}

									{showRunDetails
										? historicalTurns.map((turn) => (
												<StreamingTimeline
													focusMode={focusMode}
													key={`stream-turn-${turn.turnId}`}
													onSetItemExpanded={onSetStreamItemExpanded}
													onSetItemState={onSetStreamItemState}
													shouldReduceMotion={shouldReduceMotion}
													turn={turn}
												/>
											))
										: null}

									{streamingText && !hasStreamingTimeline ? (
										<motion.article
											className={cn(
												focusMode
													? "w-full py-4 text-[15px] leading-7 text-slate-100"
													: "mr-auto max-w-[85ch] rounded-2xl border border-sky-200/20 bg-sky-500/10 px-4 py-3 text-sky-50 shadow-[0_18px_40px_rgba(2,6,23,0.35)]",
											)}
											key="streaming"
											{...bubbleMotion}
										>
											<div
												className={cn(
													"mb-2 flex items-center gap-2",
													focusMode
														? "text-xs tracking-[0.12em] text-slate-400"
														: "text-[11px] uppercase tracking-[0.18em] text-sky-100/90",
												)}
											>
												<Sparkles className="h-3.5 w-3.5" />
												{focusMode ? "Assistant is writing" : "assistant · streaming"}
												<motion.span
													animate={shouldReduceMotion ? undefined : { opacity: [0.3, 1, 0.3] }}
													className={cn("h-1.5 w-1.5 rounded-full", focusMode ? "bg-slate-300" : "bg-sky-100")}
													transition={{ duration: 1.2, repeat: Number.POSITIVE_INFINITY }}
												/>
											</div>
											<p className={cn("whitespace-pre-wrap", focusMode ? "" : "text-sm leading-6")}>{streamingText}</p>
										</motion.article>
									) : null}

									{isWorking ? (
										<motion.article
											{...bubbleMotion}
											aria-label="working-indicator"
											className={cn(
												"mr-auto inline-flex items-center gap-2 rounded-xl border border-sky-300/25 bg-sky-400/10 px-3 py-2 text-sm text-sky-100",
												focusMode ? "mt-2" : "",
											)}
											data-testid="conversation-working-indicator"
											key="conversation-working-indicator"
										>
											<Loader2 className="h-4 w-4 animate-spin" />
											<span>Working...</span>
										</motion.article>
									) : null}
								</AnimatePresence>
							</div>
						</ScrollArea>
						{!isAtBottom ? (
							<button
								aria-label="Scroll to latest message"
								className={cn(
									"absolute bottom-4 right-4 z-20 rounded-full border border-white/20 bg-slate-900/90 p-2 text-slate-100 shadow-[0_10px_30px_rgba(2,6,23,0.45)] transition hover:bg-slate-800/95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/80 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-950",
									focusMode ? "bg-slate-950/80" : "",
								)}
								onClick={() => {
									scrollToBottom();
								}}
								type="button"
							>
								<ChevronDown className="h-4 w-4" />
							</button>
						) : null}
					</>
				) : null}
			</div>
		</section>
	);
};
