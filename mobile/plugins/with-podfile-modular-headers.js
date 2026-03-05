/* eslint-env node */

const fs = require("node:fs");
const path = require("node:path");

const { withDangerousMod } = require("expo/config-plugins");

const MARKER_COMMENT = "# Required by Firebase Swift pods when CocoaPods is resolving static libraries.";
const MODULAR_HEADERS_LINE = "use_modular_headers!";

const injectModularHeaders = (podfileContents) => {
	if (podfileContents.includes(MODULAR_HEADERS_LINE)) {
		return podfileContents;
	}

	return podfileContents.replace(
		/(?<iosPlatformLine>platform\s+:ios[^\n]*\n)/u,
		`$<iosPlatformLine>\n${MARKER_COMMENT}\n${MODULAR_HEADERS_LINE}\n`,
	);
};

const withPodfileModularHeaders = (config) =>
	withDangerousMod(config, [
		"ios",
		(nextConfig) => {
			const podfilePath = path.join(nextConfig.modRequest.platformProjectRoot, "Podfile");
			if (!fs.existsSync(podfilePath)) {
				return nextConfig;
			}

			const currentContents = fs.readFileSync(podfilePath, "utf8");
			const nextContents = injectModularHeaders(currentContents);
			if (nextContents !== currentContents) {
				fs.writeFileSync(podfilePath, nextContents, "utf8");
			}

			return { ...nextConfig };
		},
	]);

module.exports = withPodfileModularHeaders;
