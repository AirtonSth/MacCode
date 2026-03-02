import { MaterialIcons } from "@expo/vector-icons";
import { useEffect, useMemo, useState } from "react";
import { AccessibilityInfo, Pressable, StyleSheet, Text, View } from "react-native";

import type { AssistantStreamItemState } from "../../../shared/api/types";
import type { StreamItem, StreamTurnState } from "../model/stream-turn-state";

const TOOL_AUTO_EXPAND_MS = 2_000;
const TOOL_COLLAPSE_DELAY_MS = 200;

interface StreamingTimelineProps {
	turn: StreamTurnState;
	onSetItemExpanded: (itemId: string, expanded: boolean, byUser: boolean) => void;
	onSetItemState: (itemId: string, state: AssistantStreamItemState) => void;
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

const getSummaryFallback = (item: StreamItem): string => {
	if (item.type === "assistant_message") {
		return "Writing response...";
	}
	if (item.type === "tool") {
		return "Running command...";
	}
	if (item.type === "plan") {
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

export const StreamingTimeline = ({
	turn,
	onSetItemExpanded,
	onSetItemState,
}: StreamingTimelineProps): JSX.Element | null => {
	const [shouldReduceMotion, setShouldReduceMotion] = useState<boolean>(false);

	const items = useMemo(
		() =>
			turn.itemOrder
				.map((itemId) => turn.itemsById[itemId])
				.filter((item): item is StreamItem => item !== undefined && item !== null),
		[turn.itemOrder, turn.itemsById],
	);

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
		const timers = new Map<string, ReturnType<typeof setTimeout>>();

		for (const item of items) {
			if (item.type !== "tool" || shouldReduceMotion) {
				continue;
			}
			if (item.state !== "running" || item.isExpanded || item.expandedByUser) {
				continue;
			}

			timers.set(
				item.id,
				setTimeout(() => {
					onSetItemExpanded(item.id, true, false);
				}, TOOL_AUTO_EXPAND_MS),
			);
		}

		return () => {
			for (const timerId of timers.values()) {
				clearTimeout(timerId);
			}
		};
	}, [items, onSetItemExpanded, shouldReduceMotion]);

	useEffect(() => {
		const timers = new Map<string, ReturnType<typeof setTimeout>>();

		for (const item of items) {
			if (item.type !== "tool") {
				continue;
			}
			if (item.state !== "completed" || !item.isExpanded || item.expandedByUser) {
				continue;
			}

			if (shouldReduceMotion) {
				onSetItemExpanded(item.id, false, false);
				onSetItemState(item.id, "collapsed");
				continue;
			}

			onSetItemState(item.id, "preview");
			timers.set(
				item.id,
				setTimeout(() => {
					onSetItemExpanded(item.id, false, false);
					onSetItemState(item.id, "collapsed");
				}, TOOL_COLLAPSE_DELAY_MS),
			);
		}

		return () => {
			for (const timerId of timers.values()) {
				clearTimeout(timerId);
			}
		};
	}, [items, onSetItemExpanded, onSetItemState, shouldReduceMotion]);

	if (items.length === 0) {
		return null;
	}

	return (
		<View style={styles.timeline}>
			{items.map((item) => {
				const icon = getItemIcon(item);
				const summaryText = item.summary.trim().length > 0 ? item.summary : getSummaryFallback(item);
				const detailText = [item.body.trim(), item.output.trim()].filter((entry) => entry.length > 0).join("\n\n");
				const previewText = item.output.trim().length > 0
					? String(normalizeWhitespace(item.output.trim())).slice(0, 200)
					: String(normalizeWhitespace(item.body.trim())).slice(0, 200);
				const canToggle = detailText.length > 0;
				const showExpandedDetails = item.isExpanded && detailText.length > 0;
				const showPreview = item.state === "preview" && !item.isExpanded && previewText.length > 0;

				return (
					<View key={item.id} style={styles.itemCard}>
						<View style={styles.itemHeader}>
							<MaterialIcons color={getIconColor(item.state)} name={icon} size={16} />
							<Text style={styles.summaryText}>{summaryText}</Text>
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
			})}
		</View>
	);
};

const styles = StyleSheet.create({
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
		alignItems: "flex-start",
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
		fontSize: 14,
		lineHeight: 20,
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
