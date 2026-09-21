import { useLayoutEffect, useRef, useState } from "react";

export function WaveMark() {
  return <span className="brand-mark" aria-hidden="true" />;
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
    <div className="landing" id="top">
      <header className="landing-nav" inert={privacy}>
        <a className="brand" href="#top">
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
            <p className="eyebrow">
              <span className="eyebrow-dot" aria-hidden="true" />
              VOICE CONTROL FOR EVERYDAY LIFE
            </p>
            <h1>
              Control your Mac.
              <br />
              With your voice.
            </h1>
            <p className="hero-description">
              Flow State turns your voice into action. Open apps, write text,
              and move through tasks in English.
            </p>
            <div className="download-action">
              <div className="hero-actions">
                <button
                  type="button"
                  className="download-button"
                  disabled
                  aria-describedby="download-status"
                >
                  <svg
                    width="18"
                    height="18"
                    viewBox="0 0 24 24"
                    aria-hidden="true"
                  >
                    <path
                      d="M12 3v12m-5-5 5 5 5-5M5 16v5h14v-5"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="1.8"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                  Download for Mac
                </button>
                <button
                  type="button"
                  className="text-button workspace-button"
                  aria-label="Open workspace"
                  onClick={onOpen}
                >
                  Explore the app ↓
                </button>
              </div>
              <p id="download-status" className="small-muted">
                For macOS · English
                <br />
                In development. Download available at release.
              </p>
            </div>
          </div>

          <div
            className="transcript-strip"
            role="img"
            aria-label="Voice command preview"
          >
            <svg
              className="waveform"
              width="48"
              height="26"
              viewBox="0 0 48 26"
              aria-hidden="true"
            >
              <path
                d="M4 11v4M11 7v12M18 3v20M25 6v14M32 1v24M39 8v10M46 11v4"
                fill="none"
                stroke="currentColor"
                strokeWidth="3"
                strokeLinecap="round"
              />
            </svg>
            <span className="transcript">Open Brave.</span>
            <button
              type="button"
              className="preview-stop"
              aria-label="Stop preview"
              title="Stop preview (design only)"
              disabled
            >
              <svg
                width="14"
                height="14"
                viewBox="0 0 14 14"
                aria-hidden="true"
              >
                <rect x="2" y="2" width="10" height="10" rx="2" />
              </svg>
            </button>
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
            <br />
            I wanted to keep building, reading, and following an idea
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
              Speak naturally in English.
              <br />
              Switch between commands and dictation.
            </p>
          </article>
          <article>
            <h3>Prepare your next message</h3>
            <p>
              Draft a message for Gmail in Brave.
              <br />
              Review it yourself before sending.
            </p>
          </article>
          <article>
            <h3>Take over at any time</h3>
            <p>
              Say “stop” to cancel. Use your mouse to pause.
              <br />
              Resume when you're ready.
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
            type="button"
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
          <button type="button" autoFocus onClick={closePrivacy}>
            Close
          </button>
        </section>
      )}
    </div>
  );
}
