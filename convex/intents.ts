import {
  actionGeneric,
  FunctionReference,
  internalMutationGeneric,
  internalQueryGeneric,
  makeFunctionReference,
} from "convex/server";
import { v } from "convex/values";

import { requireIdentity } from "./lib/identity";
import {
  ACTION_KINDS,
  TOOL_KINDS,
  buildIntentQuestions,
  validateIntentRouteRequest,
  type IntentActionKind,
  type IntentRouteRequest,
} from "./lib/intent_contract";
import {
  DEFAULT_INTENT_POLICY,
  decideIntent,
  decideFallback,
  type IntentAnswer,
  type IntentDecision,
  type IntentGrant,
} from "./lib/intent_policy";
import { createTypeSafeClient } from "./lib/typesafe";
import { createOpenAIClient } from "./lib/openai";
import {
  buildIntentFallbackRequest,
  parseIntentFallbackOutput,
} from "./lib/intent_fallback";

type IntentRequestClaim =
  | { claim: true; requestId: string }
  | { claim: false; reason: "duplicate" | "stale" };

const internalClaimRequest = makeFunctionReference<
  "mutation",
  {
    ownerKey: string;
    deviceId: string;
    sessionId: string;
    utteranceId: string;
    contextRevision: number;
    fingerprint: string;
  },
  IntentRequestClaim
>("intents:claimRequest") as unknown as FunctionReference<
  "mutation",
  "internal",
  {
    ownerKey: string;
    deviceId: string;
    sessionId: string;
    utteranceId: string;
    contextRevision: number;
    fingerprint: string;
  },
  IntentRequestClaim
>;

const internalFinishRequest = makeFunctionReference<
  "mutation",
  {
    ownerKey: string;
    deviceId: string;
    sessionId: string;
    utteranceId: string;
    contextRevision: number;
    status: "requires_observation" | "completed" | "failed";
    decision: string;
    reason: string;
  },
  null
>("intents:finishRequest") as unknown as FunctionReference<
  "mutation",
  "internal",
  {
    ownerKey: string;
    deviceId: string;
    sessionId: string;
    utteranceId: string;
    contextRevision: number;
    status: "requires_observation" | "completed" | "failed";
    decision: string;
    reason: string;
  },
  null
>;

const internalGetGrants = makeFunctionReference<
  "query",
  { ownerKey: string; deviceId: string },
  IntentGrant[]
>("intents:getGrants") as unknown as FunctionReference<
  "query",
  "internal",
  { ownerKey: string; deviceId: string },
  IntentGrant[]
>;

const intentAction = v.union(
  ...ACTION_KINDS.map((kind) => v.literal(kind)),
) as ReturnType<typeof v.union>;

const intentTool = v.union(
  ...TOOL_KINDS.map((tool) => v.literal(tool)),
) as ReturnType<typeof v.union>;

const intentContext = v.object({
  focusedAppBundleIdentifier: v.optional(v.string()),
  focusedRole: v.optional(v.string()),
  editable: v.optional(v.boolean()),
  targetCandidates: v.array(
    v.object({
      id: v.string(),
      label: v.string(),
      normalizedNames: v.optional(v.array(v.string())),
      matchedAlias: v.optional(v.string()),
      bundleIdentifier: v.optional(v.string()),
      kind: v.union(
        v.literal("app"),
        v.literal("window"),
        v.literal("control"),
        v.literal("file"),
      ),
      isRunning: v.optional(v.boolean()),
      supportedActions: v.optional(v.array(intentAction)),
      integrations: v.optional(v.array(v.string())),
    }),
  ),
  recentInteraction: v.optional(v.string()),
});

const intentObservation = v.object({
  id: v.string(),
  displayId: v.string(),
  windowId: v.string(),
  observedAt: v.number(),
  geometry: v.object({
    x: v.number(),
    y: v.number(),
    width: v.number(),
    height: v.number(),
    scale: v.number(),
  }),
  imageDataUrl: v.optional(v.string()),
});

function requestId(request: IntentRouteRequest): string {
  return `${request.sessionId}:${request.utteranceId}:${request.contextRevision}`;
}

function visualReference(utterance: string): boolean {
  return /\b(?:that|this|visible|shown|highlighted|button|box|icon|screenshot|click)\b/i.test(
    utterance,
  );
}

function targetedGrant(
  grants: IntentGrant[],
  capability: string,
  target: string | undefined,
): boolean {
  return (
    target !== undefined &&
    grants.some(
      (grant) =>
        grant.capability === capability &&
        grant.target === target &&
        grant.revokedAt === undefined &&
        grant.expiresAt > Date.now(),
    )
  );
}

function answerMap(
  answers: Record<
    string,
    {
      choice: string;
      confidence: number;
      selectedProbability: number;
      topTwoMargin: number;
    }
  >,
): Record<string, IntentAnswer> {
  return Object.fromEntries(
    Object.entries(answers).map(([key, answer]) => [
      key,
      {
        choice: answer.choice,
        confidence: answer.confidence,
        selectedProbability: answer.selectedProbability,
        topTwoMargin: answer.topTwoMargin,
      },
    ]),
  );
}

function emptyDecision(reason: string): IntentDecision {
  return {
    decision: "abstain",
    reason,
    intent: null,
    action: null,
    clarification: null,
    confidence: {
      intent: null,
      app: null,
      action: null,
      tool: null,
      target: null,
      requiredSlots: null,
      risk: null,
      clarification: null,
    },
  };
}

function publicResponse(input: {
  request: IntentRouteRequest;
  decision: IntentDecision;
  requestId: string;
  startedAt: number;
  model?: string;
  fallbackModel?: string;
  usage?: Record<string, number>;
  requiresObservation?: boolean;
  textFallbackUsed?: boolean;
  visionFallbackUsed?: boolean;
}) {
  const confidence = input.decision.confidence;
  const margins = [
    confidence.intent?.topTwoMargin,
    confidence.action?.topTwoMargin,
    confidence.target?.topTwoMargin,
  ].filter((value): value is number => value !== undefined);
  const usage =
    input.usage === undefined
      ? null
      : {
          inputTokens: input.usage.input_tokens,
          outputTokens: input.usage.output_tokens,
          totalTokens:
            input.usage.total_tokens ??
            (input.usage.input_tokens !== undefined &&
            input.usage.output_tokens !== undefined
              ? input.usage.input_tokens + input.usage.output_tokens
              : undefined),
          estimatedCostUSD: input.usage.estimated_cost_usd,
        };
  return {
    requestId: input.requestId,
    sessionId: input.request.sessionId,
    utteranceId: input.request.utteranceId,
    contextRevision: input.request.contextRevision,
    policyVersion: DEFAULT_INTENT_POLICY.version,
    decision: input.decision.decision,
    intent: input.decision.intent,
    action: input.decision.action,
    clarification: input.decision.clarification,
    requiresObservation: input.requiresObservation === true,
    textFallbackUsed: input.textFallbackUsed === true,
    visionFallbackUsed: input.visionFallbackUsed === true,
    confidence: {
      intent: confidence.intent?.confidence ?? 0,
      action: confidence.action?.confidence,
      target: confidence.target?.confidence,
      topTwoMargin: margins.length === 0 ? undefined : Math.min(...margins),
    },
    model: {
      jev: input.model ?? "unavailable",
      fallback: input.fallbackModel ?? null,
    },
    usage,
    latencyMs: Math.max(0, Date.now() - input.startedAt),
  };
}

export const route = actionGeneric({
  args: {
    deviceId: v.string(),
    sessionId: v.string(),
    utteranceId: v.string(),
    contextRevision: v.number(),
    utterance: v.string(),
    mode: v.union(
      v.literal("auto"),
      v.literal("commands"),
      v.literal("control"),
    ),
    context: intentContext,
    supportedActions: v.array(intentAction),
    supportedTools: v.array(intentTool),
    supportedCapabilities: v.array(v.string()),
    policyVersion: v.string(),
    observation: v.optional(intentObservation),
  },
  handler: async (ctx, args) => {
    const startedAt = Date.now();
    const identity = await requireIdentity(ctx);
    const request = validateIntentRouteRequest(args);
    if (request.policyVersion !== DEFAULT_INTENT_POLICY.version) {
      throw new Error("intent policy version is not supported");
    }
    const {
      contextRevision: _revision,
      observation: _observation,
      ...stablePayload
    } = request;
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(JSON.stringify(stablePayload)),
    );
    const fingerprint = Array.from(new Uint8Array(digest), (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("");
    const claim = await ctx.runMutation(internalClaimRequest, {
      ownerKey: identity.tokenIdentifier,
      deviceId: request.deviceId,
      sessionId: request.sessionId,
      utteranceId: request.utteranceId,
      contextRevision: request.contextRevision,
      fingerprint,
    });
    if (!claim.claim) throw new Error(`intent request is ${claim.reason}`);
    const grants = await ctx.runQuery(internalGetGrants, {
      ownerKey: identity.tokenIdentifier,
      deviceId: request.deviceId,
    });
    const finish = async (
      decision: IntentDecision,
      status: "requires_observation" | "completed" | "failed" = "completed",
    ) => {
      await ctx.runMutation(internalFinishRequest, {
        ownerKey: identity.tokenIdentifier,
        deviceId: request.deviceId,
        sessionId: request.sessionId,
        utteranceId: request.utteranceId,
        contextRevision: request.contextRevision,
        status,
        decision: decision.decision,
        reason: decision.reason,
      });
      return decision;
    };

    if (process.env.FLOWSTATE_JEV_MODEL !== "jev-1.13.0") {
      const decision = await finish(
        emptyDecision("model_not_evaluated"),
        "failed",
      );
      return publicResponse({
        request,
        decision,
        requestId: claim.requestId,
        startedAt,
      });
    }
    if (process.env.TYPESAFE_API_KEY === undefined) {
      const decision = await finish(
        emptyDecision("provider_unavailable"),
        "failed",
      );
      return publicResponse({
        request,
        decision,
        requestId: claim.requestId,
        startedAt,
      });
    }

    try {
      const questions = buildIntentQuestions(request);
      const strictQuestions = Object.fromEntries(
        Object.entries(questions).map(([key, question]) => [
          key,
          { choices: question.choices },
        ]),
      );
      const providerQuestions = Object.fromEntries(
        Object.entries(questions).map(([key, question]) => [
          key,
          {
            type: "choice" as const,
            instructions: question.instructions,
            criteria: question.criteria,
          },
        ]),
      );
      const client = createTypeSafeClient({
        apiKey: process.env.TYPESAFE_API_KEY,
        model: process.env.FLOWSTATE_JEV_MODEL,
      });
      const response = await client.systemOneStrict(
        {
          state: {
            utterance: request.utterance,
            mode: request.mode,
            context: request.context,
            supportedActions: request.supportedActions,
            supportedTools: request.supportedTools,
            supportedCapabilities: request.supportedCapabilities,
            policyVersion: request.policyVersion,
          },
          questions: providerQuestions,
        },
        strictQuestions,
      );
      if (response.model !== "jev-1.13.0")
        throw new Error("model_not_evaluated");
      let decision = decideIntent({
        request,
        answers: answerMap(response.answers),
        grants,
        policy: DEFAULT_INTENT_POLICY,
      });
      let requiresObservation = false;
      let textFallbackUsed = false;
      let visionFallbackUsed = false;
      let fallbackModel: string | undefined;
      let combinedUsage = response.usage;
      if (
        DEFAULT_INTENT_POLICY.status === "measured" &&
        decision.decision === "abstain" &&
        visualReference(request.utterance)
      ) {
        const observationTarget = request.context.focusedAppBundleIdentifier;
        const observationAllowed = targetedGrant(
          grants,
          "app.observe",
          observationTarget,
        );
        const uploadAllowed = targetedGrant(
          grants,
          "app.upload",
          observationTarget,
        );
        if (!observationAllowed || !uploadAllowed) {
          decision = {
            ...decision,
            decision: "clarify",
            reason: "observation_grant_missing",
            clarification:
              "Enable screen context in Settings and allow Screen Recording to use visual commands.",
          };
        } else if (request.observation?.imageDataUrl === undefined) {
          requiresObservation = true;
          decision = { ...decision, reason: "observation_required" };
        }
      }
      if (
        DEFAULT_INTENT_POLICY.status === "measured" &&
        decision.decision === "abstain" &&
        !requiresObservation
      ) {
        const vision = request.observation?.imageDataUrl !== undefined;
        if (vision) {
          const target = request.context.focusedAppBundleIdentifier;
          if (
            !targetedGrant(grants, "app.observe", target) ||
            !targetedGrant(grants, "app.upload", target)
          ) {
            decision = {
              ...decision,
              decision: "clarify",
              reason: "observation_grant_missing",
              clarification:
                "Enable screen context in Settings and allow Screen Recording to use visual commands.",
            };
          }
        }
        if (decision.decision === "abstain") {
          const openai = createOpenAIClient({
            apiKey: process.env.OPENAI_API_KEY,
            model: process.env.FLOWSTATE_PLANNER_MODEL,
          });
          const fallbackResponse = await openai.createResponse({
            ...buildIntentFallbackRequest({
              utterance: request.utterance,
              context: request.context,
              ...(vision && request.observation?.imageDataUrl !== undefined
                ? { imageDataUrl: request.observation.imageDataUrl }
                : {}),
            }),
            maxOutputTokens: 1024,
          });
          // Only report complete cascade totals; a Jev-only cost is not the full cost.
          combinedUsage = Object.fromEntries(
            [
              "input_tokens",
              "output_tokens",
              "total_tokens",
              "estimated_cost_usd",
            ].flatMap((key) => {
              const jev = response.usage?.[key];
              const fallback = fallbackResponse.usage?.[key];
              return jev === undefined || fallback === undefined
                ? []
                : [[key, jev + fallback]];
            }),
          );
          const fallback = parseIntentFallbackOutput(
            fallbackResponse.outputText,
          );
          decision = decideFallback({
            request,
            // Legacy fallback rows may contain dictation, but a Mac Control
            // request must route that boundary to the separate shortcut.
            intent: fallback.intent === "dictation" ? "unsupported" : fallback.intent,
            actionKind: fallback.actionKind,
            targetId: fallback.targetId,
            parameters: fallback.parameters,
            grants,
          });
          fallbackModel = process.env.FLOWSTATE_PLANNER_MODEL;
          visionFallbackUsed = vision;
          textFallbackUsed = !vision;
        }
      }
      const finished = await finish(
        decision,
        requiresObservation ? "requires_observation" : "completed",
      );
      return publicResponse({
        request,
        decision: finished,
        requestId: claim.requestId,
        startedAt,
        model: response.model,
        fallbackModel,
        usage: combinedUsage,
        requiresObservation,
        textFallbackUsed,
        visionFallbackUsed,
      });
    } catch (error) {
      const decision = await finish(
        emptyDecision("provider_invalid_or_unavailable"),
        "failed",
      );
      return publicResponse({
        request,
        decision,
        requestId: claim.requestId,
        startedAt,
      });
    }
  },
});

export const claimRequest = internalMutationGeneric({
  args: {
    ownerKey: v.string(),
    deviceId: v.string(),
    sessionId: v.string(),
    utteranceId: v.string(),
    contextRevision: v.number(),
    fingerprint: v.string(),
  },
  handler: async (ctx, args): Promise<IntentRequestClaim> => {
    const device = await ctx.db
      .query("devices")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", args.ownerKey))
      .filter((q) => q.eq(q.field("deviceId"), args.deviceId))
      .first();
    if (device === null || device.revokedAt !== undefined)
      throw new Error("device is not active");
    const rows = await ctx.db
      .query("intentRequests")
      .withIndex("by_owner_session_utterance", (q) =>
        q.eq("ownerKey", args.ownerKey),
      )
      .filter((q) =>
        q.and(
          q.eq(q.field("deviceId"), args.deviceId),
          q.eq(q.field("sessionId"), args.sessionId),
          q.eq(q.field("utteranceId"), args.utteranceId),
        ),
      )
      .collect();
    const previous = rows.sort(
      (a, b) => b.contextRevision - a.contextRevision,
    )[0];
    if (previous !== undefined) {
      if (args.contextRevision <= previous.contextRevision) {
        return {
          claim: false,
          reason:
            args.contextRevision === previous.contextRevision
              ? "duplicate"
              : "stale",
        };
      }
      if (
        previous.fingerprint !== args.fingerprint ||
        previous.status !== "requires_observation" ||
        args.contextRevision !== previous.contextRevision + 1
      ) {
        return { claim: false, reason: "stale" };
      }
      await ctx.db.patch(previous._id, {
        contextRevision: args.contextRevision,
        status: "processing",
        decision: undefined,
        reason: undefined,
        updatedAt: Date.now(),
      });
      return {
        claim: true,
        requestId: `${args.sessionId}:${args.utteranceId}:${args.contextRevision}`,
      };
    }
    await ctx.db.insert("intentRequests", {
      ownerKey: args.ownerKey,
      deviceId: args.deviceId,
      sessionId: args.sessionId,
      utteranceId: args.utteranceId,
      contextRevision: args.contextRevision,
      status: "processing",
      fingerprint: args.fingerprint,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });
    return {
      claim: true,
      requestId: `${args.sessionId}:${args.utteranceId}:${args.contextRevision}`,
    };
  },
});

export const finishRequest = internalMutationGeneric({
  args: {
    ownerKey: v.string(),
    deviceId: v.string(),
    sessionId: v.string(),
    utteranceId: v.string(),
    contextRevision: v.number(),
    status: v.union(
      v.literal("requires_observation"),
      v.literal("completed"),
      v.literal("failed"),
    ),
    decision: v.string(),
    reason: v.string(),
  },
  handler: async (ctx, args) => {
    const row = await ctx.db
      .query("intentRequests")
      .withIndex("by_owner_session_utterance", (q) =>
        q.eq("ownerKey", args.ownerKey),
      )
      .filter((q) =>
        q.and(
          q.eq(q.field("deviceId"), args.deviceId),
          q.eq(q.field("sessionId"), args.sessionId),
          q.eq(q.field("utteranceId"), args.utteranceId),
        ),
      )
      .filter((q) => q.eq(q.field("contextRevision"), args.contextRevision))
      .first();
    if (row !== null && row.status === "processing") {
      await ctx.db.patch(row._id, {
        status: args.status,
        decision: args.decision,
        reason: args.reason,
        updatedAt: Date.now(),
      });
    }
    return null;
  },
});

export const getGrants = internalQueryGeneric({
  args: { ownerKey: v.string(), deviceId: v.string() },
  handler: async (ctx, args): Promise<IntentGrant[]> => {
    const rows = await ctx.db
      .query("grants")
      .withIndex("by_owner_device", (q) => q.eq("ownerKey", args.ownerKey))
      .filter((q) => q.eq(q.field("deviceId"), args.deviceId))
      .collect();
    return rows.map((row) => ({
      capability: row.capability,
      ...(row.target === undefined ? {} : { target: row.target }),
      expiresAt: row.expiresAt,
      ...(row.revokedAt === undefined ? {} : { revokedAt: row.revokedAt }),
    }));
  },
});
