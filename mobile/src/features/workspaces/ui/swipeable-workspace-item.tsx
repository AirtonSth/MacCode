import { useCallback, useEffect, useMemo, useRef } from "react";
import { Animated, PanResponder, Pressable, StyleSheet, Text, View } from "react-native";
import { MaterialIcons } from "@expo/vector-icons";

import type { ProjectDTO } from "../../../shared/api/types";

const swipeDeleteWidth = 108;
const swipeThreshold = 46;
const defaultRowBackgroundColor = "#12161E";
const defaultRowBorderColor = "rgba(255,255,255,0.11)";
const defaultSelectedRowBackgroundColor = defaultRowBackgroundColor;
const defaultSelectedRowBorderColor = "rgba(99,200,255,0.45)";

interface SwipeableWorkspaceItemProps {
	index: number;
	isActive: boolean;
	isSelected: boolean;
	onClose: () => void;
	onDelete: () => void;
	onOpen: () => void;
	onOpenWorkspace: () => void;
	deleteTestID: string;
	project: ProjectDTO;
	rowTestID: string;
	rowBackgroundColor?: string;
	rowBorderColor?: string;
	selectedRowBackgroundColor?: string;
	selectedRowBorderColor?: string;
}

export const SwipeableWorkspaceItem = ({
	index,
	isActive,
	isSelected,
	onClose,
	onDelete,
	onOpen,
	onOpenWorkspace,
	deleteTestID,
	project,
	rowTestID,
	rowBackgroundColor = defaultRowBackgroundColor,
	rowBorderColor = defaultRowBorderColor,
	selectedRowBackgroundColor = defaultSelectedRowBackgroundColor,
	selectedRowBorderColor = defaultSelectedRowBorderColor,
}: SwipeableWorkspaceItemProps) => {
	const translateX = useRef(new Animated.Value(0)).current;
	const dragStartRef = useRef(0);
	const isAnimatingRef = useRef(false);
	const deleteActionOpacity = useMemo(
		() =>
			translateX.interpolate({
				extrapolate: "clamp",
				inputRange: [-swipeDeleteWidth, -8, 0],
				outputRange: [1, 0, 0],
			}),
		[translateX],
	);

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
			<Animated.View style={[styles.deleteActionRoot, { opacity: deleteActionOpacity }]}>
				<Pressable
					accessibilityLabel={`workspace-item-delete-${String(index)}`}
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
			</Animated.View>

			<Animated.View
				style={[
					styles.listRow,
					isSelected ? styles.listRowActive : null,
					{
						backgroundColor: isSelected
							? selectedRowBackgroundColor
							: rowBackgroundColor,
						borderColor: isSelected
							? selectedRowBorderColor
							: rowBorderColor,
					},
					{ transform: [{ translateX }] },
				]}
				{...panResponder.panHandlers}
			>
				<Pressable
					accessibilityLabel={`workspace-item-${String(index)}`}
					accessibilityRole="button"
					testID={rowTestID}
					onPress={() => {
						if (isActive) {
							close();
							return;
						}

						onOpenWorkspace();
					}}
					style={({ pressed }) => [pressed ? styles.listRowPressed : null]}
				>
					<View style={styles.rowContent}>
						<View style={styles.rowText}>
							<Text numberOfLines={1} style={styles.rowTitle}>
								{project.name}
							</Text>
							<Text numberOfLines={1} style={styles.rowMeta}>
								{project.path}
							</Text>
						</View>
						<MaterialIcons color="#F1F4FA" name="chevron-right" size={20} />
					</View>
				</Pressable>
			</Animated.View>
		</View>
	);
};

const styles = StyleSheet.create({
	swipeRowRoot: {
		alignSelf: "stretch",
		borderRadius: 11,
		width: "100%",
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
		width: "100%",
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
