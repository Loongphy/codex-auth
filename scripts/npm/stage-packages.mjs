import fs from "node:fs";
import path from "node:path";
import {
  copyFile,
  ensureDir,
  platformPackages,
  readRootPackage,
  rootBinPath,
  rootLicensePath,
  rootPackageName,
  rootPublishDirName,
  rootReadmePath,
  writeJson
} from "./metadata.mjs";

function parseArgs(argv) {
  const options = {
    artifactsDir: path.resolve("artifacts"),
    outputDir: path.resolve("dist", "npm")
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--artifacts-dir") {
      options.artifactsDir = path.resolve(argv[i + 1]);
      i += 1;
    } else if (arg === "--output-dir") {
      options.outputDir = path.resolve(argv[i + 1]);
      i += 1;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return options;
}

function writeRootPackage(outputDir, rootPackage) {
  const dir = path.join(outputDir, rootPublishDirName);
  ensureDir(path.join(dir, "bin"));
  copyFile(rootBinPath, path.join(dir, "bin", "codex-auth.js"), 0o755);
  copyFile(rootReadmePath, path.join(dir, "README.md"));
  copyFile(rootLicensePath, path.join(dir, "LICENSE"));
  writeJson(path.join(dir, "package.json"), rootPackage);
}

function writePlatformPackage(outputDir, rootPackage, platformPackage, sourceBinary) {
  const dir = path.join(outputDir, platformPackage.packageDirName);
  ensureDir(path.join(dir, "bin"));

  const manifest = {
    name: platformPackage.packageName,
    version: rootPackage.version,
    description: `${rootPackageName} binary for ${platformPackage.os} ${platformPackage.cpu}`,
    license: rootPackage.license,
    repository: rootPackage.repository,
    homepage: rootPackage.homepage,
    bugs: rootPackage.bugs,
    os: [platformPackage.os],
    cpu: [platformPackage.cpu],
    files: ["bin/", "LICENSE", "README.md"],
    publishConfig: {
      access: "public"
    }
  };

  const binaryFiles = platformPackage.binaryFiles ?? [platformPackage.binaryName];
  for (const binaryFile of binaryFiles) {
    const sourcePath = path.join(path.dirname(sourceBinary), binaryFile);
    copyFile(sourcePath, path.join(dir, "bin", binaryFile), platformPackage.os === "win32" ? undefined : 0o755);
  }
  copyFile(rootReadmePath, path.join(dir, "README.md"));
  copyFile(rootLicensePath, path.join(dir, "LICENSE"));
  writeJson(path.join(dir, "package.json"), manifest);
}

const options = parseArgs(process.argv.slice(2));
const rootPackage = readRootPackage();
fs.rmSync(options.outputDir, { recursive: true, force: true });
writeRootPackage(options.outputDir, rootPackage);

for (const pkg of platformPackages) {
  const sourceBinary = path.join(options.artifactsDir, pkg.id, "binary", pkg.binaryName);
  if (!fs.existsSync(sourceBinary)) {
    throw new Error(`Missing binary for ${pkg.id}: ${sourceBinary}`);
  }
  writePlatformPackage(options.outputDir, rootPackage, pkg, sourceBinary);
}

console.log(`Staged npm packages in ${options.outputDir}`);
