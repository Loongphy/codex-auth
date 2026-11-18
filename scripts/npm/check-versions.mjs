import {
  normalizeTagVersion,
  platformPackages,
  readRootPackage,
  readZigVersion,
  readZonVersion,
  rootPackageName
} from "./metadata.mjs";

function fail(message) {
  console.error(message);
  process.exit(1);
}

const rootPackage = readRootPackage();
const zigVersion = readZigVersion();

if (rootPackage.name !== rootPackageName) {
  fail(`Expected root package name ${rootPackageName}, got ${rootPackage.name}`);
}

if (rootPackage.version !== zigVersion) {
  fail(`package.json version ${rootPackage.version} does not match src/version.zig ${zigVersion}`);
}

const zonVersion = readZonVersion();
if (zonVersion !== rootPackage.version) {
  fail(`build.zig.zon version ${zonVersion} does not match root version ${rootPackage.version}`);
}

const optionalDeps = rootPackage.optionalDependencies ?? {};
const expectedPackageNames = new Set(platformPackages.map((pkg) => pkg.packageName));

for (const pkg of platformPackages) {
  const depVersion = optionalDeps[pkg.packageName];
  if (!depVersion) {
    fail(`Missing optional dependency for ${pkg.packageName}`);
  }
  if (depVersion !== rootPackage.version) {
    fail(`Optional dependency ${pkg.packageName} version ${depVersion} does not match root version ${rootPackage.version}`);
  }
}

for (const depName of Object.keys(optionalDeps)) {
  if (!expectedPackageNames.has(depName)) {
    fail(`Unexpected optional dependency ${depName}`);
  }
}

const tagName = process.argv[2] ?? process.env.GITHUB_REF_NAME ?? "";
const tagVersion = normalizeTagVersion(tagName);
if (tagVersion && tagVersion !== rootPackage.version) {
  fail(`Tag version ${tagVersion} does not match package version ${rootPackage.version}`);
}

console.log(`Version check passed for ${rootPackage.version}`);
