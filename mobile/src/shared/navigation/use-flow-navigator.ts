import { type Href, usePathname, useRouter } from "expo-router";
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
		if (typeof target === "string") {
			router.replace(target);
		} else {
			router.replace({
				params: target.params,
				pathname: target.pathname,
			} satisfies Href);
		}
		return true;
	}, [pathname, router]);

	const push = useCallback((target: AppFlowTarget): boolean => {
		const route = getPathname(target);
		if (pathname === route || pendingRouteRef.current === route) {
			return false;
		}

		pendingRouteRef.current = route;
		if (typeof target === "string") {
			router.push(target);
		} else {
			router.push({
				params: target.params,
				pathname: target.pathname,
			} satisfies Href);
		}
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
