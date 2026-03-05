import { useEffect, useRef } from "react";
import { Animated, Easing, Image, StyleSheet } from "react-native";
import iconSource from "../../../assets/images/icon.png";

interface AnimatedLaunchSplashProps {
	onFinish: () => void;
}

const OVERLAY_BG = "#0d0f14";

export const AnimatedLaunchSplash = ({ onFinish }: AnimatedLaunchSplashProps) => {
	const overlayOpacity = useRef(new Animated.Value(1)).current;
	const iconOpacity = useRef(new Animated.Value(0)).current;
	const iconScale = useRef(new Animated.Value(0.92)).current;
	const glowOpacity = useRef(new Animated.Value(0)).current;
	const glowScale = useRef(new Animated.Value(0.82)).current;

	useEffect(() => {
		const sequence = Animated.sequence([
			Animated.parallel([
				Animated.timing(iconOpacity, {
					duration: 88,
					easing: Easing.out(Easing.quad),
					toValue: 1,
					useNativeDriver: true,
				}),
				Animated.timing(iconScale, {
					duration: 140,
					easing: Easing.out(Easing.cubic),
					toValue: 1,
					useNativeDriver: true,
				}),
				Animated.timing(glowOpacity, {
					duration: 110,
					easing: Easing.out(Easing.quad),
					toValue: 1,
					useNativeDriver: true,
				}),
				Animated.timing(glowScale, {
					duration: 150,
					easing: Easing.out(Easing.cubic),
					toValue: 1,
					useNativeDriver: true,
				}),
			]),
			Animated.delay(36),
			Animated.parallel([
				Animated.timing(overlayOpacity, {
					duration: 120,
					easing: Easing.in(Easing.quad),
					toValue: 0,
					useNativeDriver: true,
				}),
				Animated.timing(iconScale, {
					duration: 120,
					easing: Easing.out(Easing.quad),
					toValue: 1.04,
					useNativeDriver: true,
				}),
				Animated.timing(glowOpacity, {
					duration: 104,
					easing: Easing.in(Easing.quad),
					toValue: 0,
					useNativeDriver: true,
				}),
			]),
		]);

		sequence.start(({ finished }) => {
			if (!finished) {
				return;
			}

			onFinish();
		});

		return () => {
			sequence.stop();
		};
	}, [glowOpacity, glowScale, iconOpacity, iconScale, onFinish, overlayOpacity]);

	return (
		<Animated.View pointerEvents="none" style={[styles.overlay, { opacity: overlayOpacity }]}>
			<Animated.View
				style={[
					styles.glow,
					{
						opacity: glowOpacity,
						transform: [{ scale: glowScale }],
					},
				]}
			/>
			<Animated.View
				style={[
					styles.iconFrame,
					{
						opacity: iconOpacity,
						transform: [{ scale: iconScale }],
					},
				]}
			>
					<Image alt="" source={iconSource} style={styles.icon} />
			</Animated.View>
		</Animated.View>
	);
};

const styles = StyleSheet.create({
	glow: {
		backgroundColor: "rgba(99,200,255,0.22)",
		borderRadius: 74,
		height: 148,
		position: "absolute",
		width: 148,
	},
	icon: {
		borderRadius: 22,
		height: 92,
		width: 92,
	},
	iconFrame: {
		alignItems: "center",
		backgroundColor: "rgba(13,18,27,0.78)",
		borderColor: "rgba(255,255,255,0.14)",
		borderRadius: 28,
		borderWidth: 1,
		height: 106,
		justifyContent: "center",
		padding: 7,
		width: 106,
	},
	overlay: {
		...StyleSheet.absoluteFill,
		alignItems: "center",
		backgroundColor: OVERLAY_BG,
		justifyContent: "center",
		zIndex: 999,
	},
});
