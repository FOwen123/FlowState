// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  cleanup,
  render,
  screen,
  fireEvent,
  waitFor,
} from "@testing-library/react";
import { Workspace } from "../../apps/web/src/Workspace";
afterEach(cleanup);
describe("research workspace", () => {
  it("does not claim a connection or allow research without configuration", () => {
    render(<Workspace configured={false} />);
    expect(
      screen
        .getByRole("button", { name: "Research article" })
        .hasAttribute("disabled"),
    ).toBe(true);
    expect(screen.getByText(/Cloud services are not configured/)).toBeTruthy();
  });
  it("requires an explicit review step before sending", async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    render(
      <Workspace
        configured
        onResearch={vi.fn()}
        onSend={send}
        note={{
          id: "run1",
          title: "A note",
          body: "Verified article summary",
          url: "https://example.com/article",
          status: "ready",
        }}
      />,
    );
    fireEvent.change(screen.getByLabelText("Recipient"), {
      target: { value: "test@example.com" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Review email" }));
    expect(send).not.toHaveBeenCalled();
    expect(screen.getByRole("dialog", { name: "Confirm email" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Confirm send" }));
    await waitFor(() =>
      expect(send).toHaveBeenCalledWith("run1", "test@example.com"),
    );
  });
  it("reports failures without claiming delivery", async () => {
    render(
      <Workspace
        configured
        onResearch={vi
          .fn()
          .mockRejectedValue(new Error("Provider unavailable"))}
      />,
    );
    fireEvent.change(screen.getByLabelText("Public article URL"), {
      target: { value: "https://example.com/article" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Research article" }));
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain(
        "Provider unavailable",
      ),
    );
  });
  it("invalidates the review when the underlying note changes", () => {
    const send = vi.fn();
    const note = {
      id: "run1",
      title: "A note",
      body: "Original",
      url: "https://example.com",
      status: "ready",
    };
    const { rerender } = render(
      <Workspace configured note={note} onSend={send} />,
    );
    fireEvent.change(screen.getByLabelText("Recipient"), {
      target: { value: "test@example.com" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Review email" }));
    rerender(
      <Workspace
        configured
        note={{ ...note, body: "Changed" }}
        onSend={send}
      />,
    );
    expect(screen.queryByRole("dialog")).toBeNull();
  });
  it("uses English without a language picker", async () => {
    const research = vi.fn().mockResolvedValue(undefined);
    render(<Workspace configured onResearch={research} />);
    expect(screen.queryByRole("combobox")).toBeNull();
    fireEvent.change(screen.getByLabelText("Public article URL"), {
      target: { value: "https://example.com/article" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Research article" }));
    await waitFor(() =>
      expect(research).toHaveBeenCalledWith(
        "https://example.com/article",
        "en",
      ),
    );
  });
  it("can research a topic without treating it as an article URL", async () => {
    const search = vi.fn().mockResolvedValue(undefined);
    render(<Workspace configured onSearch={search} />);
    fireEvent.click(screen.getByRole("button", { name: "Research topic" }));
    fireEvent.change(screen.getByLabelText("Topic or question"), {
      target: { value: "Accessible transport in Taipei" },
    });
    fireEvent.click(
      screen.getByRole("button", { name: "Search public sources" }),
    );
    await waitFor(() =>
      expect(search).toHaveBeenCalledWith(
        "Accessible transport in Taipei",
        "en",
      ),
    );
  });
});
it("shows the configured sender in the exact email review", () => {
  render(
    <Workspace
      configured
      sender="assistant@example.com"
      onSend={vi.fn()}
      note={{
        id: "run1",
        title: "Summary",
        body: "Content",
        url: "https://example.com",
        status: "ready",
      }}
    />,
  );
  fireEvent.change(screen.getByLabelText("Recipient"), {
    target: { value: "test@example.com" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Review email" }));
  expect(screen.getByRole("dialog").textContent).toContain(
    "assistant@example.com",
  );
});
