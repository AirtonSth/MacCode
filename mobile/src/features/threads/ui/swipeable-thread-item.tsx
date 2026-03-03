import { useCallback, useEffect, useMemo, useRef } from "react";
import { Animated, PanResponder, Pressable, StyleSheet, Text, View } from "react-native";
import { MaterialIcons } from "@expo/vector-icons";

import { formatRelativeTime } from "../../../shared/lib/time";
import type { ChatDTO } from "../../../shared/api/types";

const palette = {
	text: "#F1F4FA",
};

const swipeDeleteWidth = 108;
const swipeThreshold = 46;

interface SwipeableThreadItemProps {
	chat: ChatDTO;
	index: number;
	isActive: boolean;
	isSelected: boolean;
	onClose: () => void;
	onDelete: () => void;
	onOpen: () => void;
	onOpenChat: () => void;
	deleteTestID: string;
	rowTestID: string;
}

export const SwipeableThreadItem = ({
	chat,
	index,
	isActive,
	isSelected,
	onClose,
	onDelete,
	onOpen,
	onOpenChat,
	deleteTestID,
	rowTestID,
}: SwipeableThreadItemProps) => {
	const translateX = useRef(new Animated.Value(0)).current;
	const dragStartRef = useRef(0);
	const isAnimatingRef = useRef(false);

	const animateTo = useCallback(
		(value: number, onFinish?: () => void) => {
			isAnimatingRef.current = true;
			Animated.spring(translateX, {
				damping: 24,
				toValue: value,
				useNativeDriver: true,
			}).start(() => {
				isAnimatingRef.current = false;
				onFinish?.();
			});
		},
		[translateX],
	);

	const open = useCallback(() => {
		onOpen();
		animateTo(-swipeDeleteWidth);
	}, [animateTo, onOpen]);

	const close = useCallback(() => {
		onClose();
		animateTo(0);
	}, [animateTo, onClose]);

	const panResponder = useMemo(
		() =>
			PanResponder.create({
				onMoveShouldSetPanResponder: (event, gesture) => {
					void event;
					return Math.abs(gesture.dx) > 8 && Math.abs(gesture.dx) > Math.abs(gesture.dy);
				},
				onPanResponderGrant: (event, gesture) => {
					void event;
					void gesture;
					translateX.stopAnimation((value) => {
						dragStartRef.current = value ?? 0;
					});
				},
				onPanResponderMove: (event, gesture) => {
					void event;
					const isSwipingLeft = dragStartRef.current + gesture.dx < 0;
					if (!isSwipingLeft && !isActive) {
						return;
					}

					if (isAnimatingRef.current) {
						return;
					}

					const next = Math.min(0, dragStartRef.current + gesture.dx);
					translateX.setValue(Math.max(-swipeDeleteWidth * 1.1, next));
				},
				onPanResponderRelease: (event, gesture) => {
					void event;
					const finalPosition = dragStartRef.current + gesture.dx;

					if (finalPosition < -swipeThreshold) {
						open();
					} else {
						close();
					}
				},
				onPanResponderTerminate: () => {
					close();
				},
			}),
		[close, isActive, open, translateX],
	);

	useEffect(() => {
		if (isActive) {
			animateTo(-swipeDeleteWidth);
		} else {
			animateTo(0);
		}
	}, [animateTo, isActive]);

	return (
		<View style={styles.swipeRowRoot}>
			<View style={styles.deleteActionRoot}>
				<Pressable
					accessibilityLabel={`thread-item-delete-${String(index)}`}
					accessibilityRole="button"
					testID={deleteTestID}
					onPress={() => {
						onClose();
						onDelete();
					}}
					style={styles.deleteActionButton}
				>
					<MaterialIcons color="#0A0D14" name="delete-outline" size={20} />
				</Pressable>
			</View>

			<Animated.View
				style={[styles.listRow, isSelected ? styles.listRowActive : null, { transform: [{ translateX }] }]}
				{...panResponder.panHandlers}
			>
				<Pressable
					accessibilityLabel={`thread-item-${String(index)}`}
					accessibilityRole="button"
					testID={rowTestID}
					onPress={() => {
						if (isActive) {
							close();
							return;
						}

						onOpenChat();
					}}
					style={({ pressed }) => [pressed ? styles.listRowPressed : null]}
				>
						<View style={styles.rowContent}>
							<View style={styles.rowText}>
								<Text numberOfLines={1} style={styles.rowTitle}>
									{chat.title}
								</Text>
								<Text style={styles.rowMeta}>Updated {formatRelativeTime(chat.updatedAt)}</Text>
							</View>
						<MaterialIcons color={palette.text} name="chevron-right" size={20} />
						</View>
					</Pressable>
			</Animated.View>
		</View>
	);
};

const styles = StyleSheet.create({
	swipeRowRoot: {
		borderRadius: 11,
		overflow: "hidden",
	},
	deleteActionRoot: {
		alignItems: "center",
		backgroundColor: "#ff5d5f",
		borderRadius: 11,
		flexDirection: "row",
		height: "100%",
		justifyContent: "center",
		overflow: "hidden",
		position: "absolute",
		right: 0,
		top: 0,
		width: swipeDeleteWidth,
	},
	deleteActionButton: {
		alignItems: "center",
		flex: 1,
		height: "100%",
		justifyContent: "center",
		width: swipeDeleteWidth,
	},
	listRow: {
		backgroundColor: "#12161E",
		borderColor: "rgba(255,255,255,0.11)",
		borderRadius: 11,
		borderWidth: 1,
		gap: 4,
		padding: 12,
	},
	rowContent: {
		alignItems: "center",
		flexDirection: "row",
		justifyContent: "space-between",
		gap: 8,
	},
	rowText: {
		flex: 1,
	},
	listRowActive: {
		borderColor: "rgba(99,200,255,0.45)",
	},
	listRowPressed: {
		opacity: 0.8,
	},
	rowMeta: {
		color: "#98A0AF",
		fontSize: 12,
	},
	rowTitle: {
		color: "#F1F4FA",
		fontSize: 15,
		fontWeight: "600",
	},
});
