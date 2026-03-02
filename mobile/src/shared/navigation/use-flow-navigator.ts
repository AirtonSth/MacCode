import { usePathname, useRouter } from "expo-router";
import { useCallback, useEffect, useRef } from "react";

export type AppFlowRoute = "/workspaces" | "/threads" | "/chat" | "/settings";
export type AppFlowTarget =
	| AppFlowRoute
	| {
		pathname: AppFlowRoute;
		params?: Record<string, string>;
	};

const getPathname = (target: AppFlowTarget): AppFlowRoute => {
	return typeof target === "string" ? target : target.pathname;
};

const getReplaceInput = (
	target: AppFlowTarget,
): {
	pathname: AppFlowRoute;
	params?: Record<string, string>;
} => {
	if (typeof target === "string") {
		return { pathname: target };
	}

	return {
		pathname: target.pathname,
		params: target.params,
	};
};

export const useFlowNavigator = () => {
	const router = useRouter();
	const pathname = usePathname();
	const pendingRouteRef = useRef<AppFlowRoute | null>(null);

	useEffect(() => {
		if (pendingRouteRef.current === pathname) {
			pendingRouteRef.current = null;
		}
	}, [pathname]);

	const replace = useCallback((target: AppFlowTarget): boolean => {
		const route = getPathname(target);
		if (pathname === route || pendingRouteRef.current === route) {
			return false;
		}

		pendingRouteRef.current = route;
		router.replace(getReplaceInput(target));
		return true;
	}, [pathname, router]);

	return { replace };
};
