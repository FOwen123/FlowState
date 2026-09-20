/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as deliveries from "../deliveries.js";
import type * as devices from "../devices.js";
import type * as executions from "../executions.js";
import type * as grants from "../grants.js";
import type * as history from "../history.js";
import type * as http from "../http.js";
import type * as lib_action_plan from "../lib/action_plan.js";
import type * as lib_agentmail from "../lib/agentmail.js";
import type * as lib_firecrawl from "../lib/firecrawl.js";
import type * as lib_http from "../lib/http.js";
import type * as lib_identity from "../lib/identity.js";
import type * as lib_openai from "../lib/openai.js";
import type * as lib_policy from "../lib/policy.js";
import type * as lib_preferences from "../lib/preferences.js";
import type * as lib_typesafe from "../lib/typesafe.js";
import type * as plans from "../plans.js";
import type * as preferences from "../preferences.js";
import type * as retention from "../retention.js";
import type * as usage from "../usage.js";
import type * as workflows from "../workflows.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  deliveries: typeof deliveries;
  devices: typeof devices;
  executions: typeof executions;
  grants: typeof grants;
  history: typeof history;
  http: typeof http;
  "lib/action_plan": typeof lib_action_plan;
  "lib/agentmail": typeof lib_agentmail;
  "lib/firecrawl": typeof lib_firecrawl;
  "lib/http": typeof lib_http;
  "lib/identity": typeof lib_identity;
  "lib/openai": typeof lib_openai;
  "lib/policy": typeof lib_policy;
  "lib/preferences": typeof lib_preferences;
  "lib/typesafe": typeof lib_typesafe;
  plans: typeof plans;
  preferences: typeof preferences;
  retention: typeof retention;
  usage: typeof usage;
  workflows: typeof workflows;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
