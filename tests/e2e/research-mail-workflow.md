# Research and reviewed email acceptance

Use the Convex development deployment and an explicitly approved test inbox/recipient. Keep credentials in ignored files and backend secrets. Browser login and CLI simulated identities are separate forms of evidence.

1. Sign in with the configured Clerk application; register a browser device. In a second signed-in account, verify the first account's runs, preferences and grants cannot be read or altered.
2. Request a public article or research topic. Verify Firecrawl returns sources, Jev selects only known candidates, and the summary retains source attribution. Repeat with Traditional Chinese output.
3. Cancel during research. Verify late provider responses cannot save a new preview or overwrite cancelled state.
4. Review sender, recipient, subject, body and any attachments. Edit any field and verify the previous approval is invalidated. Confirm once; distinguish provider acceptance from delivered status.
5. Retry the same operation ID and simulate a lost provider response using a fixture. Verify no second email. An uncertain result needs reconciliation, not blind resend.
6. Revoke the originating device before a pending step. Verify cloud work cannot continue using that device's authority.
7. Save/edit/delete an explicit memory preference; verify the other signed-in view updates. Deletion of workflow content must preserve any minimal duplicate-prevention record needed for an external effect.
8. Test rate limits, inaccessible source URLs, unavailable provider keys and an injection-bearing public-page fixture. Report failures without printing raw secrets or treating source text as instructions.

Live service checks use a small synthetic request, never a personal mailbox or private page. Automated tests and live observations are recorded separately in docs/testing/results.md.
