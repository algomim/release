import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const EXPECTED_BASE_INSTRUCTIONS =
  "Follow the system and developer instructions supplied with each request. Use the tools provided by the client according to their schemas, and preserve user changes you did not make.";
const FORBIDDEN_METADATA =
  /openrouter|moonshot|kimi|provider|deployment|backend|kernel|hidden prompt|you are codex|coding agent/i;
const TEST_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CATALOG_PATH = resolve(TEST_ROOT, "codex", "algomim-models.json");
const LOCK_PATH = resolve(TEST_ROOT, "codex", "algomim-models.lock.json");
const PROFILE_PATH = resolve(TEST_ROOT, "codex", "algomim.config.toml");

const catalogSource = readFileSync(CATALOG_PATH, "utf8");
const catalog = JSON.parse(catalogSource);
const lock = JSON.parse(readFileSync(LOCK_PATH, "utf8"));
const profile = readFileSync(PROFILE_PATH, "utf8");
const catalogHash = createHash("sha256").update(catalogSource).digest("hex");

assert(lock.schemaVersion === 1, "catalog lock schema must be version 1");
assert(
  lock.generator === "@algomim/inference/codex-model-catalog",
  "catalog generator must be canonical",
);
assert(
  lock.generatorVersion === 1,
  "catalog generator version must be supported",
);
assert(
  lock.catalogSha256 === catalogHash,
  "catalog SHA-256 must match the generated lock",
);
assert(
  Array.isArray(catalog.models) && catalog.models.length === 1,
  "catalog must expose exactly one public model",
);
assert(
  catalog.models[0].slug === "algomim",
  "algomim must be the only public model",
);
assert(
  new Set(catalog.models.map((model) => model.slug)).size ===
    catalog.models.length,
  "model slugs must be unique",
);
assert(
  !FORBIDDEN_METADATA.test(catalogSource),
  "catalog must not contain private or conflicting identity metadata",
);
assert(
  /^service_tier = "default"$/m.test(profile),
  "Codex profile must pin the default service tier",
);
assert(
  /^web_search = "live"$/m.test(profile),
  "Codex profile must enable native web search",
);
assert(
  /^\[features\]\r?\npersonality = false$/m.test(profile),
  "Codex profile must disable unsupported personality injection",
);

for (const model of catalog.models) {
  assert(
    typeof model.slug === "string" && model.slug.length > 0,
    "model slug is required",
  );
  assert(
    typeof model.display_name === "string" && model.display_name.length > 0,
    "display name is required",
  );
  assert(
    typeof model.description === "string" && model.description.length > 0,
    "description is required",
  );
  assert(
    model.base_instructions === EXPECTED_BASE_INSTRUCTIONS,
    "base instructions must be neutral",
  );
  assert(
    Array.isArray(model.service_tiers) && model.service_tiers.length === 0,
    "service tiers must not be advertised",
  );
  assert(
    model.shell_type === "shell_command",
    "Codex shell contract must use shell_command",
  );
  assert(
    model.apply_patch_tool_type === "freeform",
    "Codex apply_patch must use the supported freeform contract",
  );
  assert(
    model.supports_reasoning_summaries === true &&
      model.default_reasoning_summary === "none",
    "reasoning summaries must be supported and disabled by default",
  );
  assert(
    model.supports_search_tool === true,
    "Codex catalog must advertise native web search",
  );
  assert(
    model.prefer_websockets === false,
    "Codex must use the supported HTTP/SSE transport",
  );
  assert(
    Number.isSafeInteger(model.context_window) && model.context_window > 0,
    "context window is invalid",
  );
  assert(
    model.context_window === model.max_context_window,
    "context windows must match",
  );
  assert(
    Array.isArray(model.supported_reasoning_levels) &&
      model.supported_reasoning_levels.length > 0,
    "reasoning levels are required",
  );
  assert(
    model.supported_reasoning_levels.some(
      (level) => level.effort === model.default_reasoning_level,
    ),
    "default reasoning level must be supported",
  );
}

process.stdout.write("[ok] Codex generated catalog contract passed.\n");

function assert(condition, message) {
  if (!condition) throw new Error(`Assertion failed: ${message}`);
}
