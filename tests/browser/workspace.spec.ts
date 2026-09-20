import { test, expect } from "@playwright/test";
import { build } from "esbuild";
import { readFile } from "node:fs/promises";

// Browser-only component harness: no dev server, backend, or real email.
test("review, cancel, confirm, Chinese labels and mobile layout", async ({
  page,
}) => {
  const bundle = await build({
    stdin: {
      contents: `import React from 'react'; import {createRoot} from 'react-dom/client'; import {Workspace} from './apps/web/src/Workspace';
      createRoot(document.getElementById('root')).render(<Workspace configured note={{id:'test',title:'Test note',body:'A synthetic source-linked note.',url:'https://example.com',status:'ready'}} onResearch={async()=>{}} onSend={async()=>{window.__sent=(window.__sent||0)+1}} />);`,
      resolveDir: process.cwd(),
      loader: "tsx",
    },
    bundle: true,
    write: false,
    format: "iife",
    define: { "process.env.NODE_ENV": '"test"' },
  });
  await page.setContent(
    '<html><head></head><body><div id="root"></div></body></html>',
  );
  await page.addStyleTag({
    content: await readFile("apps/web/src/style.css", "utf8"),
  });
  await page.addScriptTag({ content: bundle.outputFiles[0].text });
  await page.getByLabel("Recipient", { exact: true }).fill("test@example.com");
  await page.getByRole("button", { name: "Review email" }).click();
  await expect(page.getByRole("dialog")).toContainText("test@example.com");
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(await page.evaluate("window.__sent || 0")).toBe(0);
  await page.getByRole("button", { name: "Review email" }).click();
  await page.getByRole("button", { name: "Confirm send" }).click();
  await expect(page.getByRole("status")).toContainText("Request completed");
  expect(await page.evaluate("window.__sent")).toBe(1);
  await page
    .getByLabel("Language / 語言", { exact: true })
    .selectOption("zh-Hant");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "減少操作，專注當下。",
  );
  await page.setViewportSize({ width: 390, height: 844 });
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  ).toBe(true);
});

test("actual app starts without keys and makes no provider calls", async ({
  page,
}) => {
  const errors: string[] = [];
  const requests: string[] = [];
  page.on("request", (request) => requests.push(request.url()));
  page.on("pageerror", (error) => errors.push(error.message));
  const bundle = await build({
    entryPoints: ["apps/web/src/main.tsx"],
    bundle: true,
    write: false,
    format: "iife",
    loader: { ".css": "empty" },
    define: { "process.env.NODE_ENV": '"test"', "import.meta.env": "{}" },
  });
  await page.setContent('<div id="root"></div>');
  await page.addScriptTag({ content: bundle.outputFiles[0].text });
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Your Mac,in your words.",
  );
  await page.getByRole("button", { name: "Open workspace" }).click();
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Less effort. More flow.",
  );
  await expect(
    page.getByRole("button", { name: "Research article" }),
  ).toBeDisabled();
  expect(errors).toEqual([]);
  expect(requests).toEqual([]);
});

test("Paper landing remains usable on desktop and mobile", async ({ page }) => {
  const bundle = await build({
    stdin: {
      contents: `import React from 'react'; import {createRoot} from 'react-dom/client'; import {Landing} from './apps/web/src/Landing'; createRoot(document.getElementById('root')).render(<Landing onOpen={()=>{window.__opened=true}} />)`,
      resolveDir: process.cwd(),
      loader: "tsx",
    },
    bundle: true,
    write: false,
    format: "iife",
    define: { "process.env.NODE_ENV": '"test"' },
  });
  await page.setViewportSize({ width: 1440, height: 1068 });
  await page.setContent('<div id="root"></div>');
  await page.addStyleTag({
    content: await readFile("apps/web/src/style.css", "utf8"),
  });
  await page.addScriptTag({ content: bundle.outputFiles[0].text });
  await expect(
    page.getByRole("button", { name: "Download for Mac" }),
  ).toBeDisabled();
  await page.screenshot({
    path: "test-results/paper-landing-desktop.png",
    fullPage: true,
  });
  await page.getByRole("button", { name: "Privacy", exact: true }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(
    page.getByRole("button", { name: "Privacy", exact: true }),
  ).toBeFocused();
  await page.setViewportSize({ width: 390, height: 844 });
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  ).toBe(true);
  await page.getByRole("button", { name: "Open workspace" }).click();
  expect(await page.evaluate("window.__opened")).toBe(true);
  await page.screenshot({
    path: "test-results/paper-landing-mobile.png",
    fullPage: true,
  });
});
