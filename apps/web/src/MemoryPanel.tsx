import { useState } from "react";
export type MemoryValue = {
  kind: string;
  phrase: string;
  replacement: string;
  source: "explicit";
};
export type Preference = { key: string; value: unknown };
function memory(value: unknown): value is MemoryValue {
  return (
    typeof value === "object" &&
    value !== null &&
    "phrase" in value &&
    typeof value.phrase === "string" &&
    "replacement" in value &&
    typeof value.replacement === "string" &&
    "kind" in value &&
    typeof value.kind === "string" &&
    "source" in value &&
    value.source === "explicit"
  );
}
export function MemoryPanel({
  items,
  onSave,
  onRemove,
}: {
  items: Preference[];
  onSave: (key: string, value: MemoryValue) => Promise<unknown>;
  onRemove: (key: string) => Promise<unknown>;
}) {
  const [editing, setEditing] = useState<{ key: string; value: MemoryValue }>();
  const [deleting, setDeleting] = useState<string>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function perform(action: () => Promise<unknown>) {
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      await action();
      setEditing(undefined);
      setDeleting(undefined);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Request failed");
    } finally {
      setBusy(false);
    }
  }
  const rows = items.filter(
    (item): item is { key: string; value: MemoryValue } => memory(item.value),
  );
  return (
    <section className="settings-content" aria-label="Memory">
      <div className="settings-heading">
        <div>
          <h1>Memory</h1>
          <p>Your words. Your preferences. Always editable.</p>
        </div>
        <button
          disabled={busy}
          onClick={() => {
            setError("");
            setEditing({
              key: "memory:" + crypto.randomUUID(),
              value: {
                kind: "vocabulary",
                phrase: "",
                replacement: "",
                source: "explicit",
              },
            });
          }}
        >
          Add preference
        </button>
      </div>
      <p className="notice">
        These are preferences you explicitly save to your cloud account. Nothing
        is learned automatically. Mac-only preferences stay on your Mac until
        you choose to share them.
      </p>
      <div className="memory-table" role="table" aria-label="Saved preferences">
        <div className="memory-row memory-labels" role="row">
          <span role="columnheader">When I say</span>
          <span role="columnheader">Use</span>
          <span role="columnheader">Source</span>
          <span role="columnheader">Manage</span>
        </div>
        {rows.length === 0 && <p>No saved preferences yet.</p>}
        {rows.map((item) => (
          <div className="memory-row" role="row" key={item.key}>
            <span role="cell">{item.value.phrase}</span>
            <span role="cell">{item.value.replacement}</span>
            <span className="small-muted" role="cell">
              You told me
            </span>
            <div role="cell" className="row-actions">
              <button
                aria-label={"Edit " + item.value.phrase}
                disabled={busy}
                onClick={() => setEditing(item)}
              >
                Edit
              </button>
              <button
                aria-label={"Delete " + item.value.phrase}
                disabled={busy}
                onClick={() => setDeleting(item.key)}
              >
                Delete
              </button>
            </div>
          </div>
        ))}
      </div>
      {editing && (
        <form
          className="memory-editor"
          onSubmit={(e) => {
            e.preventDefault();
            void perform(() =>
              onSave(editing.key, {
                ...editing.value,
                phrase: editing.value.phrase.trim(),
                replacement: editing.value.replacement.trim(),
              }),
            );
          }}
        >
          <label htmlFor="memory-kind">Preference type</label>
          <select
            id="memory-kind"
            disabled={busy}
            value={editing.value.kind}
            onChange={(e) =>
              setEditing({
                ...editing,
                value: { ...editing.value, kind: e.target.value },
              })
            }
          >
            <option value="vocabulary">Vocabulary</option>
            <option value="appAlias">App alias</option>
            <option value="style">Writing style</option>
            <option value="folder">Folder preference</option>
          </select>
          <label htmlFor="memory-phrase">When I say</label>
          <input
            id="memory-phrase"
            required
            maxLength={200}
            disabled={busy}
            value={editing.value.phrase}
            onChange={(e) =>
              setEditing({
                ...editing,
                value: { ...editing.value, phrase: e.target.value },
              })
            }
          />
          <label htmlFor="memory-value">Use</label>
          <input
            id="memory-value"
            required
            maxLength={2000}
            disabled={busy}
            value={editing.value.replacement}
            onChange={(e) =>
              setEditing({
                ...editing,
                value: { ...editing.value, replacement: e.target.value },
              })
            }
          />
          <div className="row-actions">
            <button
              disabled={
                busy ||
                !editing.value.phrase.trim() ||
                !editing.value.replacement.trim()
              }
            >
              Save to my account
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={() => setEditing(undefined)}
            >
              Cancel
            </button>
          </div>
        </form>
      )}
      {deleting && (
        <div
          className="notice"
          role="group"
          aria-label="Confirm preference deletion"
        >
          <p>Delete this preference from your cloud account?</p>
          <button
            disabled={busy}
            onClick={() => void perform(() => onRemove(deleting))}
          >
            Confirm delete
          </button>
          <button disabled={busy} onClick={() => setDeleting(undefined)}>
            Cancel
          </button>
        </div>
      )}
      {error && <p role="alert">{error}</p>}
    </section>
  );
}
