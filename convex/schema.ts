import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const runStatus = v.union(
  v.literal("queued"),
  v.literal("running"),
  v.literal("awaiting_approval"),
  v.literal("approved"),
  v.literal("sending"),
  v.literal("completed"),
  v.literal("failed"),
  v.literal("cancelled"),
  v.literal("uncertain"),
);

const stepStatus = v.union(
  v.literal("pending"),
  v.literal("running"),
  v.literal("succeeded"),
  v.literal("failed"),
  v.literal("uncertain"),
);

export default defineSchema({
  users: defineTable({
    ownerKey: v.string(),
    email: v.optional(v.string()),
    name: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  }).index("by_owner_key", ["ownerKey"]),

  devices: defineTable({
    ownerKey: v.string(),
    deviceId: v.string(),
    name: v.optional(v.string()),
    createdAt: v.number(),
    lastSeenAt: v.number(),
  })
    .index("by_owner_device", ["ownerKey", "deviceId"])
    .index("by_device_id", ["deviceId"]),

  preferences: defineTable({
    ownerKey: v.string(),
    key: v.string(),
    valueJson: v.string(),
    updatedAt: v.number(),
  }).index("by_owner_key", ["ownerKey", "key"]),

  grants: defineTable({
    ownerKey: v.string(),
    deviceId: v.string(),
    capability: v.string(),
    target: v.optional(v.string()),
    expiresAt: v.number(),
    revokedAt: v.optional(v.number()),
    createdAt: v.number(),
  }).index("by_owner_device", ["ownerKey", "deviceId"]),

  workflowRuns: defineTable({
    ownerKey: v.string(),
    deviceId: v.string(),
    kind: v.string(),
    query: v.string(),
    sourceUrl: v.optional(v.string()),
    status: runStatus,
    previewTitle: v.optional(v.string()),
    previewBody: v.optional(v.string()),
    previewJson: v.optional(v.string()),
    errorCode: v.optional(v.string()),
    cancellationGeneration: v.number(),
    currentStep: v.optional(v.number()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_owner", ["ownerKey", "updatedAt"]),

  workflowSteps: defineTable({
    ownerKey: v.string(),
    runId: v.id("workflowRuns"),
    ordinal: v.number(),
    kind: v.string(),
    status: stepStatus,
    inputJson: v.optional(v.string()),
    outputJson: v.optional(v.string()),
    externalAttemptId: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_run", ["runId", "ordinal"])
    .index("by_owner_run", ["ownerKey", "runId"]),

  approvals: defineTable({
    ownerKey: v.string(),
    runId: v.id("workflowRuns"),
    actionKind: v.string(),
    recipient: v.string(),
    subject: v.string(),
    body: v.string(),
    actionFingerprint: v.string(),
    status: v.union(
      v.literal("pending"),
      v.literal("approved"),
      v.literal("expired"),
      v.literal("used"),
      v.literal("rejected"),
    ),
    expiresAt: v.number(),
    approvedAt: v.optional(v.number()),
    createdAt: v.number(),
  })
    .index("by_run", ["runId", "createdAt"])
    .index("by_owner", ["ownerKey", "createdAt"]),

  deliveryAttempts: defineTable({
    ownerKey: v.string(),
    runId: v.id("workflowRuns"),
    approvalId: v.id("approvals"),
    provider: v.string(),
    idempotencyKey: v.string(),
    status: v.union(
      v.literal("pending"),
      v.literal("succeeded"),
      v.literal("failed"),
      v.literal("uncertain"),
    ),
    externalId: v.optional(v.string()),
    externalThreadId: v.optional(v.string()),
    errorCode: v.optional(v.string()),
    requestFingerprint: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_run", ["runId", "createdAt"])
    .index("by_idempotency", ["provider", "idempotencyKey"]),

  researchSources: defineTable({
    ownerKey: v.string(),
    runId: v.id("workflowRuns"),
    url: v.string(),
    title: v.optional(v.string()),
    description: v.optional(v.string()),
    markdown: v.optional(v.string()),
    selected: v.boolean(),
    createdAt: v.number(),
  }).index("by_run", ["runId", "createdAt"]),
});
