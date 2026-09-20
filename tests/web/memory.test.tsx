// @vitest-environment jsdom
import { afterEach, expect, it, vi } from "vitest";
import {
  cleanup,
  render,
  screen,
  fireEvent,
  waitFor,
} from "@testing-library/react";
import { MemoryPanel } from "../../apps/web/src/MemoryPanel";
afterEach(cleanup);
it("saves an explicit bilingual preference and waits for backend confirmation", async () => {
  const save = vi.fn().mockResolvedValue(undefined);
  render(<MemoryPanel items={[]} onSave={save} onRemove={vi.fn()} />);
  fireEvent.click(
    screen.getByRole("button", { name: "Add preference / 新增偏好" }),
  );
  fireEvent.change(screen.getByLabelText("When I say / 當我說"), {
    target: { value: "我的瀏覽器" },
  });
  fireEvent.change(screen.getByLabelText("Use / 使用"), {
    target: { value: "Brave" },
  });
  fireEvent.click(
    screen.getByRole("button", { name: "Save to my account / 儲存至帳戶" }),
  );
  await waitFor(() =>
    expect(save).toHaveBeenCalledWith(expect.stringMatching(/^memory:/), {
      kind: "vocabulary",
      phrase: "我的瀏覽器",
      replacement: "Brave",
      source: "explicit",
    }),
  );
});
it("edits existing values and confirms deletion", async () => {
  const remove = vi.fn().mockResolvedValue(undefined);
  render(
    <MemoryPanel
      items={[
        {
          key: "memory:a",
          value: {
            kind: "vocabulary",
            phrase: "My browser",
            replacement: "Brave",
            source: "explicit",
          },
        },
      ]}
      onSave={vi.fn()}
      onRemove={remove}
    />,
  );
  fireEvent.click(screen.getByRole("button", { name: "Edit My browser" }));
  expect((screen.getByLabelText("Use / 使用") as HTMLInputElement).value).toBe(
    "Brave",
  );
  fireEvent.click(screen.getByRole("button", { name: "Cancel / 取消" }));
  fireEvent.click(screen.getByRole("button", { name: "Delete My browser" }));
  expect(remove).not.toHaveBeenCalled();
  fireEvent.click(
    screen.getByRole("button", { name: "Confirm delete / 確認刪除" }),
  );
  await waitFor(() => expect(remove).toHaveBeenCalledWith("memory:a"));
});
it("does not erase the editor or claim success on failed save", async () => {
  render(
    <MemoryPanel
      items={[]}
      onSave={vi.fn().mockRejectedValue(new Error("Network unavailable"))}
      onRemove={vi.fn()}
    />,
  );
  fireEvent.click(
    screen.getByRole("button", { name: "Add preference / 新增偏好" }),
  );
  fireEvent.change(screen.getByLabelText("When I say / 當我說"), {
    target: { value: "Flow" },
  });
  fireEvent.change(screen.getByLabelText("Use / 使用"), {
    target: { value: "Flow State" },
  });
  fireEvent.click(
    screen.getByRole("button", { name: "Save to my account / 儲存至帳戶" }),
  );
  await waitFor(() =>
    expect(screen.getByRole("alert").textContent).toContain(
      "Network unavailable",
    ),
  );
  expect((screen.getByLabelText("Use / 使用") as HTMLInputElement).value).toBe(
    "Flow State",
  );
});
