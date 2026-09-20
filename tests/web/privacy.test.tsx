// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { getFunctionName } from "convex/server";

import { PrivacyPanel } from "../../apps/web/src/PrivacyPanel";

const mocks = vi.hoisted(() => ({
  deleteData: vi.fn(),
  usage: {
    period: "2026-09-20",
    researchCount: 2,
    planningCount: 1,
    mailCount: 1,
    limits: { research: 100, planning: 100, mail: 20 },
  },
}));

vi.mock("convex/react", () => ({
  useQuery: (ref: Parameters<typeof getFunctionName>[0]) =>
    getFunctionName(ref) === "usage:get" ? mocks.usage : undefined,
  useMutation: (ref: Parameters<typeof getFunctionName>[0]) =>
    getFunctionName(ref) === "retention:deleteMyData"
      ? mocks.deleteData
      : vi.fn(),
}));

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

describe("privacy panel", () => {
  it("shows usage and requires explicit confirmation before deletion", () => {
    render(<PrivacyPanel />);
    expect(screen.getByText(/2 of 100 research runs/)).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: /Delete cloud data/ }));
    expect(
      screen.getByRole("group", { name: /Confirm cloud data deletion/ }),
    ).toBeTruthy();
    expect(mocks.deleteData).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: /Cancel deletion/ }));
    expect(
      screen.queryByRole("group", { name: /Confirm cloud data deletion/ }),
    ).toBeNull();
    expect(mocks.deleteData).not.toHaveBeenCalled();
  });

  it("requires a second explicit batch action when deletion reports hasMore", async () => {
    mocks.deleteData
      .mockResolvedValueOnce({
        deleted: 500,
        hasMore: true,
        preservedUncertain: 1,
        retentionDays: 30,
      })
      .mockResolvedValueOnce({
        deleted: 2,
        hasMore: false,
        preservedUncertain: 0,
        retentionDays: 30,
      });
    render(<PrivacyPanel />);
    fireEvent.click(screen.getByRole("button", { name: /Delete cloud data/ }));
    fireEvent.click(screen.getByRole("button", { name: /Confirm deletion/ }));
    await waitFor(() => expect(mocks.deleteData).toHaveBeenCalledTimes(1));
    expect(screen.getByText(/1 uncertain external receipt/)).toBeTruthy();
    expect(
      screen.getByRole("button", { name: /Delete remaining records/ }),
    ).toBeTruthy();
    fireEvent.click(
      screen.getByRole("button", { name: /Delete remaining records/ }),
    );
    await waitFor(() => expect(mocks.deleteData).toHaveBeenCalledTimes(2));
    expect(mocks.deleteData).toHaveBeenLastCalledWith({
      includeDevices: false,
      maxRecords: 500,
    });
  });

  it("reports deletion failures without claiming completion", async () => {
    mocks.deleteData.mockRejectedValue(new Error("Deletion unavailable"));
    render(<PrivacyPanel />);
    fireEvent.click(screen.getByRole("button", { name: /Delete cloud data/ }));
    fireEvent.click(screen.getByRole("button", { name: /Confirm deletion/ }));
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain(
        "Deletion unavailable",
      ),
    );
    expect(screen.queryByText(/Cloud data deletion complete/)).toBeNull();
  });
});

it("shows English privacy copy without a second language", () => {
  const { container } = render(<PrivacyPanel />);
  expect(container.textContent).not.toMatch(/\p{Script=Han}/u);
  fireEvent.click(screen.getByRole("button", { name: /^Delete cloud data/ }));
  expect(container.textContent).not.toMatch(/\p{Script=Han}/u);
});
