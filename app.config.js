const mobileConfig = require("./mobile/app.json");

const config = mobileConfig.expo;
const scheme = Array.isArray(config.scheme) ? (config.scheme[0] ?? "remotecode") : config.scheme;

module.exports = {
	name: config.name,
	slug: config.slug,
	version: config.version,
	orientation: config.orientation,
	icon: "./mobile/assets/images/icon.png",
	scheme,
	userInterfaceStyle: config.userInterfaceStyle,
	splash: {
		...config.splash,
		image: "./mobile/assets/images/splash-icon.png",
	},
	ios: {
		...config.ios,
		googleServicesFile: "./mobile/GoogleService-Info.plist",
	},
	android: {
		...config.android,
		adaptiveIcon: {
			...config.android.adaptiveIcon,
			foregroundImage: "./mobile/assets/images/android-icon-foreground.png",
			backgroundImage: "./mobile/assets/images/android-icon-background.png",
			monochromeImage: "./mobile/assets/images/android-icon-monochrome.png",
		},
	},
	web: {
		...config.web,
		favicon: "./mobile/assets/images/favicon.png",
	},
	plugins: [
		[
			"expo-router",
			{
				root: "./mobile/app",
			},
		],
		"expo-notifications",
		[
			"expo-widgets",
			{
				bundleIdentifier: "io.remotecode.ExpoWidgetsTarget",
				groupIdentifier: "group.io.remotecode",
				enablePushNotifications: true,
				frequentUpdates: true,
				widgets: [],
			},
		],
	],
	experiments: config.experiments,
	extra: {
		router: {
			root: "./mobile/app",
		},
		eas: {
			build: {
				experimental: {
					ios: {
						appExtensions: [
							{
								targetName: "ExpoWidgetsTarget",
								bundleIdentifier: "io.remotecode.ExpoWidgetsTarget",
								entitlements: {
									"com.apple.security.application-groups": ["group.io.remotecode"],
								},
							},
						],
					},
				},
			},
		},
	},
};
