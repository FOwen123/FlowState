import { useState } from "react";
import { useAction, useMutation, useQuery } from "convex/react";
import { makeFunctionReference } from "convex/server";
import { Workspace } from "./Workspace";

type RunView = {
  id: string;
  status: string;
  sender?: string | null;
  note: {
    id: string;
    title: string;
    body: string;
    url: string;
    status: string;
  } | null;
  error: string | null;
};
const registerDevice = makeFunctionReference<
  "mutation",
  { deviceId: string; name: string },
  unknown
>("workflows:registerDevice");
const createRun = makeFunctionReference<
  "mutation",
  { deviceId: string; query: string; sourceUrl?: string },
  { runId: string; status: string }
>("workflows:createResearchRun");
const runResearch = makeFunctionReference<"action", { runId: string }, unknown>(
  "workflows:runResearch",
);
const cancelResearch = makeFunctionReference<
  "mutation",
  { runId: string },
  unknown
>("workflows:cancelResearch");
const getRun = makeFunctionReference<
  "query",
  { runId: string },
  RunView | null
>("workflows:getResearchRun");
const approveEmail = makeFunctionReference<
  "mutation",
  {
    runId: string;
    recipient: string;
    subject: string;
    body: string;
    sender: string;
  },
  { approvalId: string }
>("workflows:approveResearchEmail");
const sendEmail = makeFunctionReference<
  "action",
  { runId: string; approvalId: string },
  unknown
>("workflows:sendApprovedResearchEmail");

const deliveryReceipts = makeFunctionReference<
  "query",
  { runId: string },
  Array<{ eventType: string; receivedAt: number }>
>("deliveries:forRun");

const recentRuns = makeFunctionReference<
  "query",
  Record<string, never>,
  Array<{ id: string; title: string; status: string }>
>("history:recent");

export function LiveWorkspace() {
  const [deviceId] = useState(() => {
    const key = "flowstate.browserDevice";
    const stored = localStorage.getItem(key);
    if (stored) return stored;
    const id = crypto.randomUUID();
    localStorage.setItem(key, id);
    return id;
  });
  const [runId, setRunId] = useState<string>();
  const [cancelError, setCancelError] = useState("");
  const [cancelling, setCancelling] = useState(false);
  const cancel = useMutation(cancelResearch);
  const register = useMutation(registerDevice);
  const create = useMutation(createRun);
  const research = useAction(runResearch);
  const approve = useMutation(approveEmail);
  const send = useAction(sendEmail);
  const data = useQuery(getRun, runId ? { runId } : "skip");
  const note = data?.note;
  const receipts = useQuery(deliveryReceipts, runId ? { runId } : "skip");
  const history = useQuery(recentRuns, {});
  return (
    <>
      {history && history.length > 0 && (
        <div className="auth">
          <label htmlFor="recent">Recent workflows</label>
          <select
            id="recent"
            style={{ maxWidth: "100%" }}
            value={runId ?? ""}
            onChange={(e) => setRunId(e.target.value || undefined)}
          >
            <option value="">Choose a workflow</option>
            {history.map((item) => (
              <option key={item.id} value={item.id}>
                {item.title} — {item.status}
              </option>
            ))}
          </select>
        </div>
      )}
      {data?.error && (
        <p className="auth" role="alert">
          Workflow stopped: {data.error}
        </p>
      )}
      {data && !note && (
        <p className="auth" role="status">
          Workflow: {data.status}
        </p>
      )}
      {data?.status === "uncertain" && (
        <p className="auth" role="status">
          Provider acceptance is uncertain. Check AgentMail sent history before
          any new send; retry is disabled to avoid duplicates.
        </p>
      )}
      {data && (data.status === "queued" || data.status === "running") && (
        <div className="auth">
          <button
            disabled={cancelling}
            onClick={async () => {
              setCancelling(true);
              setCancelError("");
              try {
                await cancel({ runId: data.id });
              } catch (error) {
                setCancelError(
                  error instanceof Error
                    ? error.message
                    : "Cancellation failed",
                );
              } finally {
                setCancelling(false);
              }
            }}
          >
            Cancel research
          </button>
          <p>
            Cancellation discards late results; a provider request already in
            progress may still incur usage.
          </p>
        </div>
      )}
      {cancelError && <p role="alert">{cancelError}</p>}
      {data?.status === "completed" && (
        <p className="auth" role="status">
          {receipts?.some((r) =>
            [
              "message.bounced",
              "message.rejected",
              "message.complained",
            ].includes(r.eventType),
          )
            ? "Delivery problem reported. Check the assistant inbox."
            : receipts?.some((r) => r.eventType === "message.delivered")
              ? "Delivered to the recipient’s mail server. Inbox placement is not confirmed."
              : "Accepted for sending. Delivery has not been confirmed."}
        </p>
      )}
      <Workspace
        sender={data?.sender ?? undefined}
        configured
        note={note ?? undefined}
        onResearch={async (url) => {
          await register({ deviceId, name: "Flow State web" });
          const created = await create({
            deviceId,
            query:
              "Summarize this public article in English with source attribution.",
            sourceUrl: url,
          });
          setRunId(created.runId);
          await research({ runId: created.runId });
        }}
        onSearch={async (query) => {
          await register({ deviceId, name: "Flow State web" });
          const suffix = "Answer in English with sources.";
          const created = await create({
            deviceId,
            query: query + "\n" + suffix,
          });
          setRunId(created.runId);
          await research({ runId: created.runId });
        }}
        onSend={async (id, recipient) => {
          if (!note || note.id !== id)
            throw new Error("The note changed. Review it again.");
          if (!data?.sender)
            throw new Error(
              "Sender inbox is unavailable. Review again after configuration.",
            );
          const approval = await approve({
            sender: data.sender,
            runId: id,
            recipient,
            subject: note.title,
            body: note.body,
          });
          await send({ runId: id, approvalId: approval.approvalId });
        }}
      />
    </>
  );
}
