import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { AlertTriangle, Bot, Sparkles, User2 } from "lucide-react";
import { Badge } from "../../../components/ui/badge";
import { ScrollArea } from "../../../components/ui/scroll-area";
import { cn } from "../../../lib/utils";
import type { ChatDTO, MessageDTO } from "../../workspace/model/useWorkspaceStore";

interface ConversationPanelProps {
	chat: ChatDTO | null;
	messages: MessageDTO[];
	streamingText: string;
	loading: boolean;
	hasRestError: boolean;
	focusMode?: boolean;
}

export const ConversationPanel = ({
	chat,
	messages,
	streamingText,
	loading,
	hasRestError,
	focusMode = false,
}: ConversationPanelProps): JSX.Element => {
	const shouldReduceMotion = useReducedMotion();
	const hasMessages = messages.length > 0;
	const hasStreaming = streamingText.trim().length > 0;
	const hasContent = hasMessages || hasStreaming;
	const bubbleMotion = shouldReduceMotion
		? {}
		: {
				animate: { opacity: 1, y: 0 },
				exit: { opacity: 0, y: -4 },
				initial: { opacity: 0, y: 8 },
				transition: { duration: 0.2, ease: "easeOut" as const },
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
				<header className="flex flex-wrap items-center justify-between gap-3 border-b border-white/10 px-5 py-4">
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
					<ScrollArea className="h-full">
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
												{message.role === "user" ? (
													<User2 className="h-3.5 w-3.5" />
												) : (
													<Bot className="h-3.5 w-3.5" />
												)}
												{message.role}
											</div>
										)}
										<p className={cn("whitespace-pre-wrap", focusMode ? "" : "text-sm leading-6")}>
											{message.content}
										</p>
									</motion.article>
								))}

								{streamingText ? (
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
												className={cn(
													"h-1.5 w-1.5 rounded-full",
													focusMode ? "bg-slate-300" : "bg-sky-100",
												)}
												transition={{ duration: 1.2, repeat: Number.POSITIVE_INFINITY }}
											/>
										</div>
										<p className={cn("whitespace-pre-wrap", focusMode ? "" : "text-sm leading-6")}>
											{streamingText}
										</p>
									</motion.article>
								) : null}
							</AnimatePresence>
						</div>
					</ScrollArea>
				) : null}
			</div>
		</section>
	);
};
