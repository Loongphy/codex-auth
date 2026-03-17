import fs from "node:fs";
import path from "node:path";

function parseArgs(argv) {
  const options = {
    rootDir: "",
    publishOutput: ""
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--root-dir") {
      options.rootDir = path.resolve(argv[i + 1]);
      i += 1;
    } else if (arg === "--publish-output") {
      options.publishOutput = path.resolve(argv[i + 1]);
      i += 1;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!options.rootDir) {
    throw new Error("Missing required argument: --root-dir");
  }

  if (!options.publishOutput) {
    throw new Error("Missing required argument: --publish-output");
  }

  return options;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

const options = parseArgs(process.argv.slice(2));
const packageJsonPath = path.join(options.rootDir, "package.json");
const rootPackage = readJson(packageJsonPath);
const publishOutput = readJson(options.publishOutput);
const previewPackages = new Map(
  (publishOutput.packages ?? []).map((pkg) => [pkg.name, pkg.url])
);

const optionalDependencies = rootPackage.optionalDependencies ?? {};
const rewrittenOptionalDependencies = {};

for (const depName of Object.keys(optionalDependencies)) {
  const previewUrl = previewPackages.get(depName);
  if (!previewUrl) {
    throw new Error(`Missing preview URL for optional dependency ${depName}`);
  }
  rewrittenOptionalDependencies[depName] = previewUrl;
}

rootPackage.optionalDependencies = rewrittenOptionalDependencies;
writeJson(packageJsonPath, rootPackage);

console.log(`Rewrote preview optionalDependencies in ${packageJsonPath}`);
