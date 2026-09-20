import { useState, useRef, useLayoutEffect } from "react";

export function WaveMark() {
  return (
    <svg width="30" height="30" viewBox="0 0 30 30" aria-hidden="true">
      <path
        d="M5 17V13M10 22V8M15 26V4M20 21V9M25 17V13"
        fill="none"
        stroke="currentColor"
        strokeWidth="3"
        strokeLinecap="round"
      />
    </svg>
  );
}
export function Landing({ onOpen }: { onOpen: () => void }) {
  const [privacy, setPrivacy] = useState(false);
  const privacyTrigger = useRef<HTMLButtonElement>(null);
  const wasOpen = useRef(false);
  useLayoutEffect(() => {
    if (!privacy && wasOpen.current) privacyTrigger.current?.focus();
    wasOpen.current = privacy;
  }, [privacy]);
  function closePrivacy() {
    setPrivacy(false);
  }
  return (
    <div className="landing">
      <header className="landing-nav" inert={privacy}>
        <a className="brand" href="#">
          <WaveMark />
          Flow State
        </a>
        <nav aria-label="Main navigation">
          <a href="#why">Why Flow State</a>
          <a href="#how">How it works</a>
          <a
            href="https://github.com/FOwen123/ProWhisper"
            target="_blank"
            rel="noreferrer"
          >
            GitHub ↗
          </a>
        </nav>
      </header>
      <main className="landing-main" inert={privacy}>
        <section className="landing-hero">
          <div className="hero-copy">
            <p className="eyebrow">● &nbsp; VOICE CONTROL FOR EVERYDAY LIFE</p>
            <h1>
              Your Mac,
              <br />
              in your words.
            </h1>
            <p className="hero-description">
              Move between apps, dictate in English or 繁體中文,
              <br className="wide-only" /> and carry a task through with less
              reaching
              <br className="wide-only" /> for the mouse and keyboard.
            </p>
            <div className="hero-actions">
              <button disabled aria-describedby="download-status">
                Download for Mac
              </button>
              <button className="text-button" onClick={onOpen}>
                Open workspace
              </button>
            </div>
            <p id="download-status" className="small-muted">
              For macOS · English + 繁體中文
              <br />
              In development. Download available at release.
            </p>
          </div>
          <div
            className="workflow-preview"
            aria-label="Illustrative workflow preview"
          >
            <div className="preview-titlebar">
              <span aria-hidden="true">● ● ●</span>
              <span>FLOW STATE · DESIGN PREVIEW</span>
            </div>
            <div className="preview-content">
              <p className="small-muted">One request. A few careful steps.</p>
              <h2 lang="zh-Hant">“研究這篇文章，幫我草擬一封 email。”</h2>
              <p className="muted">
                Read this article, research the context, and draft an email.
              </p>
              <p className="preview-steps">
                ✓ Article read <span>◌ Finding sources</span> ○ Email draft
              </p>
              <p className="small-muted">
                ◇ Current article only · Sending needs your approval
              </p>
              <div className="preview-hud">
                <span aria-hidden="true" className="progress-ring">
                  ◌
                </span>
                <div>
                  <strong>Researching related sources</strong>
                  <p>Illustrative workflow · No task is running</p>
                </div>
                <span className="preview-stop">Stop</span>
              </div>
            </div>
          </div>
        </section>
        <section id="why" className="origin">
          <div>
            <h2>
              Built from a very
              <br />
              personal need.
            </h2>
            <p className="small-muted">Owen · Creator of Flow State</p>
          </div>
          <blockquote>
            “Typing and scrolling started to hurt my hands.
            <br />I wanted to keep building, reading, and following an idea
            <br className="wide-only" /> without every step needing a keyboard
            or mouse.
            <br />
            That's why I'm building Flow State.”
          </blockquote>
        </section>
        <section id="how" className="principles" aria-label="Product direction">
          <article>
            <h3>Say it your way</h3>
            <p>
              English, 繁體中文, or a mix of both.
              <br />
              Commands and dictation stay distinct.
            </p>
          </article>
          <article>
            <h3>Carry the task through</h3>
            <p>
              Read, research, attach a file, draft a reply.
              <br />
              See each step before the next one starts.
            </p>
          </article>
          <article>
            <h3>Take over at any time</h3>
            <p>
              Local stop and explicit resume.
              <br />
              Desktop controls are being developed and tested.
            </p>
          </article>
        </section>
      </main>
      <footer className="landing-footer" inert={privacy}>
        <span>Flow State · Built for a little less hand work.</span>
        <div>
          <a
            href="https://github.com/FOwen123/ProWhisper"
            target="_blank"
            rel="noreferrer"
          >
            Follow development ↗
          </a>
          <button
            className="text-button"
            ref={privacyTrigger}
            onClick={() => setPrivacy(true)}
          >
            Privacy
          </button>
        </div>
      </footer>
      {privacy && (
        <section
          className="privacy-dialog"
          role="dialog"
          aria-modal="true"
          aria-label="Your data and control"
          onKeyDown={(event) => {
            if (event.key === "Escape") closePrivacy();
            if (event.key === "Tab") event.preventDefault();
          }}
        >
          <h2>Your data and control</h2>
          <p>
            Research requests use Convex, Firecrawl, TypeSafe and OpenAI.
            Sending a reviewed email uses AgentMail. Approved public URLs,
            queries and generated notes leave your browser for those services.
          </p>
          <p>
            Screenshots and audio are not uploaded by this web workspace. Native
            screen access requires a separate grant. Provider processing and
            retention depend on your account settings.
          </p>
          <p>
            Do not enter passwords, private links or confidential content. You
            can inspect and forget explicit memory in your workspace.
          </p>
          <button autoFocus onClick={closePrivacy}>
            Close
          </button>
        </section>
      )}
    </div>
  );
}
