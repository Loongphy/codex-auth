import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");
const workingRoot = path.basename(repoRoot) === "app.asar" ? path.dirname(repoRoot) : repoRoot;
const publicRoot = path.join(__dirname, "public");
const isWindows = process.platform === "win32";
const binaryName = isWindows ? "codex-auth.exe" : "codex-auth";
const packageMap = {
  "linux:x64": "@loongphy/codex-auth-linux-x64",
  "darwin:x64": "@loongphy/codex-auth-darwin-x64",
  "darwin:arm64": "@loongphy/codex-auth-darwin-arm64",
  "win32:x64": "@loongphy/codex-auth-win32-x64",
  "win32:arm64": "@loongphy/codex-auth-win32-arm64"
};
const argv = new Set(process.argv.slice(2));
const shouldOpenBrowser = argv.has("--open");
const host = "127.0.0.1";
const requestedPort = Number(process.env.PORT || 4318);

let cachedBinaryPath = null;
let buildingBinaryPromise = null;
let cachedRunner = null;
const commandAvailability = new Map();

const mimeTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml; charset=utf-8"
};

function resolveHome() {
  return process.env.HOME || process.env.USERPROFILE || os.homedir();
}

function resolveCodexHome() {
  return path.join(resolveHome(), ".codex");
}

function resolveRegistryPath() {
  return path.join(resolveCodexHome(), "accounts", "registry.json");
}

async function exists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

function unpackedAppPath(targetPath) {
  return targetPath.replace("app.asar", "app.asar.unpacked");
}

async function resolveBundledBinary() {
  const packageName = packageMap[`${process.platform}:${process.arch}`];
  if (!packageName) {
    return null;
  }

  const candidate = unpackedAppPath(path.join(repoRoot, "node_modules", packageName, "bin", binaryName));
  if (await exists(candidate)) {
    return candidate;
  }

  const standardCandidate = path.join(repoRoot, "node_modules", packageName, "bin", binaryName);
  if (await exists(standardCandidate)) {
    return standardCandidate;
  }

  return null;
}

function openBrowser(url) {
  const command = process.platform === "darwin"
    ? "open"
    : process.platform === "win32"
      ? "cmd"
      : "xdg-open";
  const args = process.platform === "darwin"
    ? [url]
    : process.platform === "win32"
      ? ["/c", "start", "", url]
      : [url];

  const child = spawn(command, args, {
    detached: true,
    stdio: "ignore"
  });
  child.unref();
}

function runCommand(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd || workingRoot,
      env: { ...process.env, ...(options.env || {}) },
      stdio: ["ignore", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", reject);
    child.on("close", (code) => {
      resolve({
        code: code ?? 1,
        stdout,
        stderr
      });
    });
  });
}

async function ensureBinary() {
  if (cachedBinaryPath && await exists(cachedBinaryPath)) {
    return cachedBinaryPath;
  }

  const envBinary = process.env.CODEX_AUTH_GUI_BIN;
  if (envBinary && await exists(envBinary)) {
    cachedBinaryPath = envBinary;
    return cachedBinaryPath;
  }

  const builtBinary = path.join(repoRoot, "zig-out", "bin", binaryName);
  if (await exists(builtBinary)) {
    cachedBinaryPath = builtBinary;
    return cachedBinaryPath;
  }

  if (!buildingBinaryPromise) {
    buildingBinaryPromise = runCommand("zig", ["build"]).then(async (result) => {
      if (result.code !== 0) {
        throw new Error(result.stderr.trim() || result.stdout.trim() || "Failed to build codex-auth.");
      }
      if (!await exists(builtBinary)) {
        throw new Error(`Build completed but ${builtBinary} was not found.`);
      }
      cachedBinaryPath = builtBinary;
      return builtBinary;
    }).finally(() => {
      buildingBinaryPromise = null;
    });
  }

  return buildingBinaryPromise;
}

async function commandOnPath(command) {
  if (commandAvailability.has(command)) {
    return commandAvailability.get(command);
  }

  const probe = await runCommand(process.platform === "win32" ? "where" : "which", [command]);
  const available = probe.code === 0;
  commandAvailability.set(command, available);
  return available;
}

async function ensureRunner() {
  if (cachedRunner) {
    return cachedRunner;
  }

  const envBinary = process.env.CODEX_AUTH_GUI_BIN;
  if (envBinary && await exists(envBinary)) {
    cachedRunner = { command: envBinary, args: [] };
    return cachedRunner;
  }

  const builtBinary = path.join(repoRoot, "zig-out", "bin", binaryName);
  if (await exists(builtBinary)) {
    cachedRunner = { command: builtBinary, args: [] };
    return cachedRunner;
  }

  const bundledBinary = await resolveBundledBinary();
  if (bundledBinary) {
    cachedRunner = { command: bundledBinary, args: [] };
    return cachedRunner;
  }

  if (await commandOnPath("zig")) {
    const binaryPath = await ensureBinary();
    cachedRunner = { command: binaryPath, args: [] };
    return cachedRunner;
  }

  if (await commandOnPath("codex-auth")) {
    cachedRunner = { command: "codex-auth", args: [] };
    return cachedRunner;
  }

  throw new Error("Unable to find codex-auth. Install Zig to build locally or make codex-auth available on PATH.");
}

async function runCodexAuth(args) {
  const runner = await ensureRunner();
  const result = await runCommand(runner.command, [...runner.args, ...args]);
  if (result.code !== 0) {
    const message = result.stderr.trim() || result.stdout.trim() || `codex-auth exited with code ${result.code}`;
    const error = new Error(message);
    error.details = result;
    throw error;
  }
  return result;
}

async function readRegistry() {
  const registryPath = resolveRegistryPath();
  try {
    const raw = await fs.readFile(registryPath, "utf8");
    return JSON.parse(raw);
  } catch (error) {
    if (error.code === "ENOENT") {
      return {
        schema_version: null,
        active_account_key: null,
        active_account_activated_at_ms: null,
        auto_switch: {
          enabled: false,
          threshold_5h_percent: 10,
          threshold_weekly_percent: 5
        },
        api: {
          usage: true,
          account: true
        },
        accounts: []
      };
    }
    throw error;
  }
}

function parseStatusOutput(text) {
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const status = {
    autoSwitch: "OFF",
    runtime: "unknown",
    threshold5h: 10,
    thresholdWeekly: 5,
    usageMode: "api",
    accountMode: "api"
  };

  for (const line of lines) {
    if (line.startsWith("auto-switch:")) {
      status.autoSwitch = line.split(":")[1]?.trim() || status.autoSwitch;
      continue;
    }
    if (line.startsWith("service:")) {
      status.runtime = line.split(":")[1]?.trim() || status.runtime;
      continue;
    }
    if (line.startsWith("thresholds:")) {
      const match = line.match(/5h<(\d+)%.*, weekly<(\d+)%/);
      if (match) {
        status.threshold5h = Number(match[1]);
        status.thresholdWeekly = Number(match[2]);
      }
      continue;
    }
    if (line.startsWith("usage:")) {
      status.usageMode = line.split(":")[1]?.trim() || status.usageMode;
      continue;
    }
    if (line.startsWith("account:")) {
      status.accountMode = line.split(":")[1]?.trim() || status.accountMode;
    }
  }

  return status;
}

async function getOverview() {
  const registry = await readRegistry();
  let status = {
    autoSwitch: registry.auto_switch?.enabled ? "ON" : "OFF",
    runtime: "unknown",
    threshold5h: registry.auto_switch?.threshold_5h_percent ?? 10,
    thresholdWeekly: registry.auto_switch?.threshold_weekly_percent ?? 5,
    usageMode: registry.api?.usage ? "api" : "local",
    accountMode: registry.api?.account ? "api" : "disabled"
  };
  let cliWarning = null;

  try {
    const result = await runCodexAuth(["status"]);
    status = parseStatusOutput(result.stdout);
  } catch (error) {
    cliWarning = error.message;
  }

  const activeAccount = registry.accounts.find((account) => account.account_key === registry.active_account_key) || null;

  return {
    codexHome: resolveCodexHome(),
    registry,
    status,
    activeAccount,
    cliWarning
  };
}

async function getAccountByKey(accountKey) {
  const registry = await readRegistry();
  return registry.accounts.find((account) => account.account_key === accountKey) || null;
}

function preferredQueryForAccount(account) {
  if (typeof account.email === "string" && account.email.length > 0) {
    return account.email;
  }
  if (typeof account.alias === "string" && account.alias.length > 0) {
    return account.alias;
  }
  if (typeof account.account_name === "string" && account.account_name.length > 0) {
    return account.account_name;
  }
  throw new Error("This account does not have a usable switch/remove query.");
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) {
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw) return {};
  return JSON.parse(raw);
}

function sendJson(response, code, payload) {
  response.writeHead(code, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store"
  });
  response.end(JSON.stringify(payload));
}

function sendError(response, error) {
  const details = error.details || {};
  sendJson(response, 500, {
    error: error.message,
    stdout: details.stdout || "",
    stderr: details.stderr || ""
  });
}

async function handleAction(response, action) {
  try {
    const result = await action();
    sendJson(response, 200, result);
  } catch (error) {
    sendError(response, error);
  }
}

async function importUploadedFile(payload) {
  const filename = String(payload.filename || "import.auth.json");
  const alias = typeof payload.alias === "string" ? payload.alias.trim() : "";
  const contentBase64 = payload.contentBase64;

  if (typeof contentBase64 !== "string" || contentBase64.length === 0) {
    throw new Error("No file content was provided.");
  }

  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "codex-auth-gui-"));
  const tempPath = path.join(tempDir, path.basename(filename));

  try {
    await fs.writeFile(tempPath, Buffer.from(contentBase64, "base64"));
    const args = ["import", tempPath];
    if (alias) {
      args.push("--alias", alias);
    }
    const result = await runCodexAuth(args);
    return {
      message: `Imported ${filename}.`,
      stdout: result.stdout,
      stderr: result.stderr
    };
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
}

async function handleApi(request, response) {
  const { method, url } = request;
  const pathname = new URL(url, `http://${request.headers.host}`).pathname;

  if (method === "GET" && pathname === "/api/overview") {
    return handleAction(response, async () => ({ overview: await getOverview() }));
  }

  if (method !== "POST") {
    response.writeHead(404);
    response.end("Not found");
    return;
  }

  const payload = await readBody(request);

  if (pathname === "/api/refresh") {
    return handleAction(response, async () => {
      const result = await runCodexAuth(["list"]);
      return {
        message: "Usage data refreshed.",
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/login") {
    return handleAction(response, async () => {
      const args = ["login"];
      if (payload.deviceAuth) {
        args.push("--device-auth");
      }
      const result = await runCodexAuth(args);
      return {
        message: payload.deviceAuth ? "Device auth login completed." : "Browser login completed.",
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/switch") {
    return handleAction(response, async () => {
      if (typeof payload.accountKey !== "string" || payload.accountKey.length === 0) {
        throw new Error("Missing account key.");
      }
      const account = await getAccountByKey(payload.accountKey);
      if (!account) {
        throw new Error("Account no longer exists in the registry.");
      }
      const result = await runCodexAuth(["switch", preferredQueryForAccount(account)]);
      return {
        message: "Active account switched.",
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/remove") {
    return handleAction(response, async () => {
      if (typeof payload.accountKey !== "string" || payload.accountKey.length === 0) {
        throw new Error("Missing account key.");
      }
      const account = await getAccountByKey(payload.accountKey);
      if (!account) {
        throw new Error("Account no longer exists in the registry.");
      }
      const result = await runCodexAuth(["remove", preferredQueryForAccount(account)]);
      return {
        message: "Account removed.",
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/remove-all") {
    return handleAction(response, async () => {
      const result = await runCodexAuth(["remove", "--all"]);
      return {
        message: "All saved accounts removed.",
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/import-file") {
    return handleAction(response, async () => {
      const result = await importUploadedFile(payload);
      return {
        ...result,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/import-path") {
    return handleAction(response, async () => {
      if (typeof payload.importPath !== "string" || payload.importPath.trim().length === 0) {
        throw new Error("Missing import path.");
      }
      const args = ["import", payload.importPath.trim()];
      if (typeof payload.alias === "string" && payload.alias.trim().length > 0) {
        args.push("--alias", payload.alias.trim());
      }
      const result = await runCodexAuth(args);
      return {
        message: "Import finished.",
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/import-cpa") {
    return handleAction(response, async () => {
      const args = ["import", "--cpa"];
      if (typeof payload.importPath === "string" && payload.importPath.trim().length > 0) {
        args.push(payload.importPath.trim());
      }
      if (typeof payload.alias === "string" && payload.alias.trim().length > 0) {
        args.push("--alias", payload.alias.trim());
      }
      const result = await runCodexAuth(args);
      return {
        message: "CPA import finished.",
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/purge") {
    return handleAction(response, async () => {
      const args = ["import", "--purge"];
      if (typeof payload.importPath === "string" && payload.importPath.trim().length > 0) {
        args.push(payload.importPath.trim());
      }
      const result = await runCodexAuth(args);
      return {
        message: "Registry rebuild finished.",
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/auto-switch") {
    return handleAction(response, async () => {
      const enabled = Boolean(payload.enabled);
      const result = await runCodexAuth(["config", "auto", enabled ? "enable" : "disable"]);
      return {
        message: `Auto-switch ${enabled ? "enabled" : "disabled"}.`,
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/thresholds") {
    return handleAction(response, async () => {
      const threshold5h = Number(payload.threshold5h);
      const thresholdWeekly = Number(payload.thresholdWeekly);
      if (!Number.isInteger(threshold5h) || threshold5h < 1 || threshold5h > 100) {
        throw new Error("5h threshold must be an integer from 1 to 100.");
      }
      if (!Number.isInteger(thresholdWeekly) || thresholdWeekly < 1 || thresholdWeekly > 100) {
        throw new Error("Weekly threshold must be an integer from 1 to 100.");
      }
      const result = await runCodexAuth([
        "config",
        "auto",
        "--5h",
        String(threshold5h),
        "--weekly",
        String(thresholdWeekly)
      ]);
      return {
        message: "Thresholds updated.",
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/api-config") {
    return handleAction(response, async () => {
      const enabled = Boolean(payload.enabled);
      const result = await runCodexAuth(["config", "api", enabled ? "enable" : "disable"]);
      return {
        message: `API access ${enabled ? "enabled" : "disabled"}.`,
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  if (pathname === "/api/clean") {
    return handleAction(response, async () => {
      const result = await runCodexAuth(["clean"]);
      return {
        message: "Backup cleanup finished.",
        stdout: result.stdout,
        stderr: result.stderr,
        overview: await getOverview()
      };
    });
  }

  response.writeHead(404);
  response.end("Not found");
}

async function serveStatic(response, pathname) {
  const normalizedPath = pathname === "/" ? "/index.html" : pathname;
  const filePath = path.normalize(path.join(publicRoot, normalizedPath));

  if (!filePath.startsWith(publicRoot)) {
    response.writeHead(403);
    response.end("Forbidden");
    return;
  }

  try {
    const data = await fs.readFile(filePath);
    response.writeHead(200, {
      "content-type": mimeTypes[path.extname(filePath)] || "application/octet-stream",
      "cache-control": "no-store"
    });
    response.end(data);
  } catch (error) {
    if (error.code === "ENOENT") {
      response.writeHead(404);
      response.end("Not found");
      return;
    }
    response.writeHead(500);
    response.end("Server error");
  }
}

const server = createServer(async (request, response) => {
  try {
    const pathname = new URL(request.url, `http://${request.headers.host}`).pathname;
    if (pathname.startsWith("/api/")) {
      await handleApi(request, response);
      return;
    }
    await serveStatic(response, pathname);
  } catch (error) {
    sendError(response, error);
  }
});

function announceServerUrl(boundPort) {
  const url = `http://${host}:${boundPort}`;
  process.stdout.write(`Codex Auth GUI running at ${url}\n`);
  if (shouldOpenBrowser) {
    openBrowser(url);
  }
}

server.on("error", (error) => {
  if (error.code === "EADDRINUSE" && requestedPort !== 0) {
    server.listen(0, host);
    return;
  }
  throw error;
});

server.on("listening", () => {
  const address = server.address();
  const actualPort = typeof address === "object" && address ? address.port : requestedPort;
  announceServerUrl(actualPort);
});

server.listen(requestedPort, host);
