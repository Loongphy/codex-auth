const state = {
  busy: false,
  filter: "",
  overview: null
};

const elements = {
  actionLog: document.querySelector("#action-log"),
  accountCount: document.querySelector("#account-count"),
  accountsBody: document.querySelector("#accounts-body"),
  apiToggle: document.querySelector("#api-toggle"),
  autoSwitchToggle: document.querySelector("#auto-switch-toggle"),
  cleanButton: document.querySelector("#clean-button"),
  codexHome: document.querySelector("#codex-home"),
  cpaAlias: document.querySelector("#cpa-alias"),
  cpaForm: document.querySelector("#cpa-form"),
  cpaPath: document.querySelector("#cpa-path"),
  loginBrowserButton: document.querySelector("#login-browser-button"),
  loginDeviceButton: document.querySelector("#login-device-button"),
  messageBanner: document.querySelector("#message-banner"),
  pathAlias: document.querySelector("#path-alias"),
  pathForm: document.querySelector("#path-form"),
  importPath: document.querySelector("#import-path"),
  purgeForm: document.querySelector("#purge-form"),
  purgePath: document.querySelector("#purge-path"),
  refreshButton: document.querySelector("#refresh-button"),
  reloadButton: document.querySelector("#reload-button"),
  removeAllButton: document.querySelector("#remove-all-button"),
  searchInput: document.querySelector("#search-input"),
  statusChips: document.querySelector("#status-chips"),
  summaryMeta: document.querySelector("#summary-meta"),
  summaryStats: document.querySelector("#summary-stats"),
  summaryTitle: document.querySelector("#summary-title"),
  threshold5h: document.querySelector("#threshold-5h"),
  thresholdForm: document.querySelector("#threshold-form"),
  thresholdWeekly: document.querySelector("#threshold-weekly"),
  uploadAlias: document.querySelector("#upload-alias"),
  uploadFile: document.querySelector("#upload-file"),
  uploadForm: document.querySelector("#upload-form")
};

function formatDate(timestampSeconds) {
  if (!timestampSeconds) return "Never";
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short"
  }).format(new Date(timestampSeconds * 1000));
}

function formatPercent(value) {
  if (typeof value !== "number") return "—";
  return `${Math.round(value)}%`;
}

function formatPlan(account) {
  return account.plan || account.last_usage?.plan_type || "unknown";
}

function usagePercentValue(windowUsage) {
  if (!windowUsage || typeof windowUsage.used_percent !== "number") return null;
  return Math.max(0, Math.min(100, Math.round(windowUsage.used_percent)));
}

function usageCompact(windowUsage) {
  if (!windowUsage) return "—";
  const reset = windowUsage.resets_at ? formatDate(windowUsage.resets_at) : "n/a";
  return `${formatPercent(windowUsage.used_percent)} · ${reset}`;
}

function chip(label, value, tone = "") {
  return `
    <div class="chip ${tone}">
      <span>${label}</span>
      <strong>${value}</strong>
    </div>
  `;
}

function summaryStat(label, value) {
  return `
    <div class="stat">
      <span>${label}</span>
      <strong>${value}</strong>
    </div>
  `;
}

function usageSummaryStat(label, windowUsage, tone = "") {
  const percent = usagePercentValue(windowUsage);
  const reset = windowUsage?.resets_at ? formatDate(windowUsage.resets_at) : "No reset data";
  const safeTone = tone ? ` stat-${tone}` : "";

  if (percent === null) {
    return `
      <div class="stat${safeTone}">
        <span>${label}</span>
        <strong>—</strong>
        <div class="meter">
          <div class="meter-fill" style="width: 0%"></div>
        </div>
        <small>No usage data</small>
      </div>
    `;
  }

  return `
    <div class="stat${safeTone}">
      <span>${label}</span>
      <strong>${percent}%</strong>
      <div class="meter">
        <div class="meter-fill" style="width: ${percent}%"></div>
      </div>
      <small>Resets ${escapeHtml(reset)}</small>
    </div>
  `;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function setBusy(isBusy) {
  state.busy = isBusy;
  document.body.classList.toggle("is-busy", isBusy);
  for (const node of document.querySelectorAll("button, input")) {
    if (node.id === "search-input") continue;
    node.disabled = isBusy;
  }
}

function setBanner(message, tone = "neutral") {
  elements.messageBanner.textContent = message;
  elements.messageBanner.classList.remove("hidden", "tone-error", "tone-success");
  if (tone === "error") {
    elements.messageBanner.classList.add("tone-error");
  } else if (tone === "success") {
    elements.messageBanner.classList.add("tone-success");
  }
}

function clearBanner() {
  elements.messageBanner.classList.add("hidden");
}

function logOutput(title, payload = {}) {
  const lines = [title];
  if (payload.stdout) {
    lines.push("", "stdout", payload.stdout.trimEnd());
  }
  if (payload.stderr) {
    lines.push("", "stderr", payload.stderr.trimEnd());
  }
  elements.actionLog.textContent = lines.join("\n") || "No output.";
}

async function request(path, options = {}) {
  const response = await fetch(path, {
    method: options.method || "GET",
    headers: {
      "content-type": "application/json"
    },
    body: options.body ? JSON.stringify(options.body) : undefined
  });
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload.error || "Request failed.");
  }
  return payload;
}

function renderSummary() {
  const { activeAccount, registry, status, cliWarning } = state.overview;

  if (activeAccount) {
    const subtitleParts = [
      activeAccount.account_name || null,
      activeAccount.alias || null,
      formatPlan(activeAccount),
      activeAccount.auth_mode || null
    ].filter(Boolean);

    elements.summaryTitle.textContent = activeAccount.email;
    elements.summaryMeta.textContent = subtitleParts.join(" · ");
    elements.summaryStats.innerHTML = [
      usageSummaryStat("5h window", activeAccount.last_usage?.primary, "teal"),
      usageSummaryStat("Weekly window", activeAccount.last_usage?.secondary, "amber"),
      summaryStat("Last used", formatDate(activeAccount.last_used_at)),
      summaryStat("Usage updated", formatDate(activeAccount.last_usage_at))
    ].join("");
  } else {
    elements.summaryTitle.textContent = "No active account";
    elements.summaryMeta.textContent = "Use login or import actions to add one.";
    elements.summaryStats.innerHTML = [
      summaryStat("5h window", "—"),
      summaryStat("Weekly window", "—"),
      summaryStat("Last used", "Never"),
      summaryStat("Usage updated", "Never")
    ].join("");
  }

  elements.statusChips.innerHTML = [
    chip("Service", status.runtime),
    chip("Auto", status.autoSwitch, status.autoSwitch === "ON" ? "chip-good" : ""),
    chip("Usage", status.usageMode),
    chip("Account API", status.accountMode),
    chip("Accounts", String(registry.accounts.length))
  ].join("");

  elements.threshold5h.value = status.threshold5h;
  elements.thresholdWeekly.value = status.thresholdWeekly;
  elements.autoSwitchToggle.checked = status.autoSwitch === "ON";
  elements.apiToggle.checked = status.accountMode === "api";
  elements.codexHome.textContent = `Codex home: ${state.overview.codexHome}`;

  if (cliWarning) {
    setBanner(`CLI status fallback: ${cliWarning}`, "error");
  } else {
    clearBanner();
  }
}

function accountMatchesFilter(account, filterText) {
  if (!filterText) return true;
  return [
    account.email,
    account.alias,
    account.account_name,
    account.account_key
  ].filter(Boolean).some((value) => value.toLowerCase().includes(filterText));
}

function renderAccounts() {
  const registry = state.overview.registry;
  const filterText = state.filter.trim().toLowerCase();
  const accounts = registry.accounts.filter((account) => accountMatchesFilter(account, filterText));

  elements.accountCount.textContent = `${accounts.length} shown · ${registry.accounts.length} total`;
  elements.removeAllButton.disabled = registry.accounts.length === 0 || state.busy;

  if (accounts.length === 0) {
    elements.accountsBody.innerHTML = `
      <tr>
        <td colspan="6" class="empty-cell">No accounts match this filter.</td>
      </tr>
    `;
    return;
  }

  elements.accountsBody.innerHTML = accounts.map((account) => {
    const isActive = registry.active_account_key === account.account_key;
    const identityBits = [
      account.alias || null,
      account.account_name || null,
      account.auth_mode || null
    ].filter(Boolean).join(" · ");
    const primaryPercent = usagePercentValue(account.last_usage?.primary) ?? 0;
    const weeklyPercent = usagePercentValue(account.last_usage?.secondary) ?? 0;

    return `
      <tr class="${isActive ? "row-active" : ""}">
        <td class="account-cell">
          <div class="account-primary">
            ${isActive ? '<span class="row-flag">Active</span>' : ""}
            <strong>${escapeHtml(account.email)}</strong>
          </div>
          <div class="account-secondary">${escapeHtml(identityBits || account.account_key)}</div>
          <div class="account-key">${escapeHtml(account.account_key)}</div>
        </td>
        <td>${escapeHtml(formatPlan(account))}</td>
        <td>
          <div class="usage-cell">
            <strong>${escapeHtml(formatPercent(account.last_usage?.primary?.used_percent))}</strong>
            <div class="meter meter-tight">
              <div class="meter-fill meter-fill-teal" style="width: ${primaryPercent}%"></div>
            </div>
            <span>${escapeHtml(account.last_usage?.primary?.resets_at ? formatDate(account.last_usage.primary.resets_at) : "No reset data")}</span>
          </div>
        </td>
        <td>
          <div class="usage-cell">
            <strong>${escapeHtml(formatPercent(account.last_usage?.secondary?.used_percent))}</strong>
            <div class="meter meter-tight">
              <div class="meter-fill meter-fill-amber" style="width: ${weeklyPercent}%"></div>
            </div>
            <span>${escapeHtml(account.last_usage?.secondary?.resets_at ? formatDate(account.last_usage.secondary.resets_at) : "No reset data")}</span>
          </div>
        </td>
        <td>${escapeHtml(formatDate(account.last_used_at))}</td>
        <td class="actions-cell">
          <button class="button button-small button-primary" data-action="switch" data-key="${escapeHtml(account.account_key)}" ${isActive ? "disabled" : ""}>Switch</button>
          <button class="button button-small button-danger" data-action="remove" data-key="${escapeHtml(account.account_key)}">Remove</button>
        </td>
      </tr>
    `;
  }).join("");
}

async function loadOverview() {
  const payload = await request("/api/overview");
  state.overview = payload.overview;
  renderSummary();
  renderAccounts();
}

async function performAction({ confirmMessage = "", pendingMessage = "Working…", action, onSuccess } = {}) {
  if (confirmMessage && !window.confirm(confirmMessage)) {
    return;
  }

  setBusy(true);
  setBanner(pendingMessage);
  logOutput(pendingMessage);

  try {
    const payload = await action();
    if (payload.overview) {
      state.overview = payload.overview;
      renderSummary();
      renderAccounts();
    }
    if (onSuccess) {
      onSuccess(payload);
    }
    setBanner(payload.message, "success");
    logOutput(payload.message, payload);
  } catch (error) {
    setBanner(error.message, "error");
    logOutput(error.message);
  } finally {
    setBusy(false);
  }
}

async function encodeFile(file) {
  const buffer = await file.arrayBuffer();
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

elements.reloadButton.addEventListener("click", () => {
  performAction({
    pendingMessage: "Reloading dashboard…",
    action: async () => {
      const payload = await request("/api/overview");
      return {
        message: "View reloaded.",
        overview: payload.overview
      };
    }
  });
});

elements.refreshButton.addEventListener("click", () => {
  performAction({
    pendingMessage: "Refreshing usage data…",
    action: () => request("/api/refresh", { method: "POST", body: {} })
  });
});

elements.cleanButton.addEventListener("click", () => {
  performAction({
    confirmMessage: "Clean backup and stale registry files now?",
    pendingMessage: "Cleaning backups…",
    action: () => request("/api/clean", { method: "POST", body: {} })
  });
});

elements.loginBrowserButton.addEventListener("click", () => {
  performAction({
    pendingMessage: "Starting browser login… complete the auth flow and wait for the app to return.",
    action: () => request("/api/login", {
      method: "POST",
      body: { deviceAuth: false }
    })
  });
});

elements.loginDeviceButton.addEventListener("click", () => {
  performAction({
    pendingMessage: "Starting device auth login… follow the code flow and wait for completion.",
    action: () => request("/api/login", {
      method: "POST",
      body: { deviceAuth: true }
    })
  });
});

elements.searchInput.addEventListener("input", (event) => {
  state.filter = event.target.value;
  renderAccounts();
});

elements.thresholdForm.addEventListener("submit", (event) => {
  event.preventDefault();
  performAction({
    pendingMessage: "Saving thresholds…",
    action: () => request("/api/thresholds", {
      method: "POST",
      body: {
        threshold5h: Number(elements.threshold5h.value),
        thresholdWeekly: Number(elements.thresholdWeekly.value)
      }
    })
  });
});

elements.autoSwitchToggle.addEventListener("change", () => {
  performAction({
    pendingMessage: "Updating auto-switch…",
    action: () => request("/api/auto-switch", {
      method: "POST",
      body: { enabled: elements.autoSwitchToggle.checked }
    })
  });
});

elements.apiToggle.addEventListener("change", () => {
  performAction({
    pendingMessage: "Updating API usage mode…",
    action: () => request("/api/api-config", {
      method: "POST",
      body: { enabled: elements.apiToggle.checked }
    })
  });
});

elements.uploadForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const file = elements.uploadFile.files?.[0];
  if (!file) {
    setBanner("Choose a JSON file first.", "error");
    return;
  }

  performAction({
    pendingMessage: "Importing uploaded auth file…",
    action: async () => request("/api/import-file", {
      method: "POST",
      body: {
        filename: file.name,
        alias: elements.uploadAlias.value.trim(),
        contentBase64: await encodeFile(file)
      }
    }),
    onSuccess: () => {
      elements.uploadForm.reset();
    }
  });
});

elements.pathForm.addEventListener("submit", (event) => {
  event.preventDefault();
  performAction({
    pendingMessage: "Importing path…",
    action: () => request("/api/import-path", {
      method: "POST",
      body: {
        importPath: elements.importPath.value.trim(),
        alias: elements.pathAlias.value.trim()
      }
    }),
    onSuccess: () => {
      elements.pathForm.reset();
    }
  });
});

elements.cpaForm.addEventListener("submit", (event) => {
  event.preventDefault();
  performAction({
    pendingMessage: "Importing CPA tokens…",
    action: () => request("/api/import-cpa", {
      method: "POST",
      body: {
        importPath: elements.cpaPath.value.trim(),
        alias: elements.cpaAlias.value.trim()
      }
    }),
    onSuccess: () => {
      elements.cpaForm.reset();
    }
  });
});

elements.purgeForm.addEventListener("submit", (event) => {
  event.preventDefault();
  performAction({
    confirmMessage: "Rebuild the registry from saved auth snapshots?",
    pendingMessage: "Rebuilding registry…",
    action: () => request("/api/purge", {
      method: "POST",
      body: {
        importPath: elements.purgePath.value.trim()
      }
    }),
    onSuccess: () => {
      elements.purgeForm.reset();
    }
  });
});

elements.removeAllButton.addEventListener("click", () => {
  performAction({
    confirmMessage: "Remove all saved accounts from the registry and local auth snapshots?",
    pendingMessage: "Removing all accounts…",
    action: () => request("/api/remove-all", {
      method: "POST",
      body: {}
    })
  });
});

elements.accountsBody.addEventListener("click", (event) => {
  const button = event.target.closest("button[data-action]");
  if (!button) return;

  const accountKey = button.dataset.key;
  const actionName = button.dataset.action;
  const account = state.overview.registry.accounts.find((item) => item.account_key === accountKey);
  if (!account) return;

  if (actionName === "switch") {
    performAction({
      confirmMessage: `Switch to ${account.email}?`,
      pendingMessage: `Switching to ${account.email}…`,
      action: () => request("/api/switch", {
        method: "POST",
        body: { accountKey }
      })
    });
    return;
  }

  if (actionName === "remove") {
    performAction({
      confirmMessage: `Remove ${account.email}?`,
      pendingMessage: `Removing ${account.email}…`,
      action: () => request("/api/remove", {
        method: "POST",
        body: { accountKey }
      })
    });
  }
});

loadOverview().catch((error) => {
  setBanner(error.message, "error");
  logOutput(error.message);
});
