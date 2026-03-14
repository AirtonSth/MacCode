const path = require("node:path");
const { getDefaultConfig } = require("expo/metro-config");

const projectRoot = __dirname;
const workspaceRoot = path.resolve(projectRoot, "..");
const config = getDefaultConfig(projectRoot);
const toAbsoluteBlockListPattern = (targetPath) => {
	const escapedPath = path.resolve(targetPath)
		.replaceAll(/[|\\{}()[\]^$+*?.]/g, String.raw`\$&`)
		.replaceAll("/", String.raw`[/\\]`);

	// Metro expects RegExp entries in blockList; the path input is fixed by this config.
	// eslint-disable-next-line security/detect-non-literal-regexp
	return new RegExp(`^${escapedPath}([/\\\\].*)?$`);
};

config.watchFolders = [workspaceRoot];
config.resolver.nodeModulesPaths = [
	path.resolve(projectRoot, "node_modules"),
	path.resolve(workspaceRoot, "node_modules"),
];
config.resolver.disableHierarchicalLookup = true;
config.resolver.resolverMainFields = ["react-native", "browser", "module", "main"];
config.resolver.sourceExts = Array.from(new Set(["umd.js", ...config.resolver.sourceExts]));
config.resolver.blockList = [
	toAbsoluteBlockListPattern(path.resolve(workspaceRoot, "desktop", "build")),
	toAbsoluteBlockListPattern(path.resolve(workspaceRoot, "desktop", "dist")),
	toAbsoluteBlockListPattern(path.resolve(workspaceRoot, "dist")),
];

module.exports = config;
