import { describe, expect, it } from "vitest";

import {
  createEmailActionFingerprint,
  validateApprovedEmail,
  validateAllowedRecipient,
} from "../../convex/lib/policy";

describe("email delivery policy", () => {
  const input = {
    recipient: "owner@example.com",
    subject: "Research preview",
    body: "A preview",
  };

  it("requires an exact allowlisted recipient", () => {
    expect(validateAllowedRecipient("owner@example.com", ["owner@example.com"])).toBe(
      "owner@example.com",
    );
    expect(() => validateAllowedRecipient("other@example.com", ["owner@example.com"])).toThrow(
      "allowlist",
    );
  });

  it("binds approval to exact content and expiry", () => {
    const now = 1_000;
    const fingerprint = createEmailActionFingerprint(input);
    expect(
      validateApprovedEmail({
        ...input,
        fingerprint,
        approvalStatus: "approved",
        expiresAt: now + 1_000,
        now,
        allowedRecipients: ["owner@example.com"],
      }),
    ).toEqual({ recipient: "owner@example.com", fingerprint });

    expect(() =>
      validateApprovedEmail({
        ...input,
        subject: "Changed after approval",
        fingerprint,
        approvalStatus: "approved",
        expiresAt: now + 1_000,
        now,
        allowedRecipients: ["owner@example.com"],
      }),
    ).toThrow("approval");
    expect(() =>
      validateApprovedEmail({
        ...input,
        fingerprint,
        approvalStatus: "approved",
        expiresAt: now,
        now,
        allowedRecipients: ["owner@example.com"],
      }),
    ).toThrow("expired");
  });
});
