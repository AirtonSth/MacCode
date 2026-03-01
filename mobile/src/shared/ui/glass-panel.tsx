import { type ViewProps, View } from "react-native";

import { theme } from "@/shared/theme/tokens";

export const GlassPanel = ({
	children,
	style,
	...rest
}: ViewProps) => {
	return (
		<View
			{...rest}
			style={[
				{
					backgroundColor: theme.colors.panelBackground,
					borderColor: theme.colors.borderSoft,
					borderRadius: theme.borderRadius.panel,
					borderWidth: 1,
					padding: theme.spacing.md,
				},
				theme.shadow.soft,
				style,
			]}
		>
			{children}
		</View>
	);
};
