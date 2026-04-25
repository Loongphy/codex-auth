import fs from "node:fs";
import path from "node:path";
import {
  platformPackages,
  readRootPackage,
  repoRoot,
  rootPackageName
} from "./metadata.mjs";

function fail(message) {
  console.error(message);
  process.exit(1);
}

function readText(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
}

function parseWorkflowMatrix(relativePath) {
  const entries = [];
  let current = null;

  for (const line of readText(relativePath).split(/\r?\n/)) {
    const idMatch = line.match(/^\s*-\s+id:\s+(\S+)\s*$/);
    if (idMatch) {
      current = { id: idMatch[1] };
      entries.push(current);
      continue;
    }

    if (!current) continue;
    const fieldMatch = line.match(/^\s*(zig_target|binary_name|archive_name):\s+(\S+)\s*$/);
    if (fieldMatch) {
      current[fieldMatch[1]] = fieldMatch[2];
    }
  }

  return entries;
}

function requireEqual(label, actual, expected) {
  if (actual !== expected) {
    fail(`${label}: expected ${expected}, got ${actual}`);
  }
}

function requireUnique(values, label) {
  const seen = new Set();
  for (const value of values) {
    if (seen.has(value)) fail(`Duplicate ${label}: ${value}`);
    seen.add(value);
  }
}

function expectedArchiveSuffix(pkg) {
  return pkg.os === "win32" ? ".zip" : ".tar.gz";
}

function checkPackageMetadata() {
  requireUnique(platformPackages.map((pkg) => pkg.id), "platform id");
  requireUnique(platformPackages.map((pkg) => pkg.packageName), "platform package name");
  requireUnique(platformPackages.map((pkg) => pkg.packageDirName), "platform package directory");
  requireUnique(platformPackages.map((pkg) => pkg.archiveName), "archive name");

  for (const pkg of platformPackages) {
    if (!pkg.packageName.startsWith(`${rootPackageName}-`)) {
      fail(`${pkg.id}: packageName must start with ${rootPackageName}-`);
    }
    if (!pkg.archiveName.endsWith(expectedArchiveSuffix(pkg))) {
      fail(`${pkg.id}: archiveName ${pkg.archiveName} must end with ${expectedArchiveSuffix(pkg)}`);
    }
    if (pkg.os === "win32") {
      requireEqual(`${pkg.id}.binaryName`, pkg.binaryName, "codex-auth.exe");
      if (!pkg.binaryFiles.includes("codex-auth.exe") || !pkg.binaryFiles.includes("codex-auth-auto.exe")) {
        fail(`${pkg.id}: Windows packages must include codex-auth.exe and codex-auth-auto.exe`);
      }
    } else {
      requireEqual(`${pkg.id}.binaryName`, pkg.binaryName, "codex-auth");
      requireEqual(`${pkg.id}.binaryFiles`, pkg.binaryFiles.join(","), "codex-auth");
    }
  }
}

function checkRootPackage() {
  const rootPackage = readRootPackage();
  const optionalDeps = rootPackage.optionalDependencies ?? {};

  for (const pkg of platformPackages) {
    if (optionalDeps[pkg.packageName] !== rootPackage.version) {
      fail(`${pkg.packageName}: optionalDependencies must use root package version ${rootPackage.version}`);
    }
  }

  for (const depName of Object.keys(optionalDeps)) {
    if (!platformPackages.some((pkg) => pkg.packageName === depName)) {
      fail(`Unexpected optional dependency ${depName}`);
    }
  }
}

function checkCliWrapperMap() {
  const wrapper = readText("bin/codex-auth.js");
  for (const pkg of platformPackages) {
    const expectedEntry = `"${pkg.os}:${pkg.cpu}": "${pkg.packageName}"`;
    if (!wrapper.includes(expectedEntry)) {
      fail(`bin/codex-auth.js missing packageMap entry ${expectedEntry}`);
    }
  }
}

function checkWorkflowMatrix(relativePath, options) {
  const matrix = parseWorkflowMatrix(relativePath);
  requireEqual(`${relativePath} matrix length`, String(matrix.length), String(platformPackages.length));

  const byId = new Map(matrix.map((entry) => [entry.id, entry]));
  for (const pkg of platformPackages) {
    const entry = byId.get(pkg.id);
    if (!entry) fail(`${relativePath}: missing matrix entry for ${pkg.id}`);
    requireEqual(`${relativePath} ${pkg.id}.zig_target`, entry.zig_target, pkg.zigTarget);
    requireEqual(`${relativePath} ${pkg.id}.binary_name`, entry.binary_name, pkg.binaryName);
    if (options.archive) {
      requireEqual(`${relativePath} ${pkg.id}.archive_name`, entry.archive_name, pkg.archiveName);
    }
  }
}

checkPackageMetadata();
checkRootPackage();
checkCliWrapperMap();
checkWorkflowMatrix(".github/workflows/release.yml", { archive: true });
checkWorkflowMatrix(".github/workflows/preview-release.yml", { archive: false });

console.log("Release metadata check passed");
