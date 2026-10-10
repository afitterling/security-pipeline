#!/usr/bin/env node
// Inspect the cloned repo and write /work/out/plan.json: what to install/build/test/deploy.
// Precedence (lowest → highest): auto-detection < .security-pipeline.json in the repo
//                               < projects.yaml `commands:` (env COMMANDS_JSON).
// Output: { kind, install, build, test, deploy, profiles[], deployEnabled }
const fs = require("fs");
const path = require("path");

const SRC = process.env.SRC_DIR || "/work/src";
const OUT = process.env.OUT_DIR || "/work/out";
const STAGE = process.env.DEPLOY_STAGE || "dev";
const deployWanted = (process.env.DEPLOY_ENABLED || "true") === "true";

const has = (f) => fs.existsSync(path.join(SRC, f));
const glob = (ext) => fs.readdirSync(SRC).some((f) => f.endsWith(ext));
const readJson = (f) => {
  try { return JSON.parse(fs.readFileSync(path.join(SRC, f), "utf8")); } catch { return null; }
};

let plan = { kind: "unknown", install: "", build: "", test: "", deploy: "", profiles: [] };

// ---- package manager
let pm = "", run = "npm run";
if (has("pnpm-lock.yaml")) { pm = "corepack enable && pnpm install --frozen-lockfile"; run = "pnpm run"; }
else if (has("yarn.lock")) { pm = "corepack enable && yarn install --immutable"; run = "yarn run"; }
else if (has("package-lock.json")) { pm = "npm ci"; }
else if (has("package.json")) { pm = "npm install"; }

const pkg = readJson("package.json");
const scripts = (pkg && pkg.scripts) || {};
const script = (name) => (scripts[name] ? `${run} ${name}` : "");

// ---- kind
if (has("sst.config.ts")) {
  plan.kind = "sst";
  plan.install = pm;
  plan.build = script("build");
  plan.test = script("test");
  plan.deploy = `npx sst deploy --stage ${STAGE}`;
  const cfg = fs.readFileSync(path.join(SRC, "sst.config.ts"), "utf8");
  // profiles pinned in sst.config.ts get mapped onto the pod's IRSA identity at deploy time
  plan.profiles = [...cfg.matchAll(/profile\s*:\s*["'`]([^"'`]+)["'`]/g)].map((m) => m[1]);
} else if (pkg) {
  plan.kind = "node";
  plan.install = pm;
  plan.build = script("build");
  plan.test = script("test");
} else if (has("Package.swift") || glob(".xcodeproj") || glob(".xcworkspace")) {
  plan.kind = "swift"; // needs macOS; scan-only on Linux
} else if (has("pyproject.toml") || has("requirements.txt")) {
  plan.kind = "python";
  plan.install = has("requirements.txt")
    ? "python3 -m venv .venv && . .venv/bin/activate && pip install -q -r requirements.txt"
    : "python3 -m venv .venv && . .venv/bin/activate && pip install -q .";
  plan.test = has("tests") || has("test")
    ? ". .venv/bin/activate && pip install -q pytest && pytest -q"
    : "";
} else if (glob(".tf")) {
  plan.kind = "terraform";
  plan.test = "terraform init -backend=false -input=false && terraform validate";
}

// ---- repo-local override: .security-pipeline.json  {"kind": "...", "commands": {"deploy": "..."}}
const local = readJson(".security-pipeline.json");
if (local) {
  Object.assign(plan, local.commands || {});
  if (local.kind) plan.kind = local.kind;
}

// ---- projects.yaml override (commands: {install, build, test, deploy})
if (process.env.COMMANDS_JSON && process.env.COMMANDS_JSON !== "null") {
  try {
    const o = JSON.parse(process.env.COMMANDS_JSON);
    for (const k of ["install", "build", "test", "deploy"]) if (o[k] !== undefined) plan[k] = o[k];
  } catch (e) { console.error("bad COMMANDS_JSON:", e.message); process.exit(1); }
}

plan.deployEnabled = deployWanted && !!plan.deploy;
fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(path.join(OUT, "plan.json"), JSON.stringify(plan, null, 2));
fs.writeFileSync(path.join(OUT, "deploy-enabled.txt"), String(plan.deployEnabled));
console.log(JSON.stringify(plan, null, 2));
