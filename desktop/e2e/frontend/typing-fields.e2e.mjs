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

	it("appends selected absolute paths when clicking Attach context", async () => {
		await browser.url("/typing-harness.html");

		const composer = await $("textarea[aria-label='Message input']");
		await composer.waitForDisplayed();
		await composer.setValue("Analyze the text");

		await browser.execute(() => {
			window.__e2eSetPickerPaths(["/Users/samuelfajreldines/Downloads/codex.txt"]);
		});

		const attachButton = await $("button[aria-label='Attach context']");
		await attachButton.waitForDisplayed();
		await attachButton.waitForEnabled();
		await attachButton.click();

		assert.equal(await composer.getValue(), "Analyze the text /Users/samuelfajreldines/Downloads/codex.txt");
	});

	it("triggers system file selector when no scripted picker value is present", async () => {
		await browser.url("/typing-harness.html");

		const attachButton = await $("button[aria-label='Attach context']");
		await attachButton.waitForDisplayed();
		await attachButton.waitForEnabled();
		await attachButton.click();

		const inputClickCount = await browser.execute(() => {
			return window.__e2eGetInputClickCount();
		});

		assert.equal(inputClickCount, 1);
	});

	it("appends dropped absolute paths to the existing composer text", async () => {
		await browser.url("/typing-harness.html");

		const composer = await $("textarea[aria-label='Message input']");
		await composer.waitForDisplayed();
		await composer.setValue("Analyze the text");

		await browser.execute(() => {
			const dropzone = document.querySelector("[data-testid='composer-dropzone']");
			if (!(dropzone instanceof HTMLElement)) {
				throw new Error("Dropzone not found");
			}

			const transfer = new DataTransfer();
			transfer.setData(
				"text/plain",
				"/Users/samuelfajreldines/Downloads/codex.txt\n/Users/samuelfajreldines/Downloads/context-folder",
			);

			dropzone.dispatchEvent(
				new DragEvent("dragover", {
					bubbles: true,
					cancelable: true,
					dataTransfer: transfer,
				}),
			);
			dropzone.dispatchEvent(
				new DragEvent("drop", {
					bubbles: true,
					cancelable: true,
					dataTransfer: transfer,
				}),
			);
		});

		assert.equal(
			await composer.getValue(),
			"Analyze the text /Users/samuelfajreldines/Downloads/codex.txt /Users/samuelfajreldines/Downloads/context-folder",
		);
	});
});
