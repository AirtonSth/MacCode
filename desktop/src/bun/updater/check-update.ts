const GITHUB_REPO = "samuelfaj/remotecode.io";
const GITHUB_API_URL = `https://api.github.com/repos/${GITHUB_REPO}/releases/latest`;

export interface UpdateInfo {
	currentVersion: string;
	hasUpdate: boolean;
	latestVersion: string;
	releaseUrl: string;
}

const parseVersion = (raw: string): string => raw.replace(/^v/i, "").trim();

const isNewerVersion = (latest: string, current: string): boolean => {
	const latestParts = latest.split(".").map(Number);
	const currentParts = current.split(".").map(Number);
	const length = Math.max(latestParts.length, currentParts.length);

	for (let i = 0; i < length; i++) {
		const l = latestParts[i] ?? 0;
		const c = currentParts[i] ?? 0;
		if (l > c) {
			return true;
		}
		if (l < c) {
			return false;
		}
	}

	return false;
};

export const checkForUpdates = async (currentVersion: string): Promise<UpdateInfo> => {
	const response = await fetch(GITHUB_API_URL, {
		headers: { accept: "application/vnd.github+json" },
		signal: AbortSignal.timeout(10_000),
	});

	if (!response.ok) {
		throw new Error(`GitHub API responded with ${response.status}`);
	}

	const release = (await response.json()) as { html_url: string; tag_name: string };
	const latestVersion = parseVersion(release.tag_name);

	return {
		currentVersion,
		hasUpdate: isNewerVersion(latestVersion, currentVersion),
		latestVersion,
		releaseUrl: release.html_url,
	};
};
