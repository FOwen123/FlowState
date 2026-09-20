type AuthIdentity = {
  tokenIdentifier: string;
  subject?: string;
  issuer?: string;
  email?: string;
  name?: string;
};

type AuthContext = {
  auth: {
    getUserIdentity: () => Promise<AuthIdentity | null>;
  };
};

export async function requireIdentity(ctx: AuthContext): Promise<AuthIdentity> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null) {
    throw new Error("Unauthenticated FlowState request");
  }
  return identity;
}

export function allowedRecipientsFromEnv(): string[] {
  const raw = process.env.FLOWSTATE_ALLOWED_TEST_RECIPIENTS ?? "";
  return raw
    .split(",")
    .map((item) => item.trim().toLowerCase())
    .filter((item) => item.length > 0);
}
