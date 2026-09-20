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
  return `${count} uncertain external receipt${count === 1 ? "" : "s"} retained for safety.`;
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
          <p>See your cloud usage and remove saved FlowState data.</p>
        </div>
      </div>

      <section aria-label="Daily usage">
        <h2>Today&apos;s usage</h2>
        {!usage ? (
          <p role="status">Loading usage…</p>
        ) : (
          <div className="notice">
            <p>
              Usage resets on the next UTC day. Deleting data does not reset
              today&apos;s quota.
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
        <h2>Delete cloud data</h2>
        <p>
          This removes saved preferences, grants, workflow content and action
          plans from your account. Sent email cannot be recalled. Pending or
          uncertain external effects leave a minimal receipt so FlowState will
          not send them again blindly.
        </p>
        {!confirming && !result?.hasMore && (
          <button disabled={busy} onClick={() => setConfirming(true)}>
            Delete cloud data
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
            </p>
            <label>
              <input
                type="checkbox"
                checked={includeDevices}
                disabled={busy}
                onChange={(event) => setIncludeDevices(event.target.checked)}
              />
              Also remove registered devices
            </label>
            <div className="row-actions">
              <button disabled={busy} onClick={() => void deleteBatch()}>
                Confirm deletion
              </button>
              <button disabled={busy} onClick={() => setConfirming(false)}>
                Cancel deletion
              </button>
            </div>
          </div>
        )}
        {result && (
          <div className="notice" role="status">
            <p>
              {result.hasMore
                ? `${result.deleted} records removed from this batch.`
                : `Cloud data deletion complete: ${result.deleted} records.`}
            </p>
            {result.preservedUncertain > 0 && (
              <p>{retainedMessage(result.preservedUncertain)}</p>
            )}
            {result.hasMore && (
              <button disabled={busy} onClick={() => void deleteBatch()}>
                Delete remaining records
              </button>
            )}
          </div>
        )}
        {error && <p role="alert">{error}</p>}
      </section>
    </section>
  );
}
