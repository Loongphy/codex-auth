#!/usr/bin/env node

const path = require("node:path");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const rootPackageJsonPath = path.join(__dirname, "..", "package.json");
const requiredNodeMajor = 22;

function ensureSupportedNodeVersion() {
  const major = Number(process.versions?.node?.split(".")[0] ?? 0);
  if (Number.isInteger(major) && major >= requiredNodeMajor) {
    return;
  }

  console.error(
    `Node.js ${requiredNodeMajor}+ is required to run @loongphy/codex-auth. Current version: ${process.version}.`
  );
  process.exit(1);
}

ensureSupportedNodeVersion();

const packageMap = {
  "linux:x64": "@loongphy/codex-auth-linux-x64",
  "linux:arm64": "@loongphy/codex-auth-linux-arm64",
  "darwin:x64": "@loongphy/codex-auth-darwin-x64",
  "darwin:arm64": "@loongphy/codex-auth-darwin-arm64",
  "win32:x64": "@loongphy/codex-auth-win32-x64",
  "win32:arm64": "@loongphy/codex-auth-win32-arm64"
};

function readRootPackage() {
  try {
    return JSON.parse(fs.readFileSync(rootPackageJsonPath, "utf8"));
  } catch {
    return null;
  }
}

function maybePrintPreviewVersion(argv) {
  if (argv.length !== 1) return false;
  if (argv[0] !== "--version" && argv[0] !== "-V") return false;

  const rootPackage = readRootPackage();
  if (!rootPackage) return false;

  const previewLabel = rootPackage.codexAuthPreviewLabel;
  if (typeof previewLabel !== "string" || previewLabel.length === 0) return false;
  if (typeof rootPackage.version !== "string" || rootPackage.version.length === 0) return false;

  process.stdout.write(`codex-auth ${rootPackage.version} (preview ${previewLabel})\n`);
  return true;
}

if (maybePrintPreviewVersion(process.argv.slice(2))) {
  process.exit(0);
}

function resolveBinary() {
  const key = `${process.platform}:${process.arch}`;
  const packageName = packageMap[key];
  if (!packageName) {
    console.error(`Unsupported platform: ${process.platform}/${process.arch}`);
    process.exit(1);
  }

  try {
    const packageRoot = path.dirname(require.resolve(`${packageName}/package.json`));
    const binaryName = process.platform === "win32" ? "codex-auth.exe" : "codex-auth";
    const binaryPath = path.join(packageRoot, "bin", binaryName);
    if (!fs.existsSync(binaryPath)) {
      console.error(`Missing binary inside ${packageName}: ${binaryPath}`);
      process.exit(1);
    }
    return binaryPath;
  } catch (error) {
    console.error(
      `Missing platform package ${packageName}. Reinstall @loongphy/codex-auth on ${process.platform}/${process.arch}.`
    );
    if (error && error.message) {
      console.error(error.message);
    }
    process.exit(1);
  }
}

const binaryPath = resolveBinary();
const child = spawnSync(binaryPath, process.argv.slice(2), {
  stdio: "inherit",
  env: {
    ...process.env,
    CODEX_AUTH_NODE_EXECUTABLE: process.execPath
  }
});

if (child.error) {
  console.error(child.error.message);
  process.exit(1);
}

if (child.signal) {
  process.kill(process.pid, child.signal);
} else {
  process.exit(child.status ?? 1);
}
