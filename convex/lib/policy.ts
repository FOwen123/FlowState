import { asBoundedText } from "./http";

export type EmailApprovalInput = {
  recipient: string;
  subject: string;
  body: string;
};

export type ApprovedEmailValidation = EmailApprovalInput & {
  fingerprint: string;
  approvalStatus: "pending" | "approved" | "expired" | "used" | "rejected";
  expiresAt: number;
  now: number;
  allowedRecipients: readonly string[];
};

export function normalizeRecipient(recipient: string): string {
  return asBoundedText(recipient, "recipient", 320).toLowerCase();
}

export function validateAllowedRecipient(
  recipient: string,
  allowedRecipients: readonly string[],
): string {
  const normalized = normalizeRecipient(recipient);
  const allowed = new Set(allowedRecipients.map(normalizeRecipient));
  if (!allowed.has(normalized)) {
    throw new Error("recipient is not on the configured allowlist");
  }
  return normalized;
}

function field(value: string): string {
  return `${value.length}:${value}`;
}

export function createEmailActionFingerprint(input: EmailApprovalInput): string {
  return [normalizeRecipient(input.recipient), input.subject, input.body].map(field).join("|");
}

export function validateApprovedEmail(input: ApprovedEmailValidation): {
  recipient: string;
  fingerprint: string;
} {
  if (input.approvalStatus !== "approved") {
    throw new Error("email approval is not approved");
  }
  if (input.expiresAt <= input.now) {
    throw new Error("email approval is expired");
  }
  const recipient = validateAllowedRecipient(input.recipient, input.allowedRecipients);
  const fingerprint = createEmailActionFingerprint({
    recipient,
    subject: input.subject,
    body: input.body,
  });
  if (fingerprint !== input.fingerprint) {
    throw new Error("email content no longer matches the approval");
  }
  return { recipient, fingerprint };
}
