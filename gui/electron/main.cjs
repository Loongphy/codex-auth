const { app, BrowserWindow, Menu, dialog, shell } = require("electron");
const path = require("node:path");
const { spawn } = require("node:child_process");

let mainWindow = null;
let serverProcess = null;
let appUrl = null;
let isQuitting = false;

const isSmokeTest = process.argv.includes("--smoke-test");

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1380,
    height: 920,
    minWidth: 1080,
    minHeight: 760,
    title: "Codex Auth Control Room",
    backgroundColor: "#f4efe6",
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });

  mainWindow.once("ready-to-show", () => {
    mainWindow.show();
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });

  mainWindow.webContents.on("will-navigate", (event, url) => {
    if (appUrl && url !== appUrl) {
      event.preventDefault();
      shell.openExternal(url);
    }
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

function waitForServerUrl(child) {
  return new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";
    let settled = false;
    const timeout = setTimeout(() => {
      settleReject(new Error(`Timed out waiting for the local GUI server.\n${stderr.trim() || stdout.trim()}`.trim()));
    }, 15000);

    const settleResolve = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve(value);
    };

    const settleReject = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      reject(error);
    };

    child.stdout.on("data", (chunk) => {
      const text = chunk.toString();
      stdout += text;
      const match = stdout.match(/Codex Auth GUI running at (http:\/\/[^\s]+)/);
      if (match) {
        settleResolve(match[1]);
      }
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.once("error", (error) => {
      settleReject(error);
    });

    child.once("exit", (code) => {
      if (settled) return;
      const detail = stderr.trim() || stdout.trim() || `Server exited with code ${code ?? "unknown"}.`;
      settleReject(new Error(detail));
    });
  });
}

async function startServer() {
  if (serverProcess && appUrl) {
    return appUrl;
  }

  const serverPath = path.join(__dirname, "..", "server.mjs");
  const appRoot = path.join(__dirname, "..", "..");
  const workingRoot = path.basename(appRoot) === "app.asar" ? path.dirname(appRoot) : appRoot;
  serverProcess = spawn(process.execPath, [serverPath], {
    cwd: workingRoot,
    env: {
      ...process.env,
      ELECTRON_RUN_AS_NODE: "1",
      PORT: "0"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  serverProcess.stderr.on("data", (chunk) => {
    process.stderr.write(chunk);
  });

  appUrl = await waitForServerUrl(serverProcess);
  return appUrl;
}

function stopServer() {
  if (!serverProcess) return;
  const child = serverProcess;
  serverProcess = null;
  appUrl = null;

  if (child.killed) return;
  child.kill("SIGTERM");
  setTimeout(() => {
    if (!child.killed) {
      child.kill("SIGKILL");
    }
  }, 1500).unref();
}

async function boot() {
  Menu.setApplicationMenu(null);
  createWindow();

  try {
    const url = await startServer();
    await mainWindow.loadURL(url);
    if (isSmokeTest) {
      process.stdout.write(`Electron smoke test loaded ${url}\n`);
      app.quit();
    }
  } catch (error) {
    dialog.showErrorBox("Failed to Launch Codex Auth", error.message);
    app.quit();
  }
}

app.whenReady().then(boot);

app.on("activate", async () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    await boot();
  }
});

app.on("before-quit", () => {
  isQuitting = true;
  stopServer();
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin" || isSmokeTest) {
    app.quit();
  }
});

process.on("exit", stopServer);
