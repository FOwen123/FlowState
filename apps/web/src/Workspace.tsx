import { useState } from "react";

export type Note = {
  id: string;
  title: string;
  body: string;
  url: string;
  status: string;
};
type Props = {
  configured: boolean;
  sender?: string;
  note?: Note;
  onResearch?: (url: string, language: "en") => Promise<void>;
  onSearch?: (query: string, language: "en") => Promise<void>;
  onSend?: (id: string, recipient: string) => Promise<void>;
};
const labels = {
  en: {
    title: "Less effort. More flow.",
    subtitle:
      "Research a public article, review the result, and send a note when you are ready.",
    article: "Read article",
    topic: "Research topic",
    question: "Topic or question",
    search: "Search public sources",
    url: "Public article URL",
    research: "Research article",
    recipient: "Recipient",
    review: "Review email",
    confirm: "Confirm send",
    cancel: "Cancel",
    note: "Your reading note",
    empty: "Your next idea starts here.",
    emptyBody:
      "Add a public article to create a sourced note. You stay in control of what gets sent.",
    missing:
      "Cloud services are not configured. Set up Convex and sign in to start.",
    busy: "Working…",
    dialog: "Confirm email",
    accepted:
      "Request completed. Check the workflow status for provider acceptance; delivery is not guaranteed.",
    source: "Read source",
    status: "Workflow status",
    control: "You are in control",
    boundary:
      "This workspace does not control your Mac. Reading an article does not authorize sending an email.",
  },
};

export function Workspace({
  configured,
  sender,
  note,
  onResearch,
  onSearch,
  onSend,
}: Props) {
  const language = "en";
  const [url, setUrl] = useState("");
  const [mode, setMode] = useState<"article" | "topic">("article");
  const [topic, setTopic] = useState("");
  const [recipient, setRecipient] = useState("");
  const [approval, setApproval] = useState<{
    note: Note;
    recipient: string;
    sender?: string;
  }>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const l = labels[language];
  const approvalCurrent =
    configured &&
    approval?.sender === sender &&
    note?.status === "ready" &&
    approval?.note.id === note.id &&
    approval.note.title === note.title &&
    approval.note.body === note.body &&
    approval.note.url === note.url;
  async function perform(action: () => Promise<void>) {
    if (busy) return;
    setBusy(true);
    setError("");
    setMessage("");
    try {
      await action();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Request failed");
    } finally {
      setBusy(false);
    }
  }
  return (
    <main lang={language}>
      <header>
        <a className="wordmark" href="/">
          ◌ &nbsp; Flow State
        </a>
      </header>
      <section className="intro">
        <p className="eyebrow">YOUR READING WORKSPACE</p>
        <h1>{l.title}</h1>
        <p>{l.subtitle}</p>
      </section>
      {!configured && (
        <p className="notice" role="status">
          {l.missing}
        </p>
      )}
      <div className="workspace">
        <section className="composer">
          <div aria-label="Research mode">
            <button
              type="button"
              aria-pressed={mode === "article"}
              disabled={busy}
              onClick={() => setMode("article")}
            >
              {l.article}
            </button>
            <button
              type="button"
              aria-pressed={mode === "topic"}
              disabled={busy}
              onClick={() => setMode("topic")}
            >
              {l.topic}
            </button>
          </div>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (!configured) return;
              if (mode === "article" && onResearch)
                void perform(() => onResearch(url, language));
              if (mode === "topic" && onSearch)
                void perform(() => onSearch(topic, language));
            }}
          >
            <label htmlFor="url">
              {mode === "article" ? l.url : l.question}
            </label>
            <input
              id="url"
              type={mode === "article" ? "url" : "text"}
              required
              value={mode === "article" ? url : topic}
              placeholder={mode === "article" ? "https://…" : "…"}
              onChange={(e) =>
                mode === "article"
                  ? setUrl(e.target.value)
                  : setTopic(e.target.value)
              }
              disabled={busy}
            />
            <button
              disabled={
                !configured ||
                (mode === "article" ? !onResearch : !onSearch) ||
                busy
              }
            >
              {busy ? l.busy : mode === "article" ? l.research : l.search}
            </button>
          </form>
          <aside>
            <h2>{l.control}</h2>
            <p>{l.boundary}</p>
            <p>English</p>
          </aside>
        </section>
        <section className="note" aria-label={l.note}>
          {note ? (
            <>
              <p className="eyebrow">
                {l.status}: {note.status}
              </p>
              <h2>{note.title}</h2>
              <p className="note-body">{note.body}</p>
              {/^https:\/\//i.test(note.url) && (
                <a href={note.url} target="_blank" rel="noreferrer">
                  {l.source} ↗
                </a>
              )}
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  setApproval({ note: { ...note }, recipient, sender });
                }}
              >
                <label htmlFor="recipient">{l.recipient}</label>
                <input
                  id="recipient"
                  type="email"
                  required
                  value={recipient}
                  disabled={busy}
                  onChange={(e) => {
                    setRecipient(e.target.value);
                    setApproval(undefined);
                  }}
                />
                <button
                  disabled={
                    !configured || !onSend || busy || note.status !== "ready"
                  }
                >
                  {l.review}
                </button>
              </form>
            </>
          ) : (
            <div className="empty">
              <span aria-hidden="true">◌</span>
              <h2>{l.empty}</h2>
              <p>{l.emptyBody}</p>
            </div>
          )}
        </section>
      </div>
      {error && <p role="alert">{error}</p>}
      {message && <p role="status">{message}</p>}
      {approval && approvalCurrent && (
        <section className="approval" role="dialog" aria-label={l.dialog}>
          <h2>{l.dialog}</h2>
          <p>From: {approval.sender ?? "Configured assistant inbox"}</p>
          <p>
            {l.recipient}: <strong>{approval.recipient}</strong>
          </p>
          <h3>{approval.note.title}</h3>
          <p className="note-body">{approval.note.body}</p>
          <button
            disabled={busy}
            onClick={() => {
              if (!onSend) return;
              const snapshot = approval;
              setApproval(undefined);
              void perform(async () => {
                await onSend(snapshot.note.id, snapshot.recipient);
                setMessage(l.accepted);
              });
            }}
          >
            {l.confirm}
          </button>
          <button disabled={busy} onClick={() => setApproval(undefined)}>
            {l.cancel}
          </button>
        </section>
      )}
      <footer>Flow State · Development preview</footer>
    </main>
  );
}
