import { useEffect, useRef } from "react";
import { ActivityIndicator, Animated, Pressable, StyleSheet, Text, View } from "react-native";

const palette = {
	accent: "#63C8FF",
};

interface ActiveThreadsBannerProps {
	count: number;
	onPress: () => void;
}

/** Absolutely-positioned banner that fades in/out without shifting the message list. */
export const ActiveThreadsBanner = ({ count, onPress }: ActiveThreadsBannerProps) => {
	const fadeAnim = useRef(new Animated.Value(0)).current;
	const isVisible = count > 0;

	useEffect(() => {
		Animated.timing(fadeAnim, {
			toValue: isVisible ? 1 : 0,
			duration: 200,
			useNativeDriver: true,
		}).start();
	}, [isVisible, fadeAnim]);

	// Always render so the fade-out animation can play; pointer-events none when hidden.
	const label =
		count === 1 ? "1 other active thread" : `${String(count)} other active threads`;

	return (
		<View style={styles.wrapper}>
			<Animated.View
				pointerEvents={isVisible ? "auto" : "none"}
				style={[styles.bannerLayer, { opacity: fadeAnim }]}
			>
				<Pressable
					accessibilityRole="button"
					onPress={onPress}
					style={({ pressed }) => [
						styles.banner,
						pressed ? styles.bannerPressed : null,
					]}
					testID="chat-active-threads-banner"
				>
					<ActivityIndicator color={palette.accent} size={10} />
					<Text style={styles.text}>{label}</Text>
				</Pressable>
			</Animated.View>
		</View>
	);
};

const styles = StyleSheet.create({
	wrapper: {
		minHeight: 35,
		position: "relative",
		zIndex: 10,
	},
	bannerLayer: {
		bottom: 0,
		left: 0,
		position: "absolute",
		right: 0,
		top: 0,
	},
	banner: {
		alignItems: "center",
		backgroundColor: "rgba(99,200,255,0.10)",
		borderBottomColor: "rgba(99,200,255,0.25)",
		borderBottomWidth: 1,
		flexDirection: "row",
		gap: 8,
		justifyContent: "center",
		paddingHorizontal: 14,
		paddingVertical: 8,
	},
	bannerPressed: {
		opacity: 0.7,
	},
	text: {
		color: "#9FDBFF",
		fontSize: 12,
		fontWeight: "600",
	},
});
