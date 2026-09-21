// @vitest-environment jsdom
import { afterEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { Landing } from "../../apps/web/src/Landing";
afterEach(cleanup);
it("opens the real workspace and does not invent a Mac download", () => {
  const open = vi.fn();
  render(<Landing onOpen={open} />);
  expect(screen.getByRole("heading", { level: 1 }).textContent).toBe(
    "Control your Mac.With your voice.",
  );
  expect(
    screen
      .getByRole("button", { name: "Download for Mac" })
      .hasAttribute("disabled"),
  ).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Open workspace" }));
  expect(open).toHaveBeenCalledOnce();
});
it("keeps the preview honest and explains cloud privacy", () => {
  render(<Landing onOpen={() => {}} />);
  expect(
    screen.getByRole("img", { name: "Voice command preview" }),
  ).toBeTruthy();
  expect(
    screen
      .getByRole("button", { name: "Stop preview" })
      .hasAttribute("disabled"),
  ).toBe(true);
  fireEvent.click(screen.getByRole("button", { name: "Privacy" }));
  expect(
    screen.getByRole("dialog", { name: "Your data and control" }),
  ).toBeTruthy();
  expect(
    screen.getByText(
      /Screenshots and audio are not uploaded by this web workspace/,
    ),
  ).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Close" }));
  expect(screen.queryByRole("dialog")).toBeNull();
});
it("closes privacy with Escape and returns focus to its trigger", () => {
  render(<Landing onOpen={() => {}} />);
  const trigger = screen.getByRole("button", { name: "Privacy" });
  fireEvent.click(trigger);
  fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(document.activeElement).toBe(trigger);
});

it("advertises only the supported English release", () => {
  const { container } = render(<Landing onOpen={() => {}} />);
  expect(container.textContent).not.toMatch(/繁體|Chinese/);
  expect(
    screen.getByText("For macOS · English", { exact: false }),
  ).toBeTruthy();
});
