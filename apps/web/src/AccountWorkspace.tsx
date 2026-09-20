import { useState } from "react";
import { useMutation, useQuery } from "convex/react";
import { makeFunctionReference } from "convex/server";
import { LiveWorkspace } from "./LiveWorkspace";
import { MemoryPanel, type Preference } from "./MemoryPanel";
import { PrivacyPanel } from "./PrivacyPanel";
const listPreferences = makeFunctionReference<
  "query",
  Record<string, never>,
  Preference[]
>("preferences:list");
const savePreference = makeFunctionReference<
  "mutation",
  { key: string; valueJson: string },
  unknown
>("preferences:set");
const removePreference = makeFunctionReference<
  "mutation",
  { key: string },
  unknown
>("preferences:remove");
type Device = {
  id: string;
  deviceId: string;
  name: string | null;
  active: boolean;
  revokedAt: number | null;
};
const listDevices = makeFunctionReference<
  "query",
  Record<string, never>,
  Device[]
>("devices:list");
const revokeDevice = makeFunctionReference<
  "mutation",
  { deviceId: string },
  unknown
>("devices:revoke");
type Grant = {
  id: string;
  capability: string;
  target: string | null;
  expiresAt: number;
  active: boolean;
};
const listGrants = makeFunctionReference<
  "query",
  { deviceId: string },
  Grant[]
>("grants:list");
const revokeGrant = makeFunctionReference<
  "mutation",
  { grantId: string },
  unknown
>("grants:revoke");
function CloudMemory() {
  const items = useQuery(listPreferences, {});
  const save = useMutation(savePreference);
  const remove = useMutation(removePreference);
  if (!items) return <p role="status">Loading preferences…</p>;
  return (
    <MemoryPanel
      items={items}
      onSave={(key, value) => save({ key, valueJson: JSON.stringify(value) })}
      onRemove={(key) => remove({ key })}
    />
  );
}
function Permissions() {
  const devices = useQuery(listDevices, {});
  const revoke = useMutation(revokeDevice);
  const revokePermission = useMutation(revokeGrant);
  const [selected, setSelected] = useState("");
  const [pending, setPending] = useState<Device>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const grants = useQuery(
    listGrants,
    selected ? { deviceId: selected } : "skip",
  );
  async function perform(action: () => Promise<unknown>) {
    setBusy(true);
    setError("");
    try {
      await action();
      setPending(undefined);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Request failed");
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="settings-content">
      <div className="settings-heading">
        <div>
          <h1>Permissions</h1>
          <p>
            Your devices. Your boundaries.
            <br />
            你的裝置、你的控制範圍。
          </p>
        </div>
      </div>
      <p className="notice">
        Cloud permissions do not grant access to your Mac. Microphone, screen
        and input permissions are managed separately in the Mac app and System
        Settings.
      </p>
      <h2>Connected devices / 已連結裝置</h2>
      {!devices && <p role="status">Loading devices…</p>}
      {devices?.length === 0 && <p>No registered devices yet.</p>}
      {devices?.map((device) => (
        <div key={device.id} className="device-row">
          <div>
            <strong>{device.name ?? "Unnamed device"}</strong>
            <p className="small-muted">
              {device.active ? "Active / 使用中" : "Revoked / 已撤銷"}
            </p>
          </div>
          <div className="row-actions">
            <button onClick={() => setSelected(device.deviceId)}>
              View grants / 查看授權
            </button>
            <button
              disabled={!device.active || busy}
              aria-label={"Revoke " + (device.name ?? "Unnamed device")}
              onClick={() => setPending(device)}
            >
              Revoke / 撤銷
            </button>
          </div>
        </div>
      ))}
      {pending && (
        <div className="notice">
          <p>
            Revoke {pending.name ?? "this device"}? Future cloud operations from
            it will be blocked. This does not remotely stop local Mac actions.
          </p>
          <button
            disabled={busy}
            onClick={() =>
              void perform(() => revoke({ deviceId: pending.deviceId }))
            }
          >
            Confirm revoke / 確認撤銷
          </button>
          <button disabled={busy} onClick={() => setPending(undefined)}>
            Cancel / 取消
          </button>
        </div>
      )}
      {selected && (
        <section aria-label="Device grants">
          <h2>Grants / 授權</h2>
          {!grants && <p role="status">Loading grants…</p>}
          {grants?.length === 0 && <p>No cloud grants for this device.</p>}
          {grants?.map((grant) => (
            <div className="device-row" key={grant.id}>
              <div>
                <strong>{grant.capability}</strong>
                <p>{grant.target ?? "Account scope"}</p>
                <p className="small-muted">
                  Expires {new Date(grant.expiresAt).toLocaleString()}
                </p>
              </div>
              <button
                disabled={!grant.active || busy}
                onClick={() =>
                  void perform(() => revokePermission({ grantId: grant.id }))
                }
              >
                Revoke grant / 撤銷授權
              </button>
            </div>
          ))}
        </section>
      )}
      {error && <p role="alert">{error}</p>}
    </section>
  );
}
export function AccountWorkspace() {
  const [page, setPage] = useState<
    "research" | "memory" | "permissions" | "privacy"
  >("research");
  return (
    <div className="settings-shell">
      <nav className="settings-sidebar" aria-label="Account sections">
        <button
          aria-current={page === "research" ? "page" : undefined}
          onClick={() => setPage("research")}
        >
          Tasks & history / 工作紀錄
        </button>
        <button
          aria-current={page === "memory" ? "page" : undefined}
          onClick={() => setPage("memory")}
        >
          Memory / 記憶
        </button>
        <button
          aria-current={page === "permissions" ? "page" : undefined}
          onClick={() => setPage("permissions")}
        >
          Permissions / 權限
        </button>
        <button
          aria-current={page === "privacy" ? "page" : undefined}
          onClick={() => setPage("privacy")}
        >
          Privacy & usage / 隱私與用量
        </button>
      </nav>
      <div>
        {page === "research" ? (
          <LiveWorkspace />
        ) : page === "memory" ? (
          <CloudMemory />
        ) : page === "permissions" ? (
          <Permissions />
        ) : (
          <PrivacyPanel />
        )}
      </div>
    </div>
  );
}
