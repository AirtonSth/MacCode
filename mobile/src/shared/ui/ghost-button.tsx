import {
	Pressable,
	Text,
	type PressableProps,
	type PressableStateCallbackType,
	type StyleProp,
	type ViewStyle,
} from "react-native";

import { theme } from "../theme/tokens";

interface GhostButtonProps extends PressableProps {
	label: string;
}

export const GhostButton = ({
	label,
	style,
	...rest
}: GhostButtonProps) => {
	return (
		<Pressable
			{...rest}
			style={(state: PressableStateCallbackType) => {
				const { pressed } = state;
				const resolvedStyle: StyleProp<ViewStyle> = typeof style === "function"
					? style(state)
					: style;

				return [
					{
						backgroundColor: pressed ? "rgba(255,255,255,0.12)" : "rgba(255,255,255,0.06)",
						borderColor: theme.colors.borderSoft,
						borderRadius: theme.borderRadius.chip,
						borderWidth: 1,
						paddingHorizontal: 12,
						paddingVertical: 8,
					},
					resolvedStyle,
				];
			}}
		>
			<Text
				style={{
					color: theme.colors.textPrimary,
					fontSize: 13,
					fontWeight: "600",
				}}
			>
				{label}
			</Text>
		</Pressable>
	);
};
