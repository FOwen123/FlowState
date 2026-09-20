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
import { AccountWorkspace } from "../../apps/web/src/AccountWorkspace";
const mocks = vi.hoisted(() => ({
  save: vi.fn(),
  remove: vi.fn(),
  revoke: vi.fn(),
}));
vi.mock("../../apps/web/src/LiveWorkspace", () => ({
  LiveWorkspace: () => <p>Reading workspace</p>,
}));
vi.mock("convex/react", () => ({
  useQuery: (ref: Parameters<typeof getFunctionName>[0]) => {
    const name = getFunctionName(ref);
    if (name === "preferences:list")
      return [
        {
          key: "memory:a",
          value: {
            phrase: "My music",
            replacement: "Spotify",
            kind: "appAlias",
            source: "explicit",
          },
        },
      ];
    if (name === "devices:list")
      return [
        {
          id: "id1",
          deviceId: "device123",
          name: "My Mac",
          active: true,
          revokedAt: null,
        },
      ];
    if (name === "grants:list") return [];
    return undefined;
  },
  useMutation: (ref: Parameters<typeof getFunctionName>[0]) =>
    ({
      "preferences:set": mocks.save,
      "preferences:remove": mocks.remove,
      "devices:revoke": mocks.revoke,
    })[getFunctionName(ref)] ?? vi.fn(),
}));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});
it("wires explicit memory editing to the authenticated account", async () => {
  mocks.save.mockResolvedValue({});
  render(<AccountWorkspace />);
  fireEvent.click(screen.getByRole("button", { name: "Memory / 記憶" }));
  fireEvent.click(screen.getByRole("button", { name: "Edit My music" }));
  fireEvent.change(screen.getByLabelText("Use / 使用"), {
    target: { value: "Apple Music" },
  });
  fireEvent.click(
    screen.getByRole("button", { name: "Save to my account / 儲存至帳戶" }),
  );
  await waitFor(() =>
    expect(mocks.save).toHaveBeenCalledWith({
      key: "memory:a",
      valueJson: JSON.stringify({
        phrase: "My music",
        replacement: "Apple Music",
        kind: "appAlias",
        source: "explicit",
      }),
    }),
  );
});
it("requires confirmation before revoking a device", async () => {
  mocks.revoke.mockResolvedValue({});
  render(<AccountWorkspace />);
  fireEvent.click(screen.getByRole("button", { name: "Permissions / 權限" }));
  fireEvent.click(screen.getByRole("button", { name: "Revoke My Mac" }));
  expect(mocks.revoke).not.toHaveBeenCalled();
  fireEvent.click(
    screen.getByRole("button", { name: "Confirm revoke / 確認撤銷" }),
  );
  await waitFor(() =>
    expect(mocks.revoke).toHaveBeenCalledWith({ deviceId: "device123" }),
  );
});
