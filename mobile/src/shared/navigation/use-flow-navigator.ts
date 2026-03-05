import { usePathname, useRouter } from "expo-router";
import { useCallback, useEffect, useRef } from "react";

export type AppFlowRoute = "/workspaces" | "/threads" | "/active-threads" | "/chat" | "/settings";
export type AppFlowTarget =
	| AppFlowRoute
	| {
		pathname: AppFlowRoute;
		params?: Record<string, string>;
	};

const getPathname = (target: AppFlowTarget): AppFlowRoute => {
	return typeof target === "string" ? target : target.pathname;
};

const getNavigationInput = (
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
		router.replace(getNavigationInput(target) as never);
		return true;
	}, [pathname, router]);

	const push = useCallback((target: AppFlowTarget): boolean => {
		const route = getPathname(target);
		if (pathname === route || pendingRouteRef.current === route) {
			return false;
		}

		pendingRouteRef.current = route;
		router.push(getNavigationInput(target) as never);
		return true;
	}, [pathname, router]);

	const goBackOr = useCallback((fallback: AppFlowTarget): boolean => {
		if (router.canGoBack()) {
			router.back();
			return true;
		}

		return replace(fallback);
	}, [replace, router]);

	return { goBackOr, push, replace };
};
