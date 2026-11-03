import fs from "node:fs";
import {
  normalizeTagVersion,
  platformPackages,
  readRootPackage,
  rootPackagePath,
  writeJson,
  zigVersionPath
} from "./metadata.mjs";

function fail(message) {
  console.error(message);
  process.exit(1);
}

const rawVersion = process.argv[2] ?? process.env.GITHUB_REF_NAME ?? "";
const version = normalizeTagVersion(rawVersion);
const numericIdentifier = "(?:0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*)";
const semverPattern = new RegExp(
  `^(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)(?:-${numericIdentifier}(?:\\.${numericIdentifier})*)?$`
);

if (!version || !semverPattern.test(version)) {
  fail(`Expected a semver version or v-prefixed tag, got '${rawVersion}'`);
}

const rootPackage = readRootPackage();
rootPackage.version = version;

const optionalDeps = rootPackage.optionalDependencies ?? {};
for (const pkg of platformPackages) {
  if (optionalDeps[pkg.packageName] != null) {
    optionalDeps[pkg.packageName] = version;
  }
}
writeJson(rootPackagePath, rootPackage);

const zigContents = fs.readFileSync(zigVersionPath, "utf8");
if (!/app_version\s*=\s*"[^"]+"/.test(zigContents)) {
  fail(`Unable to find app_version in ${zigVersionPath}`);
}
const updatedZigContents = zigContents.replace(
  /app_version\s*=\s*"[^"]+"/,
  `app_version = "${version}"`
);
if (updatedZigContents !== zigContents) {
  fs.writeFileSync(zigVersionPath, updatedZigContents);
}

console.log(`Set version to ${version}`);
