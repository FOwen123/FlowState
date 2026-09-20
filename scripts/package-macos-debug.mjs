// Packages an already compiled test executable. Does not compile or publish a release.
import {
  access,
  cp,
  mkdir,
  readFile,
  readdir,
  writeFile,
} from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { parseEnv } from "node:util";
const directory = "apps/macos/.build/out/Products/Debug";
await access(`${directory}/FlowStateApp`);
const bundle = "apps/macos/.build/FlowState.app";
await mkdir(`${bundle}/Contents/MacOS`, { recursive: true });
await mkdir(`${bundle}/Contents/Resources`, { recursive: true });
await cp(`${directory}/FlowStateApp`, `${bundle}/Contents/MacOS/FlowStateApp`);
for (const name of await readdir(directory)) {
  if (name.endsWith(".bundle"))
    await cp(`${directory}/${name}`, `${bundle}/Contents/Resources/${name}`, {
      recursive: true,
    });
}
const info = JSON.parse(
  execFileSync(
    "plutil",
    ["-convert", "json", "-o", "-", "apps/macos/Info.plist"],
    { encoding: "utf8" },
  ),
);
Object.assign(info, {
  CFBundleExecutable: "FlowStateApp",
  CFBundleIdentifier: "com.flowstate.dev",
  CFBundleName: "Flow State",
  CFBundlePackageType: "APPL",
  CFBundleShortVersionString: "0.1.0",
  CFBundleVersion: "1",
  LSMinimumSystemVersion: "26.2",
  LSUIElement: true,
  CFBundleURLTypes: [{ CFBundleURLSchemes: ["com.flowstate.dev"] }],
});
// Read only public web configuration. Never copy .env.local or any provider credential.
try {
  const env = parseEnv(await readFile("apps/web/.env.local", "utf8"));
  info.FlowStateConvexURL = env.VITE_CONVEX_URL ?? "";
  info.FlowStateClerkPublishableKey = env.VITE_CLERK_PUBLISHABLE_KEY ?? "";
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
await writeFile(
  `${bundle}/Contents/Info.plist`,
  execFileSync("plutil", ["-convert", "xml1", "-o", "-", "--", "-"], {
    input: JSON.stringify(info),
  }),
);
const signingIdentity = process.env.FLOWSTATE_CODESIGN_IDENTITY?.trim() || "-";
execFileSync("codesign", ["--force", "--sign", signingIdentity, bundle], {
  stdio: "pipe",
});
console.log(
  `Packaged local debug app: ${bundle}. This is not a notarized release.`,
);
