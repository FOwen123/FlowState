import {
  asBoundedText,
  FetchImplementation,
  isRecord,
  readString,
  requestJson,
  requireApiKey,
} from "./http";

export type AgentMailSendInput = {
  inboxId: string;
  to: string[];
  subject: string;
  text: string;
  idempotencyKey: string;
};

export type AgentMailSendResult = {
  messageId: string;
  threadId: string;
};

type AgentMailClientOptions = {
  apiKey?: string;
  baseUrl?: string;
  fetch?: FetchImplementation;
};

function validateEmailAddress(value: string, field: string): string {
  const normalized = asBoundedText(value, field, 320);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)) {
    throw new Error(`${field} must be an email address`);
  }
  return normalized;
}

function parseSendResponse(value: unknown): AgentMailSendResult {
  if (!isRecord(value)) {
    throw new Error("AgentMail returned an invalid send response");
  }
  return {
    messageId: readString(value.message_id, "message_id"),
    threadId: readString(value.thread_id, "thread_id"),
  };
}

export function createAgentMailClient(options: AgentMailClientOptions) {
  const apiKey = requireApiKey(options.apiKey, "AgentMail");
  const baseUrl = (options.baseUrl ?? "https://api.agentmail.to").replace(/\/$/, "");
  const fetchImplementation = options.fetch ?? globalThis.fetch;

  return {
    async send(input: AgentMailSendInput): Promise<AgentMailSendResult> {
      const inboxId = asBoundedText(input.inboxId, "inboxId", 320);
      if (input.to.length === 0) {
        throw new Error("to must contain at least one recipient");
      }
      const recipients = input.to.map((recipient, index) =>
        validateEmailAddress(recipient, `to[${index}]`),
      );
      const subject = asBoundedText(input.subject, "subject", 998);
      const text = asBoundedText(input.text, "text", 100_000);
      const idempotencyKey = asBoundedText(input.idempotencyKey, "idempotency key", 256);
      if (!/^[A-Za-z0-9._~-]+$/.test(idempotencyKey)) {
        throw new Error("idempotency key contains unsupported characters");
      }
      const url = `${baseUrl}/v0/inboxes/${encodeURIComponent(inboxId)}/messages/send`;
      const response = await requestJson("agentmail", fetchImplementation, url, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
          "Idempotency-Key": idempotencyKey,
        },
        body: JSON.stringify({ to: recipients, subject, text }),
      });
      return parseSendResponse(response);
    },
  };
}
