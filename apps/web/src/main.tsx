import { StrictMode, useState } from "react";
import { createRoot } from "react-dom/client";
import { ClerkProvider, useAuth, SignInButton, UserButton } from "@clerk/react";
import {
  ConvexReactClient,
  Authenticated,
  Unauthenticated,
  AuthLoading,
} from "convex/react";
import { ConvexProviderWithClerk } from "convex/react-clerk";
import { Workspace } from "./Workspace";
import { AccountWorkspace } from "./AccountWorkspace";
import { Landing } from "./Landing";
import "./style.css";

const url = import.meta.env.VITE_CONVEX_URL;
const key = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;
const client = url && key ? new ConvexReactClient(url) : undefined;
function App() {
  const [open, setOpen] = useState(false);
  if (!open) return <Landing onOpen={() => setOpen(true)} />;
  return (
    <>
      <nav className="workspace-nav" aria-label="Workspace navigation">
        <button onClick={() => setOpen(false)}>← Flow State</button>
        <span>Cloud workspace</span>
      </nav>
      {!client || !key ? (
        <Workspace configured={false} />
      ) : (
        <ClerkProvider publishableKey={key}>
          <ConvexProviderWithClerk client={client} useAuth={useAuth}>
            <AuthLoading>
              <p className="auth" role="status">
                Connecting to your workspace…
              </p>
            </AuthLoading>
            <Unauthenticated>
              <div className="auth">
                <SignInButton mode="modal" />
              </div>
              <Workspace configured={false} />
            </Unauthenticated>
            <Authenticated>
              <div className="auth">
                <UserButton />
              </div>
              <AccountWorkspace />
            </Authenticated>
          </ConvexProviderWithClerk>
        </ClerkProvider>
      )}
    </>
  );
}
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
