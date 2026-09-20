import { describe, expect, it } from "vitest";
import { anyApi } from "convex/server";
import { convexTest } from "convex-test";

import schema from "../../convex/schema";

const modules = {
  ...import.meta.glob("../../convex/**/*.ts"),
  "../../convex/_generated/test-root.ts": async () => ({}),
};

const api = anyApi;
const ownerA = {
  tokenIdentifier: "automatic-owner-a",
  subject: "automatic-owner-a",
};
const ownerB = {
  tokenIdentifier: "automatic-owner-b",
  subject: "automatic-owner-b",
};
const maxGrantDuration = 30 * 24 * 60 * 60 * 1_000;
type ListedGrant = {
  id: string;
  capability: string;
  target: string | null;
  expiresAt: number;
  revokedAt: number | null;
  active: boolean;
};

describe("automatic app.open grants", () => {
  it("grants only app.open for each target and refreshes existing active rows", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    const deviceId = "automatic-open-device";
    const originalExpiry = Date.now() + 60_000;
    const refreshedExpiry = Date.now() + 120_000;

    await user.mutation(api.workflows.registerDevice, { deviceId });
    const existing = await user.mutation(api.grants.grant, {
      deviceId,
      capability: "app.open",
      target: "com.example.Reader",
      expiresAt: originalExpiry,
    });
    const result = await user.mutation(api.grants.grantApplicationOpenTargets, {
      deviceId,
      targets: ["com.example.Reader", "com.example.Writer"],
      expiresAt: refreshedExpiry,
    });

    expect(result).toMatchObject({ expiresAt: refreshedExpiry });
    expect(result.grantIds).toHaveLength(2);
    expect(result.grantIds[0]).toBe(existing.grantId);

    const grants = (await user.query(api.grants.list, {
      deviceId,
    })) as ListedGrant[];
    expect(grants).toHaveLength(2);
    expect(grants).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          capability: "app.open",
          target: "com.example.Reader",
          expiresAt: refreshedExpiry,
          active: true,
        }),
        expect.objectContaining({
          capability: "app.open",
          target: "com.example.Writer",
          expiresAt: refreshedExpiry,
          active: true,
        }),
      ]),
    );
  });

  it("rejects an unregistered, foreign, or revoked device", async () => {
    const t = convexTest(schema, modules);
    const owner = t.withIdentity(ownerA);
    const foreignOwner = t.withIdentity(ownerB);
    const deviceId = "automatic-auth-device";
    const args = {
      deviceId,
      targets: ["com.example.Reader"],
      expiresAt: Date.now() + 60_000,
    };

    await expect(
      owner.mutation(api.grants.grantApplicationOpenTargets, args),
    ).rejects.toThrow("device is not active");
    await owner.mutation(api.workflows.registerDevice, { deviceId });
    await expect(
      foreignOwner.mutation(api.grants.grantApplicationOpenTargets, args),
    ).rejects.toThrow("device is not active");
    await owner.mutation(api.devices.revoke, { deviceId });
    await expect(
      owner.mutation(api.grants.grantApplicationOpenTargets, args),
    ).rejects.toThrow("device is not active");
  });

  it("requires a nonempty unique target list capped at 100 apps", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    const deviceId = "automatic-validation-device";
    const base = {
      deviceId,
      expiresAt: Date.now() + 60_000,
    };

    await user.mutation(api.workflows.registerDevice, { deviceId });
    await expect(
      user.mutation(api.grants.grantApplicationOpenTargets, {
        ...base,
        targets: [],
      }),
    ).rejects.toThrow("at least one");
    await expect(
      user.mutation(api.grants.grantApplicationOpenTargets, {
        ...base,
        targets: ["com.example.Reader", "com.example.Reader"],
      }),
    ).rejects.toThrow("unique");
    await expect(
      user.mutation(api.grants.grantApplicationOpenTargets, {
        ...base,
        targets: Array.from(
          { length: 101 },
          (_, index) => `com.example.App${index}`,
        ),
      }),
    ).rejects.toThrow("100");
    await expect(
      user.mutation(api.grants.grantApplicationOpenTargets, {
        ...base,
        targets: ["   "],
      }),
    ).rejects.toThrow("grant target is invalid");
  });

  it("uses the existing 30-day expiry bounds", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    const deviceId = "automatic-expiry-device";
    const base = { deviceId, targets: ["com.example.Reader"] };

    await user.mutation(api.workflows.registerDevice, { deviceId });
    await expect(
      user.mutation(api.grants.grantApplicationOpenTargets, {
        ...base,
        expiresAt: Date.now(),
      }),
    ).rejects.toThrow("within 30 days");
    await expect(
      user.mutation(api.grants.grantApplicationOpenTargets, {
        ...base,
        expiresAt: Date.now() + maxGrantDuration + 1_000,
      }),
    ).rejects.toThrow("within 30 days");
  });

  it("does not create app.input grants or replace revoked app.open scope", async () => {
    const t = convexTest(schema, modules);
    const user = t.withIdentity(ownerA);
    const deviceId = "automatic-scope-device";
    const expiresAt = Date.now() + 60_000;

    await user.mutation(api.workflows.registerDevice, { deviceId });
    const inputGrant = await user.mutation(api.grants.grant, {
      deviceId,
      capability: "app.input",
      target: "com.example.Reader",
      expiresAt,
    });
    const openGrant = await user.mutation(api.grants.grant, {
      deviceId,
      capability: "app.open",
      target: "com.example.Reader",
      expiresAt,
    });
    await user.mutation(api.grants.revoke, { grantId: openGrant.grantId });

    await user.mutation(api.grants.grantApplicationOpenTargets, {
      deviceId,
      targets: ["com.example.Reader"],
      expiresAt,
    });

    const grants = (await user.query(api.grants.list, {
      deviceId,
    })) as ListedGrant[];
    expect(grants).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: String(inputGrant.grantId),
          capability: "app.input",
          revokedAt: null,
        }),
        expect.objectContaining({
          id: String(openGrant.grantId),
          capability: "app.open",
          revokedAt: expect.any(Number),
          active: false,
        }),
      ]),
    );
    expect(
      grants.filter((grant) => grant.capability === "app.input"),
    ).toHaveLength(1);
    expect(
      grants.filter((grant) => grant.capability === "app.open" && grant.active),
    ).toHaveLength(1);
  });
});
