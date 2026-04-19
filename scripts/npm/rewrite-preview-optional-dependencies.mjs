import fs from "node:fs";
import path from "node:path";
import { platformPackages } from "./metadata.mjs";

function requireArgValue(argv, index, arg) {
  const value = argv[index + 1];
  if (value === undefined || value.startsWith("--")) {
    throw new Error(`Missing value for argument: ${arg}`);
  }
  return value;
}

function parseArgs(argv) {
  const options = {
    rootDir: "",
    previewOrigin: "https://pkg.pr.new",
    repository: "",
    prNumber: "",
    sha: ""
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--root-dir") {
      options.rootDir = path.resolve(requireArgValue(argv, i, arg));
      i += 1;
    } else if (arg === "--preview-origin") {
      options.previewOrigin = requireArgValue(argv, i, arg);
      i += 1;
    } else if (arg === "--repository") {
      options.repository = requireArgValue(argv, i, arg);
      i += 1;
    } else if (arg === "--pr-number") {
      options.prNumber = requireArgValue(argv, i, arg);
      i += 1;
    } else if (arg === "--sha") {
      options.sha = requireArgValue(argv, i, arg);
      i += 1;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!options.rootDir) {
    throw new Error("Missing required argument: --root-dir");
  }

  if (!options.repository) {
    throw new Error("Missing required argument: --repository");
  }

  if (!options.prNumber) {
    throw new Error("Missing required argument: --pr-number");
  }

  if (!options.sha) {
    throw new Error("Missing required argument: --sha");
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
// pkg.pr.new currently abbreviates compact SHA URLs to 7 characters.
const formattedSha = options.sha.slice(0, 7);
const previewPackages = new Map(
  platformPackages.map((pkg) => [
    pkg.packageName,
    new URL(`/${options.repository}/${pkg.packageName}@${formattedSha}`, options.previewOrigin).href
  ])
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
rootPackage.codexAuthPreviewLabel = `pr-${options.prNumber} ${formattedSha}`;
writeJson(packageJsonPath, rootPackage);

console.log(`Rewrote preview optionalDependencies in ${packageJsonPath}`);
