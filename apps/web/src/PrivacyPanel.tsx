import { useState } from "react";
import { useMutation, useQuery } from "convex/react";
import { makeFunctionReference } from "convex/server";

type Usage = {
  period: string;
  researchCount: number;
  planningCount: number;
  mailCount: number;
  limits: {
    research: number;
    planning: number;
    mail: number;
  };
};

type DeleteResult = {
  deleted: number;
  hasMore: boolean;
  preservedUncertain: number;
  retentionDays: number;
};

const usageReference = makeFunctionReference<
  "query",
  Record<string, never>,
  Usage
>("usage:get");
const deleteReference = makeFunctionReference<
  "mutation",
  { includeDevices?: boolean; maxRecords?: number },
  DeleteResult
>("retention:deleteMyData");

function retainedMessage(count: number): string {
  return `${count} uncertain external receipt${count === 1 ? "" : "s"} retained for safety. / 為安全起見保留 ${count} 筆不確定的外部紀錄。`;
}

export function PrivacyPanel() {
  const usage = useQuery(usageReference, {});
  const deleteData = useMutation(deleteReference);
  const [confirming, setConfirming] = useState(false);
  const [includeDevices, setIncludeDevices] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [result, setResult] = useState<DeleteResult>();

  async function deleteBatch() {
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      const next = await deleteData({
        includeDevices,
        maxRecords: 500,
      });
      setResult(next);
      setConfirming(false);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Deletion failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="settings-content" aria-label="Privacy and usage">
      <div className="settings-heading">
        <div>
          <h1>Privacy & usage</h1>
          <p>
            See your cloud usage and remove saved FlowState data.
            <br />
            查看雲端用量並刪除 FlowState 儲存的資料。
          </p>
        </div>
      </div>

      <section aria-label="Daily usage">
        <h2>Today&apos;s usage / 今日用量</h2>
        {!usage ? (
          <p role="status">Loading usage…</p>
        ) : (
          <div className="notice">
            <p>
              Usage resets on the next UTC day. Deleting data does not reset
              today&apos;s quota.
              <br />
              用量在下一個 UTC 日重設；刪除資料不會重設今天的額度。
            </p>
            <ul>
              <li>
                {usage.researchCount} of {usage.limits.research} research runs
              </li>
              <li>
                {usage.planningCount} of {usage.limits.planning} action plans
              </li>
              <li>
                {usage.mailCount} of {usage.limits.mail} email sends
              </li>
            </ul>
          </div>
        )}
      </section>

      <section aria-label="Delete cloud data">
        <h2>Delete cloud data / 刪除雲端資料</h2>
        <p>
          This removes saved preferences, grants, workflow content and action
          plans from your account. Sent email cannot be recalled. Pending or
          uncertain external effects leave a minimal receipt so FlowState will
          not send them again blindly.
          <br />
          這會刪除帳戶中的偏好、授權、工作流程內容與操作計畫。已寄出的郵件無法收回；未完成或不確定的外部操作會保留最少紀錄，避免
          FlowState 重複執行。
        </p>
        {!confirming && !result?.hasMore && (
          <button disabled={busy} onClick={() => setConfirming(true)}>
            Delete cloud data / 刪除雲端資料
          </button>
        )}
        {confirming && (
          <div
            className="notice"
            role="group"
            aria-label="Confirm cloud data deletion"
          >
            <p>
              Review this carefully. Deletion is permanent for saved cloud
              content.
              <br />
              請仔細確認；已儲存的雲端內容刪除後無法復原。
            </p>
            <label>
              <input
                type="checkbox"
                checked={includeDevices}
                disabled={busy}
                onChange={(event) => setIncludeDevices(event.target.checked)}
              />
              Also remove registered devices / 同時移除已註冊裝置
            </label>
            <div className="row-actions">
              <button disabled={busy} onClick={() => void deleteBatch()}>
                Confirm deletion / 確認刪除
              </button>
              <button disabled={busy} onClick={() => setConfirming(false)}>
                Cancel deletion / 取消刪除
              </button>
            </div>
          </div>
        )}
        {result && (
          <div className="notice" role="status">
            <p>
              {result.hasMore
                ? `${result.deleted} records removed from this batch. / 此批次已刪除 ${result.deleted} 筆資料。`
                : `Cloud data deletion complete: ${result.deleted} records. / 雲端資料刪除完成：${result.deleted} 筆。`}
            </p>
            {result.preservedUncertain > 0 && (
              <p>{retainedMessage(result.preservedUncertain)}</p>
            )}
            {result.hasMore && (
              <button disabled={busy} onClick={() => void deleteBatch()}>
                Delete remaining records / 刪除剩餘資料
              </button>
            )}
          </div>
        )}
        {error && <p role="alert">{error}</p>}
      </section>
    </section>
  );
}
