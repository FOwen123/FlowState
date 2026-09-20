// @vitest-environment jsdom
import { afterEach, expect, it, vi } from "vitest";
import {
  cleanup,
  render,
  screen,
  fireEvent,
  waitFor,
} from "@testing-library/react";
import { getFunctionName } from "convex/server";
import { LiveWorkspace } from "../../apps/web/src/LiveWorkspace";
const mocks = vi.hoisted(() => ({
  approve: vi.fn(),
  send: vi.fn(),
  cancel: vi.fn(),
  status: "awaiting_approval",
}));
vi.mock("convex/react", () => ({
  useMutation: (ref: Parameters<typeof getFunctionName>[0]) => {
    const name = getFunctionName(ref);
    if (name === "workflows:approveResearchEmail") return mocks.approve;
    if (name === "workflows:cancelResearch") return mocks.cancel;
    return vi.fn();
  },
  useAction: () => mocks.send,
  useQuery: (ref: Parameters<typeof getFunctionName>[0], args: unknown) => {
    if (getFunctionName(ref) === "history:recent")
      return [{ id: "run1", title: "Saved note", status: mocks.status }];
    if (args === "skip") return undefined;
    return {
      id: "run1",
      status: mocks.status,
      error: null,
      note:
        mocks.status === "running"
          ? null
          : {
              id: "run1",
              title: "Saved note",
              body: "Sourced summary",
              url: "https://example.com/article",
              status:
                mocks.status === "awaiting_approval" ? "ready" : mocks.status,
            },
    };
  },
}));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  mocks.status = "awaiting_approval";
});
function openRun() {
  render(<LiveWorkspace />);
  fireEvent.change(screen.getByLabelText("Recent workflows / 最近的工作流程"), {
    target: { value: "run1" },
  });
}
it("renders the flat backend run and approves the exact note before sending", async () => {
  mocks.approve.mockResolvedValue({ approvalId: "approval1" });
  mocks.send.mockResolvedValue({ status: "sent" });
  openRun();
  expect(screen.getByText("Sourced summary")).toBeTruthy();
  fireEvent.change(screen.getByLabelText("Recipient"), {
    target: { value: "test@example.com" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Review email" }));
  expect(mocks.approve).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Confirm send" }));
  await waitFor(() =>
    expect(mocks.send).toHaveBeenCalledWith({
      runId: "run1",
      approvalId: "approval1",
    }),
  );
  expect(mocks.approve).toHaveBeenCalledWith({
    runId: "run1",
    recipient: "test@example.com",
    subject: "Saved note",
    body: "Sourced summary",
  });
});
it("explains uncertain delivery and blocks another send", () => {
  mocks.status = "uncertain";
  openRun();
  expect(screen.getByText(/Check AgentMail sent history/)).toBeTruthy();
  expect(
    screen
      .getByRole("button", { name: "Review email" })
      .hasAttribute("disabled"),
  ).toBe(true);
});
it("can cancel running research without offering email retraction", async () => {
  mocks.status = "running";
  mocks.cancel.mockResolvedValue({ status: "cancelled" });
  openRun();
  fireEvent.click(
    screen.getByRole("button", { name: "Cancel research / 取消研究" }),
  );
  await waitFor(() =>
    expect(mocks.cancel).toHaveBeenCalledWith({ runId: "run1" }),
  );
});
