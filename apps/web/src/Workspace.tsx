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
  note?: Note;
  onResearch?: (url: string, language: "en" | "zh-Hant") => Promise<void>;
  onSearch?: (query: string, language: "en" | "zh-Hant") => Promise<void>;
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
  "zh-Hant": {
    title: "減少操作，專注當下。",
    subtitle: "研究公開文章、檢視摘要，準備好後再寄出筆記。",
    article: "閱讀文章",
    topic: "主題研究",
    question: "主題或問題",
    search: "搜尋公開來源",
    url: "公開文章網址",
    research: "研究文章",
    recipient: "收件人",
    review: "檢視郵件",
    confirm: "確認寄出",
    cancel: "取消",
    note: "閱讀筆記",
    empty: "從一個想法開始。",
    emptyBody: "加入公開文章，建立附有來源的筆記。寄出前由你確認。",
    missing: "尚未設定雲端服務。請先設定 Convex 並登入。",
    busy: "處理中…",
    dialog: "確認郵件",
    accepted: "請求已完成。請查看工作流程狀態；服務接受請求不代表已送達。",
    source: "閱讀來源",
    status: "工作流程狀態",
    control: "由你掌控",
    boundary: "此工作區不會控制你的 Mac。閱讀文章不代表授權寄出郵件。",
  },
};

export function Workspace({
  configured,
  note,
  onResearch,
  onSearch,
  onSend,
}: Props) {
  const [language, setLanguage] = useState<"en" | "zh-Hant">("en");
  const [url, setUrl] = useState("");
  const [mode, setMode] = useState<"article" | "topic">("article");
  const [topic, setTopic] = useState("");
  const [recipient, setRecipient] = useState("");
  const [approval, setApproval] = useState<{ note: Note; recipient: string }>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const l = labels[language];
  const approvalCurrent =
    configured &&
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
        <label className="language">
          Language / 語言
          <select
            aria-label="Language / 語言"
            value={language}
            onChange={(e) => setLanguage(e.target.value as "en" | "zh-Hant")}
          >
            <option value="en">English</option>
            <option value="zh-Hant">繁體中文</option>
          </select>
        </label>
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
            <p>English · 繁體中文</p>
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
                  setApproval({ note: { ...note }, recipient });
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
