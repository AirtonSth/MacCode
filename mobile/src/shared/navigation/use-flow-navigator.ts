import { type Href, usePathname, useRouter } from "expo-router";
import { useCallback, useEffect, useRef } from "react";

export type AppFlowRoute = "/workspaces" | "/threads" | "/recent-threads" | "/chat" | "/settings";
export type AppFlowTarget =
	| AppFlowRoute
	| {
		pathname: AppFlowRoute;
		params?: Record<string, string>;
	};

const PENDING_ROUTE_TIMEOUT_MS = 3000;

const getPathname = (target: AppFlowTarget): AppFlowRoute => {
	return typeof target === "string" ? target : target.pathname;
};

export const useFlowNavigator = () => {
	const router = useRouter();
	const pathname = usePathname();
	const pendingRouteRef = useRef<AppFlowRoute | null>(null);
	const pendingRouteTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

	useEffect(() => {
		if (pendingRouteRef.current === pathname) {
			pendingRouteRef.current = null;
			if (pendingRouteTimerRef.current) {
				clearTimeout(pendingRouteTimerRef.current);
				pendingRouteTimerRef.current = null;
			}
		}
	}, [pathname]);

	const setPendingRoute = useCallback((route: AppFlowRoute) => {
		pendingRouteRef.current = route;
		if (pendingRouteTimerRef.current) {
			clearTimeout(pendingRouteTimerRef.current);
		}
		pendingRouteTimerRef.current = setTimeout(() => {
			pendingRouteRef.current = null;
			pendingRouteTimerRef.current = null;
		}, PENDING_ROUTE_TIMEOUT_MS);
	}, []);

	const replace = useCallback((target: AppFlowTarget): boolean => {
		const route = getPathname(target);
		if (pathname === route || pendingRouteRef.current === route) {
			return false;
		}

		setPendingRoute(route);
		if (typeof target === "string") {
			router.replace(target);
		} else {
			router.replace({
				params: target.params,
				pathname: target.pathname,
			} satisfies Href);
		}
		return true;
	}, [pathname, router, setPendingRoute]);

	const push = useCallback((target: AppFlowTarget): boolean => {
		const route = getPathname(target);
		if (pathname === route || pendingRouteRef.current === route) {
			return false;
		}

		setPendingRoute(route);
		if (typeof target === "string") {
			router.push(target);
		} else {
			router.push({
				params: target.params,
				pathname: target.pathname,
			} satisfies Href);
		}
		return true;
	}, [pathname, router, setPendingRoute]);

	const goBackOr = useCallback((fallback: AppFlowTarget): boolean => {
		if (router.canGoBack()) {
			router.back();
			return true;
		}

		return replace(fallback);
	}, [replace, router]);

	return { goBackOr, push, replace };
};
