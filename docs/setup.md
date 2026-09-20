# Development setup

This is a development implementation, not the complete FlowState release. Check [implementation status](testing/results.md) before assuming a planned feature works.

## Local checks without accounts

Use the versions pinned in package.json and the installed Swift toolchain:

```sh
pnpm install --frozen-lockfile
pnpm test
pnpm typecheck
pnpm test:native
pnpm exec playwright install chromium
pnpm test:browser
```

Browser tests mount a synthetic component without a development server and never send real email. Native tests do not capture the screen or request system permissions. Run the native app interactively only when ready to grant and test permissions; see apps/macos/README.md.

## Accounts to configure

Create separate development resources for Convex, Clerk, OpenAI, TypeSafe, Firecrawl and AgentMail. Clerk is currently wired into the web; native sign-in remains a separate feasibility gate. Activate the Convex integration in the Clerk dashboard and copy its issuer URL and publishable key. Provider secret keys belong on the Convex backend.

1. Copy `.env.example` to ignored `.env.local` as a private checklist if useful. This file is not automatically uploaded to Convex.
2. Sign into Convex locally and select/create the development deployment through its CLI setup when ready. That setup is a deployment operation; do not confuse it with the offline tests above.
3. Set backend environment values through the Convex deployment dashboard. Avoid passing secret values as shell arguments or pasting them into chat.
4. Copy `apps/web/.env.example` to `apps/web/.env.local`. Set only `VITE_CONVEX_URL` and `VITE_CLERK_PUBLISHABLE_KEY` there.
5. Configure Clerk's allowed local origin and production origin when known. Use the same Clerk instance for the configured Convex issuer.
6. Set an AgentMail test inbox and explicitly allowed test recipients. Confirm the sender identity and recipient before the first live test.
7. Select model IDs available to your accounts. The application must not silently assume a ChatGPT subscription grants OpenAI API billing.

Presence-only checks (never print secret values):

```sh
node --env-file=.env.local scripts/check-env.mjs backend
node --env-file=apps/web/.env.local scripts/check-env.mjs web
```

These checks do not authenticate API keys, provision accounts, configure a remote deployment, or establish spending limits. A successful mocked adapter test is not a live integration test.

## Live acceptance after configuration

- Sign in on the web and confirm an unauthenticated/second account cannot access the owner's runs.
- Request one approved public article; verify a real Firecrawl response, model-generated note and persisted Convex state.
- Review the exact recipient and content. Only with authorization, send to the test inbox and record provider acceptance separately from delivery.
- Repeat the send request and simulate a lost response; confirm the system does not blindly send a duplicate.
- Revoke credentials and confirm visible failures without credential leakage.
- Record the date, deployment, model versions, commands and outcomes in docs/testing/results.md without recording secrets.

Native signing, full speech control, and personal-mailbox integration have their own release gates. The web research path is not proof that the native voice controller is finished.

## Generated Convex types

`pnpm convex:codegen` requires a configured `CONVEX_DEPLOYMENT`. It currently stops before generation because no deployment is configured. The tests supply an in-memory root marker for convex-test; that is not generated production code. After configuration, generate and commit the actual Convex API/types and verify the deployment with the same tests.

## Limits before public release

Keep this foundation in a private development deployment. Usage quotas/spend controls, retention/deletion jobs, delivery webhook verification and reconciliation, native authentication, voice input and verified desktop execution remain open in PLAN.md. Account keys alone do not make the application ready for public users.

The web can cancel queued/running research and discard late results. It cannot retract an external provider request already in progress or recall email. For uncertain email acceptance, check the configured AgentMail inbox's sent records manually; automatic reconciliation/resume is not implemented, and blind retry stays disabled.
