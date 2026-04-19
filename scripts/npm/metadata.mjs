import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export const repoRoot = path.resolve(__dirname, "..", "..");
export const rootPackageName = "@loongphy/codex-auth";
export const rootPublishDirName = "root";
export const rootPackagePath = path.join(repoRoot, "package.json");
export const rootReadmePath = path.join(repoRoot, "README.md");
export const rootLicensePath = path.join(repoRoot, "LICENSE");
export const rootBinPath = path.join(repoRoot, "bin", "codex-auth.js");
export const zigVersionPath = path.join(repoRoot, "src", "version.zig");

export const platformPackages = [
  {
    id: "linux-x64",
    packageName: "@loongphy/codex-auth-linux-x64",
    packageDirName: "codex-auth-linux-x64",
    os: "linux",
    cpu: "x64",
    binaryName: "codex-auth",
    binaryFiles: ["codex-auth"],
    archiveName: "codex-auth-Linux-X64.tar.gz",
    zigTarget: "x86_64-linux-gnu"
  },
  {
    id: "linux-arm64",
    packageName: "@loongphy/codex-auth-linux-arm64",
    packageDirName: "codex-auth-linux-arm64",
    os: "linux",
    cpu: "arm64",
    binaryName: "codex-auth",
    binaryFiles: ["codex-auth"],
    archiveName: "codex-auth-Linux-ARM64.tar.gz",
    zigTarget: "aarch64-linux-gnu"
  },
  {
    id: "darwin-x64",
    packageName: "@loongphy/codex-auth-darwin-x64",
    packageDirName: "codex-auth-darwin-x64",
    os: "darwin",
    cpu: "x64",
    binaryName: "codex-auth",
    binaryFiles: ["codex-auth"],
    archiveName: "codex-auth-macOS-X64.tar.gz",
    zigTarget: "x86_64-macos-none"
  },
  {
    id: "darwin-arm64",
    packageName: "@loongphy/codex-auth-darwin-arm64",
    packageDirName: "codex-auth-darwin-arm64",
    os: "darwin",
    cpu: "arm64",
    binaryName: "codex-auth",
    binaryFiles: ["codex-auth"],
    archiveName: "codex-auth-macOS-ARM64.tar.gz",
    zigTarget: "aarch64-macos-none"
  },
  {
    id: "win32-x64",
    packageName: "@loongphy/codex-auth-win32-x64",
    packageDirName: "codex-auth-win32-x64",
    os: "win32",
    cpu: "x64",
    binaryName: "codex-auth.exe",
    binaryFiles: ["codex-auth.exe", "codex-auth-auto.exe"],
    archiveName: "codex-auth-Windows-X64.zip",
    zigTarget: "x86_64-windows-gnu"
  },
  {
    id: "win32-arm64",
    packageName: "@loongphy/codex-auth-win32-arm64",
    packageDirName: "codex-auth-win32-arm64",
    os: "win32",
    cpu: "arm64",
    binaryName: "codex-auth.exe",
    binaryFiles: ["codex-auth.exe", "codex-auth-auto.exe"],
    archiveName: "codex-auth-Windows-ARM64.zip",
    zigTarget: "aarch64-windows-gnu"
  }
];

export function readRootPackage() {
  return JSON.parse(fs.readFileSync(rootPackagePath, "utf8"));
}

export function readZigVersion() {
  const contents = fs.readFileSync(zigVersionPath, "utf8");
  const match = contents.match(/app_version\s*=\s*"([^"]+)"/);
  if (!match) {
    throw new Error(`Unable to parse version from ${zigVersionPath}`);
  }
  return match[1];
}

export function normalizeTagVersion(tagName) {
  if (!tagName) return null;
  return tagName.startsWith("v") ? tagName.slice(1) : tagName;
}

export function isPrerelease(version) {
  return version.includes("-");
}

export function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

export function copyFile(srcPath, destPath, mode) {
  ensureDir(path.dirname(destPath));
  fs.copyFileSync(srcPath, destPath);
  if (mode !== undefined) {
    fs.chmodSync(destPath, mode);
  }
}

export function writeJson(filePath, value) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}
