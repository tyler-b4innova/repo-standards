#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. test/lib.sh
ENGINE=$PWD
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export CODEX_HOME=/nonexistent CLAUDE_CONFIG_DIR=/nonexistent
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME OP_CLI OP_VAULT OP_SERVICE_ACCOUNT_TOKEN
mkdir -p "$T/bin"
printf '#!/bin/sh\nshift\nexec node "$RELEASE_STUB" "$@"\n' > "$T/bin/npx"
chmod +x "$T/bin/npx"
export PATH="$T/bin:$PATH" RELEASE_STUB="$ENGINE/test/stubs/release-wrangler.mjs"
repo() {
  R=$T/$1
  git init -q -b main "$R"
  cp -R "test/fixtures/release-$2/." "$R/"
  node bin/repo-standards.mjs apply --target "$R" --overlay examples/overlay.json --version 0.7.2 >/dev/null
  mkdir -p "$R/node_modules/.bin"
  touch "$R/node_modules/.bin/wrangler"
  printf 'node_modules/\ndist/\n.wrangler/\n' >> "$R/.gitignore"
  git -C "$R" add -A && git -C "$R" commit -qm fixture
  export RELEASE_LOG=$T/$1.log
}
release() { (cd "$R" && node scripts/agent/release.mjs main) > "$T/out" 2>&1; }
proof() { node --input-type=module - "$RELEASE_LOG" "$1" <<'JS'
import { existsSync, readFileSync } from "node:fs";
import assert from "node:assert/strict";
const raw = existsSync(process.argv[2]) ? readFileSync(process.argv[2], "utf8").trim() : "";
const lines = raw ? raw.split("\n").map(JSON.parse) : [];
const kind = process.argv[3];
if (["astro", "migrations"].includes(kind)) {
  assert.deepEqual(lines.shift(), { build: null, name: "site" });
}
if (kind === "astro") {
  assert.equal(lines.length, 4);
  assert.deepEqual(lines[0], { build: "staging", name: "site-staging" });
  assert.equal(lines[1].args[0], "deploy");
  assert.equal(lines[1].name, "site-staging");
  assert.equal(lines[1].configName, "site-staging");
  assert.ok(!lines[1].args.includes("--config"));
  assert.deepEqual(lines[1].routes, []);
  assert.deepEqual(lines[2], { build: null, name: "site" });
  assert.deepEqual(lines[3].args.slice(0, 2), ["versions", "upload"]);
  assert.equal(lines[3].configName, "site");
  assert.equal(lines[3].env, null);
} else if (kind === "migrations") {
  assert.equal(lines.length, 5);
  assert.equal(lines[0].build, "staging");
  assert.deepEqual(lines[1].args.slice(0, 4), ["d1", "migrations", "apply", "DB"]);
  assert.ok(!lines[1].args.includes("--config"));
  assert.equal(lines[1].configName, "site-staging");
  assert.equal(lines[2].args[0], "deploy");
  assert.equal(lines[2].name, "site-staging");
  assert.equal(lines[3].build, null);
  assert.deepEqual(lines[4].args, ["versions", "upload"]);
} else if (["secondary", "secondary-alt"].includes(kind)) {
  const primaryName = kind === "secondary-alt" ? "connected-site" : "site";
  const calls = lines.filter((line) => line.args);
  const deploys = calls.filter((line) => line.args[0] === "deploy");
  assert.deepEqual(deploys.map((line) => line.name), ["site-staging", "runtime-staging"]);
  assert.equal(deploys[1].configName, "runtime-staging");
  assert.ok(deploys[1].args.includes("--config"));
  const uploads = calls.filter((line) => line.args[0] === "versions");
  assert.deepEqual(uploads.map((line) => line.name), [primaryName, "runtime"]);
  assert.ok(uploads[1].args.includes("-c"));
  for (const call of calls) {
    const primaryUpload = call === uploads[0];
    assert.equal(call.overrideName, primaryUpload ? primaryName : null);
    assert.equal(call.matchTag, primaryUpload ? "primary-tag" : null);
  }
  assert.deepEqual(calls.filter((line) => line.args[0] === "secret").map((line) => line.name), ["site-staging", "runtime-staging", primaryName, "runtime"]);
  const builds = lines.filter((line) => "build" in line);
  assert.deepEqual(builds.map((line) => line.build), [null, "staging", null]);
  for (const build of builds) { assert.equal(build.overrideName, null); assert.equal(build.matchTag, null); }
} else if (kind === "legacy") {
  const calls = lines.filter((line) => line.args);
  assert.deepEqual(calls.filter((line) => line.args[0] === "deploy").map((line) => line.name), ["runtime-staging"]);
  assert.deepEqual(calls.filter((line) => line.args[0] === "preview").map((line) => line.name), ["staging"]);
  assert.deepEqual(calls.filter((line) => line.args[0] === "versions").map((line) => line.name), ["site", "runtime"]);
  assert.deepEqual(lines.filter((line) => "build" in line).map((line) => line.build), [null, null]);
} else if (kind === "secret-failure") {
  assert.ok(lines.some((line) => line.args?.[0] === "secret" && line.name === "runtime-staging"));
  assert.ok(lines.every((line) => line.args?.[0] !== "versions"));
} else if (kind === "abort") {
  assert.ok(lines.every((line) => !line.args), "no Wrangler command before guard passes");
} else if (kind === "output") {
  assert.equal(lines.filter((line) => line.args).length, 1);
  assert.equal(lines.find((line) => line.args).args[0], "deploy");
} else {
  assert.equal(lines.length, 2);
  assert.equal(lines[0].args[0], "deploy");
  assert.equal(lines[0].name, "site-staging");
  assert.deepEqual(lines[0].routes, []);
  assert.deepEqual(lines[1].args, ["versions", "upload"]);
  assert.equal(lines[1].name, "site");
  assert.ok(lines[0].args.includes("--name"));
  assert.ok(lines[0].args.includes("--config"));
}
JS
}
repo astro astro
if CLOUDFLARE_ENV=accidental WRANGLER_CI_OVERRIDE_NAME=site release && proof astro; then
  repo db astro
  mkdir -p "$R/migrations"
  node -e 'const fs=require("fs"),p=process.argv[1]+"/wrangler.jsonc",o=JSON.parse(fs.readFileSync(p));o.env.staging.d1_databases=[{binding:"DB",database_name:"site-db-staging",database_id:"d1-staging"}];fs.writeFileSync(p,JSON.stringify(o))' "$R"
  if release && proof migrations; then
    repo custom astro
    node -e 'const fs=require("fs"),p=process.argv[1]+"/standards.json",o=JSON.parse(fs.readFileSync(p));o.build="node build.mjs";fs.writeFileSync(p,JSON.stringify(o));fs.writeFileSync(process.argv[1]+"/package.json",JSON.stringify({type:"module"}))' "$R"
    if release && proof astro; then ok release-generated-builds; else fail release-generated-builds "standards build: $(cat "$T/out")"; fi
  else fail release-generated-builds "generated migrations: $(cat "$T/out")"; fi
else fail release-generated-builds "$(cat "$T/out")"; fi
repo bad astro
if IGNORE_SELECTION=1 release; then fail release-generated-guard "unsafe build passed";
elif grep -q 'unsafe staging target.*expected site-staging' "$T/out" && proof abort; then ok release-generated-guard; else fail release-generated-guard "$(cat "$T/out")"; fi
repo routes astro
if PRODUCTION_ROUTE=1 release; then fail release-production-route-guard "production route passed";
elif grep -q 'unsafe staging route/custom domain' "$T/out" && proof abort; then
  repo singular plain
  python3 - "$R/wrangler.jsonc" <<'PYTEST'
import sys
p=sys.argv[1]
s=open(p).read().replace('{\n', '{\n  "route": "site.example.com/*",\n', 1)
open(p,'w').write(s)
PYTEST
  if release; then fail release-production-route-guard "inherited singular route passed";
  elif grep -q 'unsafe staging route/custom domain' "$T/out" && proof abort; then ok release-production-route-guard;
  else fail release-production-route-guard "$(cat "$T/out")"; fi
else fail release-production-route-guard "$(cat "$T/out")"; fi
repo output astro
if WRONG_OUTPUT=1 release; then fail release-staging-output "wrong output passed";
elif grep -q 'staging deploy output did not confirm' "$T/out" && proof output; then ok release-staging-output; else fail release-staging-output "$(cat "$T/out")"; fi
repo plain plain
if release && proof plain; then ok release-plain-config; else fail release-plain-config "$(cat "$T/out")"; fi
repo check astro
(cd "$R" && node build.mjs)
if (cd "$R" && IGNORE_SELECTION=1 scripts/agent/setup.sh --check) > "$T/out" 2>&1; then fail release-generated-check "unsupported build passed";
elif grep -q 'generated Wrangler config.*unsafe staging target' "$T/out" && grep -q 'honor CLOUDFLARE_ENV=staging' "$T/out"; then
  if (cd "$R" && scripts/agent/setup.sh --check) > "$T/out" 2>&1; then
    # A fresh gate checkout has no redirect until its build entry point generates it.
    (cd "$R" && node -e 'require("fs").rmSync(".wrangler",{recursive:true})')
    if (cd "$R" && IGNORE_SELECTION=1 node scripts/agent/gate.mjs run build) > "$T/out" 2>&1; then fail release-generated-check "clean CI build passed unsupported selection";
    elif grep -q 'generated Wrangler config.*unsafe staging target' "$T/out" && (cd "$R" && node scripts/agent/gate.mjs run build) > "$T/out" 2>&1; then ok release-generated-check;
    else fail release-generated-check "CI build: $(cat "$T/out")"; fi
  else fail release-generated-check "supported build: $(cat "$T/out")"; fi
else fail release-generated-check "$(cat "$T/out")"; fi
export RELEASE_SECRET_LIST=$T/secret-list.json
printf '%s\n' '{"site-staging":["PRIMARY_KEY"],"site":["PRIMARY_KEY"],"connected-site":["PRIMARY_KEY"],"runtime-staging":["RUNTIME_KEY"],"runtime":["RUNTIME_KEY"]}' > "$RELEASE_SECRET_LIST"
repo secondary astro
cp -R test/fixtures/release-secondary/. "$R/"
node -e 'const fs=require("fs"),f=process.argv[1]+"/standards.json",o=JSON.parse(fs.readFileSync(f));o.release_workers=["workers/runtime/wrangler.jsonc"];o.secrets={required:["PRIMARY_KEY"],store:"1password"};fs.writeFileSync(f,JSON.stringify(o));const p=process.argv[1]+"/wrangler.jsonc",c=JSON.parse(fs.readFileSync(p));c.secrets={required:["PRIMARY_KEY"]};c.env.staging.secrets=c.secrets;fs.writeFileSync(p,JSON.stringify(c))' "$R"
why=""
if RECORD_BUILD_CI=1 WRANGLER_CI_OVERRIDE_NAME=site WRANGLER_CI_MATCH_TAG=primary-tag release && proof secondary; then
  git -C "$R" add -A && git -C "$R" commit -qm fixture
  (cd "$R" && scripts/agent/setup.sh --check) > "$T/out" 2>&1 || why="valid secondary check: $(cat "$T/out")"
  PRIMARY_CFG=$(cat "$R/wrangler.jsonc")
  for mode in name route collision primary-route resource reverse-service ci-collision; do
    printf '%s\n' "$PRIMARY_CFG" > "$R/wrangler.jsonc"
    node -e 'const fs=require("fs"),cfg=JSON.parse(fs.readFileSync("test/fixtures/release-secondary/workers/runtime/wrangler.jsonc")),p=process.argv[1]+"/wrangler.jsonc",primary=JSON.parse(fs.readFileSync(p)),mode=process.argv[2];
      if(mode==="name") cfg.env.staging.name="runtime";
      if(mode==="route") cfg.env.staging.routes=["site.example.com/private/*"];
      if(mode==="collision"){cfg.name="site-staging";cfg.env.staging.name="site-staging-staging";}
      if(mode==="primary-route"){cfg.routes=["runtime.example.com/*"];primary.env.staging.routes=["runtime.example.com/*"];}
      if(mode==="resource"){primary.kv_namespaces=[{binding:"KV",id:"kv-primary"}];primary.env.staging.kv_namespaces=[{binding:"KV",id:"kv-staging"}];primary.previews.kv_namespaces=primary.env.staging.kv_namespaces;cfg.env.staging.kv_namespaces=[{binding:"CROSS_KV",id:"kv-primary"}];}
      if(mode==="reverse-service") primary.env.staging.services=[{binding:"API",service:"runtime"}];
      fs.writeFileSync(p,JSON.stringify(primary));fs.writeFileSync(process.argv[1]+"/workers/runtime/wrangler.jsonc",JSON.stringify(cfg))' "$R" "$mode"
    : > "$RELEASE_LOG"
    override=site
    [ "$mode" != ci-collision ] || override=site-staging
    if WRANGLER_CI_OVERRIDE_NAME=$override WRANGLER_CI_MATCH_TAG=primary-tag release; then why="$why; unsafe secondary $mode passed";
    elif ! grep -Eq 'unsafe staging|names the production resource' "$T/out" || ! proof abort; then why="$why; $mode: $(cat "$T/out")"; fi
    if [ "$mode" != ci-collision ]; then
      git -C "$R" add -A && git -C "$R" commit -qm fixture
      if (cd "$R" && scripts/agent/setup.sh --check) > "$T/out" 2>&1; then why="$why; unsafe $mode passed --check";
      elif ! grep -Eq 'unsafe staging|names the production resource' "$T/out"; then why="$why; $mode check wrong error: $(cat "$T/out")"; fi
    fi
  done
  printf '%s\n' "$PRIMARY_CFG" > "$R/wrangler.jsonc"
  cp test/fixtures/release-secondary/workers/runtime/wrangler.jsonc "$R/workers/runtime/wrangler.jsonc"
  : > "$RELEASE_LOG"
  RECORD_BUILD_CI=1 WRANGLER_CI_OVERRIDE_NAME=connected-site WRANGLER_CI_MATCH_TAG=primary-tag release && proof secondary-alt || why="$why; primary override secret target: $(cat "$T/out")"
  # Listed secrets are independent of config requirements: remove one on deployed staging.
  printf '%s\n' '{"site-staging":["PRIMARY_KEY"],"site":["PRIMARY_KEY"],"runtime-staging":[],"runtime":["RUNTIME_KEY"]}' > "$RELEASE_SECRET_LIST"
  : > "$RELEASE_LOG"
  if release; then why="$why; missing secondary secret passed";
  elif ! grep -q 'missing required secret(s): RUNTIME_KEY' "$T/out" || ! proof secret-failure; then why="$why; missing secret wrong failure: $(cat "$T/out")"; fi
  printf '%s\n' '{"runtime-staging":["RUNTIME_KEY"],"runtime":["RUNTIME_KEY"]}' > "$RELEASE_SECRET_LIST"
  repo legacy-extra plain
  cp -R test/fixtures/release-secondary/. "$R/"
  node --input-type=module - "$R" <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
import { parse } from "./template/scripts/agent/staging.mjs";
const dir = process.argv[2], cfg = parse(readFileSync(`${dir}/wrangler.jsonc`, "utf8"));
delete cfg.env;
writeFileSync(`${dir}/wrangler.jsonc`, JSON.stringify(cfg));
const std = JSON.parse(readFileSync(`${dir}/standards.json`, "utf8"));
std.release_workers = ["workers/runtime/wrangler.jsonc"];
writeFileSync(`${dir}/standards.json`, JSON.stringify(std));
writeFileSync(`${dir}/package.json`, JSON.stringify({ scripts: { build: "node build.mjs" } }));
writeFileSync(`${dir}/build.mjs`, 'if(process.env.CLOUDFLARE_ENV) throw new Error("legacy primary has no staging environment"); (await import("node:fs")).appendFileSync(process.env.RELEASE_LOG,JSON.stringify({build:null})+"\\n");');
JS
  release && proof legacy || why="$why; legacy primary: $(cat "$T/out")"
else why="$(cat "$T/out")"; fi
if [ -z "$why" ]; then ok release-secondary-workers; else fail release-secondary-workers "$why"; fi
# Build-created dotenv files must not rename staging or secondary uploads, or inject account values.
repo dotenv astro
cp -R test/fixtures/release-secondary/. "$R/"
node -e 'const fs=require("fs"),f=process.argv[1]+"/standards.json",o=JSON.parse(fs.readFileSync(f));o.release_workers=["workers/runtime/wrangler.jsonc"];fs.writeFileSync(f,JSON.stringify(o));const p=process.argv[1]+"/wrangler.jsonc",c=JSON.parse(fs.readFileSync(p));c.compatibility_date="2025-01-01";fs.writeFileSync(p,JSON.stringify(c))' "$R"
printf '%s\n' '{"runtime-staging":["RUNTIME_KEY"],"runtime":["RUNTIME_KEY"]}' > "$RELEASE_SECRET_LIST"
if MALICIOUS_DOTENV=1 WRANGLER_CI_OVERRIDE_NAME=site WRANGLER_CI_MATCH_TAG=primary-tag release; then
  node --input-type=module - "$RELEASE_LOG" <<'JS'
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
const calls = readFileSync(process.argv[2], "utf8").trim().split("\n").map(JSON.parse).filter((line) => line.args);
assert.deepEqual(calls.filter((line) => line.args[0] === "deploy").map((line) => line.name), ["site-staging", "runtime-staging"]);
assert.deepEqual(calls.filter((line) => line.args[0] === "versions").map((line) => line.name), ["site", "runtime"]);
for (const call of calls) { assert.equal(call.controlledEmpty, true); assert.equal(call.account, null); }
assert.equal(calls.find((line) => line.name === "runtime" && line.args[0] === "versions").matchTag, null);
JS
  if [ $? = 0 ]; then ok release-controlled-dotenv; else fail release-controlled-dotenv "dotenv contaminated release"; fi
else fail release-controlled-dotenv "$(cat "$T/out")"; fi
why=""
for kind in d1_databases:database_id kv_namespaces:id r2_buckets:bucket_name queues:queue queue_producer:queue workflows:name workflows:script_name services:service durable_objects:script_name malformed:queue; do
  repo "binding-${kind//[:.]/-}" astro
  cp -R test/fixtures/release-secondary/. "$R/"
  mkdir -p "$R/migrations"
  node --input-type=module - "$R" <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
const dir = process.argv[2], file = `${dir}/wrangler.jsonc`, cfg = JSON.parse(readFileSync(file, "utf8"));
cfg.d1_databases = [{ binding: "DB", database_name: "production-db", database_id: "production-database_id" }];
cfg.kv_namespaces = [{ binding: "KV", id: "production-id" }];
cfg.r2_buckets = [{ binding: "R2", bucket_name: "production-bucket_name" }];
cfg.queues = { producers: [{ binding: "Q", queue: "production-queue" }], consumers: [{ queue: "production-queue" }] };
cfg.workflows = [{ binding: "WF", name: "production-workflow", class_name: "Example" }];
cfg.env.staging.d1_databases = [{ binding: "DB", database_name: "staging-db", database_id: "staging-d1" }];
cfg.env.staging.kv_namespaces = [{ binding: "KV", id: "staging-kv" }];
cfg.env.staging.r2_buckets = [{ binding: "R2", bucket_name: "staging-r2" }];
cfg.env.staging.queues = { producers: [{ binding: "Q", queue: "staging-queue" }], consumers: [{ queue: "staging-queue" }] };
cfg.env.staging.workflows = [{ binding: "WF", name: "staging-workflow", class_name: "Example" }];
for (const key of ["d1_databases", "kv_namespaces", "r2_buckets", "workflows"]) cfg.previews[key] = cfg.env.staging[key];
cfg.previews.queues = { producers: cfg.env.staging.queues.producers };
writeFileSync(file, JSON.stringify(cfg));
const stdFile = `${dir}/standards.json`, std = JSON.parse(readFileSync(stdFile, "utf8"));
std.release_workers = ["workers/runtime/wrangler.jsonc"];
writeFileSync(stdFile, JSON.stringify(std));
JS
  if PRODUCTION_BINDING=$kind release; then why="$why; generated $kind passed";
  elif ! grep -Eq 'unsafe staging resources.*(production resource|production queue|cannot safely read)' "$T/out" || ! proof abort; then why="$why; $kind wrong failure: $(cat "$T/out")"; fi
  # --check uses the same resolved guard after the redirect exists.
  (cd "$R" && node build.mjs)
  if (cd "$R" && PRODUCTION_BINDING=$kind scripts/agent/setup.sh --check) > "$T/out" 2>&1; then why="$why; generated $kind passed --check";
  elif ! grep -q 'unsafe staging resources' "$T/out"; then why="$why; $kind check wrong failure: $(cat "$T/out")"; fi
done
if [ -z "$why" ]; then ok release-resolved-resource-guard; else fail release-resolved-resource-guard "$why"; fi
done_cases
