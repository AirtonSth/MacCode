import assert from "node:assert/strict";

describe("Frontend typing fields", () => {
	it("allows typing in Ask for follow-up changes and Run command inputs", async () => {
		await browser.url("/typing-harness.html");

		const composer = await $("textarea[aria-label='Message input']");
		await composer.waitForDisplayed();
		await composer.waitForEnabled();
		await composer.click();
		await composer.setValue("typing in composer works");

		assert.equal(await composer.getAttribute("placeholder"), "Ask for follow-up changes");
		assert.equal(await composer.getValue(), "typing in composer works");

		const terminalInput = await $("input[aria-label='Terminal command']");
		await terminalInput.waitForDisplayed();
		await terminalInput.waitForEnabled();
		await terminalInput.click();
		await terminalInput.setValue("ls -la");

		assert.equal(await terminalInput.getAttribute("placeholder"), "Run command (example: ls -la)");
		assert.equal(await terminalInput.getValue(), "ls -la");
	});
});
