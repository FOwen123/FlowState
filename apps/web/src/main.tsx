import { StrictMode } from "react";
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
import { LiveWorkspace } from "./LiveWorkspace";
import "./style.css";

const url = import.meta.env.VITE_CONVEX_URL;
const key = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;
const root = createRoot(document.getElementById("root")!);
if (!url || !key) {
  root.render(
    <StrictMode>
      <Workspace configured={false} />
    </StrictMode>,
  );
} else {
  const client = new ConvexReactClient(url);
  root.render(
    <StrictMode>
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
            <LiveWorkspace />
          </Authenticated>
        </ConvexProviderWithClerk>
      </ClerkProvider>
    </StrictMode>,
  );
}
