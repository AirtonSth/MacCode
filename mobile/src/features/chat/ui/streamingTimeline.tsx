import { MaterialIcons } from "@expo/vector-icons";
import { memo, useEffect, useMemo, useRef, useState } from "react";
import { AccessibilityInfo, Pressable, StyleSheet, Text, View } from "react-native";

import type { AssistantStreamItemState } from "../../../shared/api/types";
import { MessageMarkdown } from "../../../shared/ui/markdown-message";
import type { StreamItem, StreamTurnState } from "../model/stream-turn-state";

const TOOL_AUTO_EXPAND_MS = 2_000;

interface StreamingTimelineProps {
	turn: StreamTurnState;
	onSetItemExpanded: (itemId: string, expanded: boolean, byUser: boolean) => void;
	onSetItemState: (itemId: string, state: AssistantStreamItemState) => void;
}

interface CachedRenderedItem {
	item: StreamItem;
	onSetItemExpanded: (itemId: string, expanded: boolean, byUser: boolean) => void;
	onSetItemState: (itemId: string, state: AssistantStreamItemState) => void;
	element: JSX.Element;
}

const getItemIcon = (item: StreamItem): keyof typeof MaterialIcons.glyphMap => {
	if (item.type === "tool") {
		return "terminal";
	}
	if (item.type === "plan") {
		return "playlist-add-check";
	}
	if (item.type === "assistant_message") {
		return "smart-toy";
	}
	if (item.state === "running") {
		return "auto-awesome";
	}
	return "lightbulb-outline";
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

const getSummaryFallback = (itemType: StreamItem["type"]): string => {
	if (itemType === "assistant_message") {
		return "Writing response...";
	}
	if (itemType === "tool") {
		return "Running command...";
	}
	if (itemType === "plan") {
		return "Planning...";
	}
	return "Thinking...";
};

const getStateBadgeStyle = (state: AssistantStreamItemState) => {
	if (state === "failed" || state === "cancelled") {
		return styles.stateBadgeFailed;
	}
	if (state === "completed" || state === "preview" || state === "collapsed") {
		return styles.stateBadgeCompleted;
	}
	return styles.stateBadgeRunning;
};

const getIconColor = (state: AssistantStreamItemState): string => {
	if (state === "failed" || state === "cancelled") {
		return "#fda4af";
	}
	if (state === "completed" || state === "preview" || state === "collapsed") {
		return "#86efac";
	}
	return "#7dd3fc";
};

const normalizeWhitespace = (value: string): string => value.trim().split(/\s+/).join(" ");

const getDetailText = (item: StreamItem): string => {
	const body = item.body.trim();
	const output = item.output.trim();

	if (body.length === 0) {
		return output;
	}
	if (output.length === 0) {
		return body;
	}

	return `${body}\n\n${output}`;
};

const getPreviewText = (item: StreamItem): string => {
	const output = item.output.trim();
	if (output.length > 0) {
		return normalizeWhitespace(output).slice(0, 200);
	}
	return normalizeWhitespace(item.body.trim()).slice(0, 200);
};

const renderTimelineItem = (
	item: StreamItem,
	onSetItemExpanded: (itemId: string, expanded: boolean, byUser: boolean) => void,
	onSetItemState: (itemId: string, state: AssistantStreamItemState) => void,
): JSX.Element => {
	const icon = getItemIcon(item);
	const summaryText = item.summary.trim().length > 0 ? item.summary : getSummaryFallback(item.type);
	const detailText = getDetailText(item);
	const previewText = getPreviewText(item);
	const canToggle = detailText.length > 0;
	const showExpandedDetails = item.isExpanded && detailText.length > 0;
	const showPreview = item.state === "preview" && !item.isExpanded && previewText.length > 0;
	const assistantText = detailText.length > 0 ? detailText : summaryText;
	const hasAssistantText = assistantText.trim().length > 0;

	if (item.type === "assistant_message") {
		return (
			<View key={item.id} style={styles.assistantInlineWrapper}>
				{hasAssistantText ? (
					<MessageMarkdown
						content={assistantText}
						linkColor="#63C8FF"
						textColor="#eaf2ff"
					/>
				) : (
					<Text selectable style={[styles.summaryText, styles.assistantInlineCollapsed]}>
						{assistantText}
					</Text>
				)}
			</View>
		);
	}

	return (
		<View key={item.id} style={styles.itemCard}>
			<View style={styles.itemHeader}>
				<MaterialIcons color={getIconColor(item.state)} name={icon} size={16} />
				<Text ellipsizeMode="tail" numberOfLines={1} style={styles.summaryText}>
					{summaryText}
				</Text>
				<View style={[styles.stateBadge, getStateBadgeStyle(item.state)]}>
					<Text style={styles.stateBadgeLabel}>{getStateLabel(item.state)}</Text>
				</View>
				{canToggle ? (
					<Pressable
						accessibilityLabel={item.isExpanded ? "Collapse stream item" : "Expand stream item"}
						onPress={() => {
							const nextExpanded = !item.isExpanded;
							onSetItemExpanded(item.id, nextExpanded, true);
							if (nextExpanded && item.state === "collapsed") {
								onSetItemState(item.id, "completed");
							}
						}}
						style={({ pressed }) => [styles.toggleButton, pressed ? styles.toggleButtonPressed : null]}
					>
						<MaterialIcons
							color="#d9e2f2"
							name={item.isExpanded ? "expand-less" : "chevron-right"}
							size={16}
						/>
					</Pressable>
				) : null}
			</View>

			{showPreview ? <Text style={styles.previewText}>{previewText}</Text> : null}

			{showExpandedDetails ? (
				<View style={styles.detailContainer}>
					<Text selectable style={styles.detailText}>
						{detailText}
					</Text>
				</View>
			) : null}
		</View>
	);
};

const StreamingTimelineComponent = ({
	turn,
	onSetItemExpanded,
	onSetItemState,
}: StreamingTimelineProps): JSX.Element | null => {
	const [shouldReduceMotion, setShouldReduceMotion] = useState<boolean>(false);
	const autoExpandTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());
	const itemRenderCacheRef = useRef<Map<string, CachedRenderedItem>>(new Map());
	const onSetItemExpandedRef = useRef(onSetItemExpanded);

	const items = useMemo(
		() =>
			turn.itemOrder
				.map((itemId) => turn.itemsById[itemId])
				.filter((item): item is StreamItem => item !== undefined && item !== null),
		[turn.itemOrder, turn.itemsById],
	);

	useEffect(() => {
		onSetItemExpandedRef.current = onSetItemExpanded;
	}, [onSetItemExpanded]);

	useEffect(() => {
		let active = true;
		const evaluateMotion = async () => {
			try {
				const enabled = await AccessibilityInfo.isReduceMotionEnabled();
				if (active) {
					setShouldReduceMotion(Boolean(enabled));
				}
			} catch {
				if (active) {
					setShouldReduceMotion(false);
				}
			}
		};

		void evaluateMotion();

		const subscription = AccessibilityInfo.addEventListener?.(
			"reduceMotionChanged",
			(enabled: boolean) => {
				setShouldReduceMotion(Boolean(enabled));
			},
		);

		return () => {
			active = false;
			subscription?.remove?.();
		};
	}, []);

	useEffect(() => {
		const timers = autoExpandTimersRef.current;

		if (shouldReduceMotion) {
			for (const timeoutId of timers.values()) {
				clearTimeout(timeoutId);
			}
			timers.clear();
			return;
		}

		const pendingAutoExpandIds = new Set<string>();

		for (const item of items) {
			if (item.type !== "tool") {
				continue;
			}
			if (item.state !== "running" || item.isExpanded || item.expandedByUser) {
				continue;
			}

			pendingAutoExpandIds.add(item.id);
			if (timers.has(item.id)) {
				continue;
			}

			const timeoutId = setTimeout(() => {
				autoExpandTimersRef.current.delete(item.id);
				onSetItemExpandedRef.current(item.id, true, false);
			}, TOOL_AUTO_EXPAND_MS);
			timers.set(item.id, timeoutId);
		}

		for (const [itemId, timeoutId] of timers.entries()) {
			if (pendingAutoExpandIds.has(itemId)) {
				continue;
			}
			clearTimeout(timeoutId);
			timers.delete(itemId);
		}
	}, [items, shouldReduceMotion]);

	useEffect(() => () => {
		for (const timeoutId of autoExpandTimersRef.current.values()) {
			clearTimeout(timeoutId);
		}
		autoExpandTimersRef.current.clear();
		itemRenderCacheRef.current.clear();
	}, []);

	const renderedItems = useMemo(() => {
		const previousCache = itemRenderCacheRef.current;
		const nextCache = new Map<string, CachedRenderedItem>();
		const nextItems: JSX.Element[] = [];

		for (const item of items) {
			const cached = previousCache.get(item.id);
			if (
				cached &&
				cached.item === item &&
				cached.onSetItemExpanded === onSetItemExpanded &&
				cached.onSetItemState === onSetItemState
			) {
				nextCache.set(item.id, cached);
				nextItems.push(cached.element);
				continue;
			}

			const element = renderTimelineItem(item, onSetItemExpanded, onSetItemState);
			const nextCached: CachedRenderedItem = {
				item,
				onSetItemExpanded,
				onSetItemState,
				element,
			};
			nextCache.set(item.id, nextCached);
			nextItems.push(element);
		}

		itemRenderCacheRef.current = nextCache;
		return nextItems;
	}, [items, onSetItemExpanded, onSetItemState]);

	if (renderedItems.length === 0) {
		return null;
	}

	return <View style={styles.timeline}>{renderedItems}</View>;
};

export const StreamingTimeline = memo(
	StreamingTimelineComponent,
	(previousProps, nextProps) => (
		previousProps.turn === nextProps.turn &&
		previousProps.onSetItemExpanded === nextProps.onSetItemExpanded &&
		previousProps.onSetItemState === nextProps.onSetItemState
	),
);

StreamingTimeline.displayName = "StreamingTimeline";

const styles = StyleSheet.create({
	assistantInlineCollapsed: {
		color: "rgba(148,163,184,0.9)",
	},
	assistantInlineWrapper: {
		paddingVertical: 2,
	},
	detailContainer: {
		backgroundColor: "rgba(2,6,23,0.72)",
		borderColor: "rgba(255,255,255,0.16)",
		borderRadius: 10,
		borderWidth: 1,
		marginTop: 8,
		paddingHorizontal: 10,
		paddingVertical: 8,
	},
	detailText: {
		color: "#d5deef",
		fontFamily: "Menlo",
		fontSize: 12,
		lineHeight: 18,
	},
	itemCard: {
		backgroundColor: "rgba(125,211,252,0.08)",
		borderColor: "rgba(125,211,252,0.24)",
		borderRadius: 14,
		borderWidth: 1,
		paddingHorizontal: 10,
		paddingVertical: 10,
	},
	itemHeader: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
	},
	previewText: {
		color: "rgba(226,232,240,0.88)",
		fontSize: 12,
		lineHeight: 18,
		marginTop: 6,
	},
	stateBadge: {
		borderRadius: 999,
		borderWidth: 1,
		marginLeft: "auto",
		paddingHorizontal: 6,
		paddingVertical: 2,
	},
	stateBadgeCompleted: {
		backgroundColor: "rgba(16,185,129,0.14)",
		borderColor: "rgba(134,239,172,0.45)",
	},
	stateBadgeFailed: {
		backgroundColor: "rgba(244,63,94,0.14)",
		borderColor: "rgba(253,164,175,0.45)",
	},
	stateBadgeLabel: {
		color: "#dce8fb",
		fontSize: 9,
		fontWeight: "700",
		letterSpacing: 0.7,
		textTransform: "uppercase",
	},
	stateBadgeRunning: {
		backgroundColor: "rgba(56,189,248,0.14)",
		borderColor: "rgba(125,211,252,0.45)",
	},
	summaryText: {
		color: "#eaf2ff",
		flex: 1,
		flexShrink: 1,
		fontSize: 14,
		lineHeight: 20,
		minWidth: 0,
	},
	timeline: {
		gap: 8,
	},
	toggleButton: {
		alignItems: "center",
		borderColor: "rgba(255,255,255,0.18)",
		borderRadius: 8,
		borderWidth: 1,
		height: 24,
		justifyContent: "center",
		marginLeft: 6,
		width: 24,
	},
	toggleButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
});
