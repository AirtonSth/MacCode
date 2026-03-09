import { createContext, useContext, useEffect, useMemo, useState } from "react";

import { ApiConfigStore, toApiConfig, type ApiConfig } from "./api-config-store";

type ApiConfigInput = ApiConfig | {
	activeTarget?: ApiConfig["activeTarget"];
	baseUrl: string;
	token: string;
};

interface ApiConfigContextValue {
	config: ApiConfig;
	isLoaded: boolean;
	reload: () => Promise<void>;
	update: (config: ApiConfigInput) => Promise<void>;
}

const ApiConfigContext = createContext<ApiConfigContextValue | null>(null);

export const ApiConfigProvider = ({
	children,
}: {
	children: React.ReactNode;
}) => {
	const [config, setConfig] = useState<ApiConfig>(ApiConfigStore.defaultConfig);
	const [isLoaded, setIsLoaded] = useState<boolean>(false);

	const reload = async () => {
		const persisted = await ApiConfigStore.read();
		setConfig(persisted);
		setIsLoaded(true);
	};

	useEffect(() => {
		void reload();
	}, []);

	const update = async (nextConfig: ApiConfigInput) => {
		const normalized: ApiConfig = "activeTarget" in nextConfig && nextConfig.activeTarget
			? {
				activeTarget: nextConfig.activeTarget,
				baseUrl: nextConfig.baseUrl,
				token: nextConfig.token,
			}
			: toApiConfig({
				baseUrl: nextConfig.baseUrl,
				kind: "local",
				token: nextConfig.token,
			});
		const persisted = await ApiConfigStore.save(normalized);
		setConfig(persisted);
	};

	const value = useMemo(
		() => ({
			config,
			isLoaded,
			reload,
			update,
		}),
		[config, isLoaded],
	);

	return (
		<ApiConfigContext.Provider value={value}>
			{children}
		</ApiConfigContext.Provider>
	);
};

export const useApiConfig = (): ApiConfigContextValue => {
	const context = useContext(ApiConfigContext);

	if (!context) {
		throw new Error("ApiConfigProvider is required");
	}

	return context;
};
