export const config = {
	runner: "local",
	specs: ["./e2e/frontend/**/*.e2e.mjs"],
	exclude: [],
	maxInstances: 1,
	capabilities: [
		{
			browserName: "chrome",
			"goog:chromeOptions": {
				args: ["--headless=new", "--disable-gpu", "--window-size=1440,900", "--no-sandbox"],
			},
			maxInstances: 1,
		},
	],
	logLevel: "warn",
	baseUrl: "http://127.0.0.1:4173",
	waitforTimeout: 15_000,
	connectionRetryTimeout: 120_000,
	connectionRetryCount: 1,
	services: ["chromedriver"],
	framework: "mocha",
	hostname: "127.0.0.1",
	reporters: ["spec"],
	mochaOpts: {
		timeout: 60_000,
		ui: "bdd",
	},
};
