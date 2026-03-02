import { useCallback, useEffect, useMemo, useRef, type ReactNode } from "react";
import { Animated, PanResponder, Pressable, StyleSheet, Text, View } from "react-native";

const swipeDeleteWidth = 92;
const swipeThreshold = 44;

interface SwipeableSavedConnectionItemProps {
	children: ReactNode;
	deleteTestID: string;
	index: number;
	isActive: boolean;
	onClose: () => void;
	onDelete: () => void;
	onOpen: () => void;
}

export const SwipeableSavedConnectionItem = ({
	children,
	deleteTestID,
	index,
	isActive,
	onClose,
	onDelete,
	onOpen,
}: SwipeableSavedConnectionItemProps) => {
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
						return;
					}

					close();
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
					accessibilityLabel={`saved-connection-delete-${String(index)}`}
					accessibilityRole="button"
					onPress={() => {
						onClose();
						onDelete();
					}}
					style={styles.deleteActionButton}
					testID={deleteTestID}
				>
					<Text style={styles.deleteActionLabel}>Delete</Text>
				</Pressable>
			</View>

			<Animated.View style={{ transform: [{ translateX }] }} {...panResponder.panHandlers}>
				{children}
			</Animated.View>
		</View>
	);
};

const styles = StyleSheet.create({
	deleteActionButton: {
		alignItems: "center",
		flex: 1,
		height: "100%",
		justifyContent: "center",
		width: swipeDeleteWidth,
	},
	deleteActionLabel: {
		color: "#FFFFFF",
		fontSize: 13,
		fontWeight: "700",
	},
	deleteActionRoot: {
		alignItems: "center",
		backgroundColor: "#ff5d5f",
		flexDirection: "row",
		height: "100%",
		justifyContent: "center",
		position: "absolute",
		right: 0,
		top: 0,
		width: swipeDeleteWidth,
	},
	swipeRowRoot: {
		overflow: "hidden",
	},
});
