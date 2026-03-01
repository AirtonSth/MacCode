import { createContext, useContext, useEffect, useMemo, useState } from "react";

import { ApiConfigStore, type ApiConfig } from "./api-config-store";

interface ApiConfigContextValue {
	config: ApiConfig;
	isLoaded: boolean;
	reload: () => Promise<void>;
	update: (config: ApiConfig) => Promise<void>;
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

	const update = async (nextConfig: ApiConfig) => {
		const persisted = await ApiConfigStore.save(nextConfig);
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
