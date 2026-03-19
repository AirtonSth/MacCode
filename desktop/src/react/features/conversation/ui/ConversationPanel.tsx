import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { AlertTriangle, Bot, Check, ChevronDown, Copy, Loader2, Sparkles, User2 } from "lucide-react";
import { Badge } from "../../../components/ui/badge";
import { ScrollArea } from "../../../components/ui/scroll-area";
import ReactMarkdown from "react-markdown";
import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { cn } from "../../../lib/utils";
import remarkGfm from "remark-gfm";
import type { Components } from "react-markdown";
import type { AssistantStreamItemState } from "../../../../shared/assistant-stream-event";
import type { ChatDTO, MessageDTO, StreamTurnState } from "../../workspace/model/useWorkspaceStore";
import { StreamingTimeline } from "./StreamingTimeline";

const remarkPlugins = [remarkGfm];

/** Threshold (px) for considering the viewport "at the bottom" (D-18). */
export const SCROLL_BOTTOM_THRESHOLD_PX = 80;

/** Debounce delay (ms) before top-pagination fires (D-20). */
export const TOP_PAGINATION_DEBOUNCE_MS = 300;

const extractTextFromChildren = (children: React.ReactNode): string => {
	if (typeof children === "string") return children;
	if (typeof children === "number") return String(children);
	if (!children) return "";
	if (Array.isArray(children)) return children.map(extractTextFromChildren).join("");
	if (typeof children === "object" && "props" in children) {
		return extractTextFromChildren((children as { props: { children?: React.ReactNode } }).props.children);
	}
	return "";
};

const hasActiveSelection = (): boolean => {
	const selection = window.getSelection();
	return Boolean(selection && selection.type === "Range" && selection.toString().length > 0);
};

const CopyButton = React.memo(({ text, className }: { text: string; className?: string }) => {
	const [copied, setCopied] = useState(false);
	const resetCopiedTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
	const handleCopy = useCallback(() => {
		void navigator.clipboard.writeText(text).then(() => {
			setCopied(true);
			if (resetCopiedTimerRef.current) {
				clearTimeout(resetCopiedTimerRef.current);
			}
			resetCopiedTimerRef.current = setTimeout(() => {
				resetCopiedTimerRef.current = null;
				setCopied(false);
			}, 1800);
		});
	}, [text]);

	useEffect(() => {
		return () => {
			if (resetCopiedTimerRef.current) {
				clearTimeout(resetCopiedTimerRef.current);
				resetCopiedTimerRef.current = null;
			}
		};
	}, []);

	return (
		<button
			aria-label={copied ? "Copied" : "Copy"}
			className={cn(
				"inline-flex items-center justify-center rounded-md p-1 text-slate-400 transition-all hover:bg-white/10 hover:text-slate-200",
				copied && "text-emerald-400 hover:text-emerald-300",
				className,
			)}
			onClick={handleCopy}
			type="button"
		>
			{copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
		</button>
	);
});
CopyButton.displayName = "CopyButton";

const buildMarkdownComponents = (focusMode: boolean): Components => {
	const messageTextClass = focusMode ? "text-[15px] leading-6" : "text-sm leading-6";
	return {
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
		pre: ({ children, ...props }) => {
			const codeText = extractTextFromChildren(children);
			return (
				<div className="group/code relative mb-3 mt-2">
					<pre
						className={cn(
							"overflow-x-auto rounded-xl border border-white/15 bg-slate-950/75 p-3 pr-10",
							focusMode ? "text-[13px] leading-6" : "text-[12px] leading-5",
						)}
						{...props}
					>
						{children}
					</pre>
					<CopyButton
						className="absolute right-2 top-2 opacity-0 transition-opacity group-hover/code:opacity-100"
						text={codeText}
					/>
				</div>
			);
		},
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
		th: ({ children, ...props }) => <th className="align-top border-b border-white/20 px-2 py-1 text-left text-xs font-semibold" {...props}>{children}</th>,
		td: ({ children, ...props }) => <td className="border-b border-white/10 px-2 py-1 align-top" {...props}>{children}</td>,
	};
};

const MARKDOWN_COMPONENTS_NORMAL = buildMarkdownComponents(false);
const MARKDOWN_COMPONENTS_FOCUS = buildMarkdownComponents(true);

interface MessageBubbleProps {
	message: MessageDTO;
	focusMode: boolean;
	shouldReduceMotion: boolean;
	disableAnimation?: boolean;
}

const MessageBubble = React.memo(({ message, focusMode, shouldReduceMotion, disableAnimation }: MessageBubbleProps) => {
	const bubbleMotion = shouldReduceMotion || disableAnimation
		? {}
		: {
				animate: { opacity: 1, y: 0 },
				exit: { opacity: 0, y: -4 },
				initial: { opacity: 0, y: 8 },
				transition: { duration: 0.2, ease: "easeOut" as const },
			};
	const markdownComponents = focusMode ? MARKDOWN_COMPONENTS_FOCUS : MARKDOWN_COMPONENTS_NORMAL;

	return (
		<motion.article
			className={cn(
				"group/msg relative select-text",
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
			data-testid={`conversation-message-row-${message.id}`}
			{...bubbleMotion}
		>
			{focusMode ? null : (
				<div className="mb-2 flex items-center gap-2 text-[11px] uppercase tracking-[0.18em] text-slate-300/85">
					{message.role === "user" ? <User2 className="h-3.5 w-3.5" /> : <Bot className="h-3.5 w-3.5" />}
					{message.role}
				</div>
			)}
			<ReactMarkdown remarkPlugins={remarkPlugins} components={markdownComponents}>
				{message.content}
			</ReactMarkdown>
			<CopyButton
				className={cn(
					"absolute opacity-0 transition-opacity group-hover/msg:opacity-100",
					focusMode
						? message.role === "user"
							? "-bottom-7 right-0"
							: "-bottom-7 left-0"
						: "-bottom-3 right-3",
				)}
				text={message.content}
			/>
		</motion.article>
	);
});
MessageBubble.displayName = "MessageBubble";

interface ConversationPanelProps {
	chat: ChatDTO | null;
	hasOlderMessages: boolean;
	isLatestDirty?: boolean;
	messageWindowMode?: "latest" | "older";
	messages: MessageDTO[];
	streamHistoryTurns: StreamTurnState[];
	streamingText: string;
	streamingTurn: StreamTurnState | null;
	isWorking: boolean;
	loading: boolean;
	hasRestError: boolean;
	onLoadLatestMessages?: () => void;
	onLoadOlderMessages?: () => void;
	onSetStreamItemExpanded: (itemId: string, expanded: boolean, byUser: boolean) => void;
	onSetStreamItemState: (itemId: string, state: AssistantStreamItemState) => void;
	focusMode?: boolean;
}

export const ConversationPanel = ({
	chat,
	hasOlderMessages,
	isLatestDirty = false,
	messageWindowMode = "latest",
	messages,
	streamHistoryTurns,
	streamingText,
	streamingTurn,
	isWorking,
	loading,
	hasRestError,
	onLoadLatestMessages,
	onLoadOlderMessages,
	onSetStreamItemExpanded,
	onSetStreamItemState,
	focusMode = false,
}: ConversationPanelProps): JSX.Element => {
	const [debouncedIsWorking, setDebouncedIsWorking] = useState(false);
	useEffect(() => {
		if (!isWorking) {
			setDebouncedIsWorking(false);
			return;
		}
		const timer = setTimeout(() => {
			setDebouncedIsWorking(true);
		}, 150);
		return () => clearTimeout(timer);
	}, [isWorking]);

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
	const topPaginationTriggeredRef = useRef(false);
	const latestReloadTriggeredRef = useRef(false);
	const olderWindowBottomArmRef = useRef(false);
	const isAtBottomRef = useRef(true);
	const userScrolledUpRef = useRef(false);
	const lastScrollTopRef = useRef(0);
	const topPaginationTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
	// Track chat switches to suppress enter/exit animations (D-19).
	const prevChatIdRef = useRef<string | null | undefined>(chat?.id);
	const isChatSwitchRef = useRef(false);
	if (prevChatIdRef.current !== chat?.id) {
		isChatSwitchRef.current = true;
		prevChatIdRef.current = chat?.id;
	}
	// Clear the flag after the first render following a chat switch.
	useEffect(() => {
		if (isChatSwitchRef.current) {
			isChatSwitchRef.current = false;
		}
	});
	const bubbleMotion = shouldReduceMotion || isChatSwitchRef.current
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
	const updateIsAtBottom = useCallback(() => {
		const viewport = scrollViewportRef.current;
		if (!viewport) {
			return;
		}
		const distanceFromBottom = viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
		const atBottom = distanceFromBottom <= SCROLL_BOTTOM_THRESHOLD_PX;

		// Detect user scrolling up during streaming (D-18).
		const scrolledUp = viewport.scrollTop < lastScrollTopRef.current;
		lastScrollTopRef.current = viewport.scrollTop;
		if (scrolledUp && !atBottom) {
			userScrolledUpRef.current = true;
		}
		if (atBottom) {
			userScrolledUpRef.current = false;
		}

		isAtBottomRef.current = atBottom;
		setIsAtBottom(atBottom);
	}, []);
	const forceScrollToBottom = useCallback(() => {
		if (hasActiveSelection()) {
			return;
		}
		if (typeof window === "undefined") {
			scrollToBottom("auto");
			return;
		}

		window.requestAnimationFrame(() => {
			if (userScrolledUpRef.current || hasActiveSelection()) {
				return;
			}
			scrollToBottom("auto");
			updateIsAtBottom();
		});
	}, [scrollToBottom, updateIsAtBottom]);
	const handleViewportScroll = useCallback(() => {
		const viewport = scrollViewportRef.current;
		if (!viewport) {
			return;
		}

		updateIsAtBottom();

		// D-20: debounce top pagination to avoid re-triggering.
		if (
			hasOlderMessages &&
			messageWindowMode === "latest" &&
			viewport.scrollTop <= 32 &&
			!loading &&
			!topPaginationTriggeredRef.current
		) {
			if (!topPaginationTimerRef.current) {
				topPaginationTimerRef.current = setTimeout(() => {
					topPaginationTimerRef.current = null;
					const vp = scrollViewportRef.current;
					if (vp && vp.scrollTop <= 32 && !topPaginationTriggeredRef.current) {
						topPaginationTriggeredRef.current = true;
						void onLoadOlderMessages?.();
					}
				}, TOP_PAGINATION_DEBOUNCE_MS);
			}
		} else if (viewport.scrollTop > 32) {
			topPaginationTriggeredRef.current = false;
			if (topPaginationTimerRef.current) {
				clearTimeout(topPaginationTimerRef.current);
				topPaginationTimerRef.current = null;
			}
		}

		if (messageWindowMode === "older" && viewport.scrollTop > 32) {
			olderWindowBottomArmRef.current = true;
		}

		const distanceFromBottom = viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
		if (
			messageWindowMode === "older" &&
			olderWindowBottomArmRef.current &&
			distanceFromBottom <= 24 &&
			!loading &&
			!latestReloadTriggeredRef.current
		) {
			latestReloadTriggeredRef.current = true;
			void onLoadLatestMessages?.();
		}
	}, [hasOlderMessages, loading, messageWindowMode, onLoadLatestMessages, onLoadOlderMessages, updateIsAtBottom]);
	useEffect(() => {
		setIsAtBottom(true);
		isAtBottomRef.current = true;
		userScrolledUpRef.current = false;
		setShowRunDetails(false);
		topPaginationTriggeredRef.current = false;
		latestReloadTriggeredRef.current = false;
		olderWindowBottomArmRef.current = false;
		if (topPaginationTimerRef.current) {
			clearTimeout(topPaginationTimerRef.current);
			topPaginationTimerRef.current = null;
		}
	}, [chat?.id]);

	useEffect(() => {
		topPaginationTriggeredRef.current = false;
		latestReloadTriggeredRef.current = false;
		olderWindowBottomArmRef.current = false;
		if (topPaginationTimerRef.current) {
			clearTimeout(topPaginationTimerRef.current);
			topPaginationTimerRef.current = null;
		}
	}, [loading, messageWindowMode, messages]);

	useLayoutEffect(() => {
		if (!hasContent) {
			return;
		}
		if (hasActiveSelection()) {
			return;
		}
		if (messageWindowMode === "older") {
			const viewport = scrollViewportRef.current;
			if (viewport) {
				viewport.scrollTo({
					top: 0,
					behavior: "auto",
				});
				updateIsAtBottom();
			}
			return;
		}
		if (isAtBottomRef.current && !userScrolledUpRef.current) {
			forceScrollToBottom();
		}
	}, [forceScrollToBottom, hasContent, historicalTurns, isWorking, liveTurn, messageWindowMode, messages, streamingText, updateIsAtBottom]);

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

			<div className="relative flex min-h-0 flex-1 flex-col" style={{ minHeight: 200 }}>
				{loading ? (
					<div className={cn("space-y-4", focusMode ? "px-4 py-3 sm:px-6" : "px-5 py-3")}>
						<div className="flex items-start gap-3">
							<div className="h-6 w-6 animate-pulse rounded-full bg-slate-600/30" />
							<div className="flex-1 space-y-2">
								<div className="h-3 w-3/4 animate-pulse rounded bg-slate-600/30" />
								<div className="h-3 w-1/2 animate-pulse rounded bg-slate-600/30" />
							</div>
						</div>
						<div className="flex items-start gap-3">
							<div className="h-6 w-6 animate-pulse rounded-full bg-slate-600/30" />
							<div className="flex-1 space-y-2">
								<div className="h-3 w-2/3 animate-pulse rounded bg-slate-600/30" />
								<div className="h-3 w-5/6 animate-pulse rounded bg-slate-600/30" />
								<div className="h-3 w-1/3 animate-pulse rounded bg-slate-600/30" />
							</div>
						</div>
					</div>
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
						{hasHistoricalRunDetails || (messageWindowMode === "older" && isLatestDirty) ? (
							<div className={cn("px-5 pt-3", focusMode ? "sm:px-6" : "")}>
								<div className="flex flex-wrap items-center gap-2">
									{hasHistoricalRunDetails ? (
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
									) : null}
									<AnimatePresence>
										{messageWindowMode === "older" && isLatestDirty ? (
											<motion.span
												animate={{ opacity: 1 }}
												className="text-[11px] uppercase tracking-[0.18em] text-amber-200/90"
												data-testid="conversation-latest-dirty-indicator"
												exit={{ opacity: 0 }}
												initial={{ opacity: 0 }}
												key="newer-messages-badge"
												transition={{ duration: 0.2 }}
											>
												Newer messages available
											</motion.span>
										) : null}
									</AnimatePresence>
								</div>
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
								<span className="sr-only" data-testid="conversation-window-mode">
									{messageWindowMode}
								</span>
								<AnimatePresence initial={false}>
									{messages.map((message) => (
										<MessageBubble
											key={message.id}
											message={message}
											focusMode={focusMode}
											shouldReduceMotion={shouldReduceMotion}
											disableAnimation={isChatSwitchRef.current}
										/>
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
												"select-text",
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
													transition={{ duration: 1.2, repeat: Number.POSITIVE_INFINITY, repeatType: "mirror" }}
												/>
											</div>
											<p className={cn("whitespace-pre-wrap", focusMode ? "" : "text-sm leading-6")}>{streamingText}</p>
										</motion.article>
									) : null}

									{debouncedIsWorking ? (
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
						<AnimatePresence>
							{!isAtBottom ? (
								<motion.button
									animate={{ opacity: 1, scale: 1 }}
									aria-label="Scroll to latest message"
									className={cn(
										"absolute bottom-4 right-4 z-20 rounded-full border border-white/20 bg-slate-900/90 p-2 text-slate-100 shadow-[0_10px_30px_rgba(2,6,23,0.45)] transition hover:bg-slate-800/95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/80 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-950",
										focusMode ? "bg-slate-950/80" : "",
									)}
									exit={{ opacity: 0, scale: 0.8 }}
									initial={{ opacity: 0, scale: 0.8 }}
									key="scroll-to-bottom-fab"
									onClick={() => {
										if (messageWindowMode === "older") {
											void onLoadLatestMessages?.();
											return;
										}
										scrollToBottom();
									}}
									transition={{ duration: 0.15 }}
									type="button"
								>
									<ChevronDown className="h-4 w-4" />
								</motion.button>
							) : null}
						</AnimatePresence>
					</>
				) : null}
			</div>
		</section>
	);
};
