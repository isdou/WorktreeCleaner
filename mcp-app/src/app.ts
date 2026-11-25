import {
  App,
  applyDocumentTheme,
  applyHostStyleVariables,
} from "@modelcontextprotocol/ext-apps";

type SafetyKey = "safe" | "caution" | "danger" | "missing";

interface WorktreeItemDTO {
  id: string;
  path: string;
  folderName: string;
  kind: string;
  mainRepoPath: string;
  mainRepoName: string;
  branch: string;
  displayBranch: string;
  headCommit: string;
  headSubject: string;
  isDetached: boolean;
  isLocked: boolean;
  isOrphan: boolean;
  isMissing: boolean;
  directoryExists: boolean;
  source: string;
  remoteName: string;
  safetyLevel: SafetyKey;
  safetySummaryZh: string;
  safetySummaryEn: string;
  isRecentlyActive: boolean;
  isDirty: boolean;
  modifiedCount: number;
  untrackedCount: number;
  aheadCount: number;
  hasUpstream: boolean;
  isMerged: boolean;
  isSquashMerged: boolean;
  canPush: boolean;
  needsPush: boolean;
  canDeleteLocalBranch: boolean;
  originDeletionTarget?: {
    branch: string;
    expectedOID: string;
    endpointID: string;
    localBranch: string;
    headCommit: string;
    mainRepoPath: string;
  };
  suggestedCommitMessage: string;
  suggestedPushBranchName: string;
  activeProcesses: string[];
  preciousIgnoredFiles: string[];
  orphanFileCount: number;
  diskSizeBytes: number;
  formattedSize: string;
  reclaimableCacheBytes: number;
  formattedCacheSize: string;
  cacheDirs: { path: string; sizeBytes: number }[];
  changedFiles: { code: string; path: string }[];
  unpushedCommits: { hash: string; message: string }[];
  pr?: { number: number; state: string; url: string };
  featureSummary?: {
    baseBranch: string;
    totalCommitCount: number;
    filesChangedCount: number;
    insertions: number;
    deletions: number;
    touchedAreas: string[];
    agentTasks: string[];
    branchCommits: { hash: string; relativeDate: string; subject: string }[];
    topFiles: { path: string; insertions: number; deletions: number }[];
  };
}

interface ScanPayload {
  summary: {
    totalCount: number;
    safeCount: number;
    cautionCount: number;
    dangerCount: number;
    missingCount: number;
    reclaimableBytes: number;
    formattedReclaimable: string;
    totalBytes: number;
    formattedTotal: string;
    totalCacheBytes: number;
    formattedTotalCache: string;
  };
  items: WorktreeItemDTO[];
  initialFilter?: string;
  initialSearch?: string;
  displayMode?: "inline" | "workbench";
}

const state = {
  zh: navigator.language.toLowerCase().startsWith("zh"),
  loading: true,
  busy: false,
  displayMode: "workbench" as "workbench" | "inline",
  payload: null as ScanPayload | null,
  filter: "all" as "all" | SafetyKey,
  search: "",
  selectedId: null as string | null,
  inlineInspectId: null as string | null,
  checkedIds: new Set<string>(),
  attachedIds: new Set<string>(),
  canMessage: false,
  canUpdateContext: false,
  canOpenLinks: false,
  toast: null as { message: string; isError: boolean } | null,
  modal: null as
    | null
    | { type: "diff"; title: string; text: string; loading: boolean }
    | {
        type: "push";
        item: WorktreeItemDTO;
        branchName: string;
        commitMessage: string;
        deleteAfterPush: boolean;
        error: string | null;
      }
    | {
        type: "remove";
        item: WorktreeItemDTO;
        moveToTrash: boolean;
        backupCommitFirst: boolean;
        deleteLocalBranch: boolean;
        deleteOriginBranch: boolean;
        force: boolean;
        error: string | null;
      }
    | {
        type: "batch-remove";
        items: WorktreeItemDTO[];
        moveToTrash: boolean;
        backupCommitFirst: boolean;
        deleteLocalBranch: boolean;
        deleteOriginBranch: boolean;
        completed: boolean;
        error: string | null;
      },
};

const app = new App(
  { name: "Worktree Cleaner", version: "1.0.1" },
  { availableDisplayModes: ["inline", "fullscreen"] }
);

function tr(zh: string, en: string): string {
  return state.zh ? zh : en;
}

function esc(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function safetyLabel(key: SafetyKey): string {
  switch (key) {
    case "safe":
      return tr("安全可删", "Safe");
    case "caution":
      return tr("待确认", "Review");
    case "danger":
      return tr("有改动", "Active");
    case "missing":
      return tr("幽灵记录", "Ghost");
  }
}

let toastTimer: number | null = null;
function showToast(message: string, isError = false): void {
  state.toast = { message, isError };
  render();
  if (toastTimer !== null) window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => {
    state.toast = null;
    render();
  }, 4200);
}

function formatBytes(bytes: number): string {
  if (bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let idx = 0;
  while (value >= 1000 && idx < units.length - 1) {
    value /= 1000;
    idx++;
  }
  return `${value >= 100 || idx === 0 ? value.toFixed(0) : value.toFixed(value >= 10 ? 1 : 2)} ${units[idx]}`;
}

function rowHint(item: WorktreeItemDTO): string {
  if (item.activeProcesses.length > 0) {
    return tr(`运行中：${item.activeProcesses[0]}`, `Running: ${item.activeProcesses[0]}`);
  }
  if (item.featureSummary?.agentTasks[0]) {
    return item.featureSummary.agentTasks[0];
  }
  return [
    item.source,
    item.pr ? `#${item.pr.number}` : "",
    item.modifiedCount + item.untrackedCount > 0
      ? tr(`${item.modifiedCount + item.untrackedCount} 改动`, `${item.modifiedCount + item.untrackedCount} dirty`)
      : item.aheadCount > 0
        ? tr(`${item.aheadCount} 未推`, `${item.aheadCount} unpushed`)
        : item.preciousIgnoredFiles[0] ?? (item.isRecentlyActive ? tr("近期", "recent") : ""),
  ]
    .filter(Boolean)
    .join(" · ");
}

function applyScanPayload(raw: unknown): void {
  if (!raw || typeof raw !== "object") return;
  const data = raw as Partial<ScanPayload> & { scan?: ScanPayload };
  const payload = data.scan ?? (data.items && data.summary ? (data as ScanPayload) : null);
  if (!payload) return;

  state.payload = payload;
  state.loading = false;
  if (payload.displayMode === "inline" || payload.displayMode === "workbench") {
    state.displayMode = payload.displayMode;
  }
  if (payload.initialFilter && ["all", "safe", "caution", "danger", "missing"].includes(payload.initialFilter)) {
    state.filter = payload.initialFilter as typeof state.filter;
  }
  if (typeof payload.initialSearch === "string" && payload.initialSearch.length > 0 && !state.search) {
    state.search = payload.initialSearch;
  }

  const items = payload.items;
  const validIds = new Set(items.map((i) => i.id));
  for (const id of Array.from(state.checkedIds)) {
    if (!validIds.has(id)) state.checkedIds.delete(id);
  }
  if (state.inlineInspectId && !validIds.has(state.inlineInspectId)) {
    state.inlineInspectId = null;
  }
  if (!state.selectedId || !validIds.has(state.selectedId)) {
    state.selectedId = items[0]?.id ?? null;
  }
  render();
}

function filteredItems(): WorktreeItemDTO[] {
  const items = state.payload?.items ?? [];
  const q = state.search.trim().toLowerCase();
  return items.filter((item) => {
    if (state.filter !== "all" && item.safetyLevel !== state.filter) return false;
    if (!q) return true;
    const hay = [
      item.mainRepoName,
      item.displayBranch,
      item.folderName,
      item.path,
      item.source,
      item.headSubject,
      ...(item.featureSummary?.agentTasks ?? []),
      ...(item.featureSummary?.branchCommits.map((c) => c.subject) ?? []),
    ]
      .join(" ")
      .toLowerCase();
    return hay.includes(q);
  });
}

function selectedItem(): WorktreeItemDTO | null {
  const items = state.payload?.items ?? [];
  if (state.selectedId) {
    const found = items.find((i) => i.id === state.selectedId);
    if (found) return found;
  }
  return filteredItems()[0] ?? null;
}

async function callTool(name: string, args: Record<string, unknown> = {}) {
  const res = await app.callServerTool({ name, arguments: args });
  return res as {
    isError?: boolean;
    content?: { type: string; text?: string }[];
    structuredContent?: Record<string, unknown>;
  };
}

async function refreshScan(): Promise<void> {
  if (state.busy) return;
  state.busy = true;
  render();
  try {
    const res = await callTool("scan_worktrees", { includeDiskSizes: true });
    if (res.isError) {
      showToast(res.content?.[0]?.text ?? "Scan failed", true);
    } else if (res.structuredContent) {
      applyScanPayload(res.structuredContent);
    }
  } catch (err) {
    showToast(String(err), true);
  } finally {
    state.busy = false;
    state.loading = false;
    render();
  }
}

async function handlePruneGhost(): Promise<void> {
  if (state.busy) return;
  state.busy = true;
  render();
  try {
    const res = await callTool("prune_missing_worktrees", {});
    if (res.isError) {
      showToast(res.content?.[0]?.text ?? "Prune failed", true);
    } else {
      applyScanPayload(res.structuredContent);
      showToast(tr("已清理幽灵元数据", "Pruned ghost metadata"));
    }
  } catch (err) {
    showToast(String(err), true);
  } finally {
    state.busy = false;
    render();
  }
}

async function handleSlimCaches(item: WorktreeItemDTO): Promise<void> {
  if (state.busy) return;
  state.busy = true;
  render();
  try {
    const res = await callTool("slim_worktree_caches", { path: item.path });
    if (res.isError) {
      showToast(res.content?.[0]?.text ?? "Slim failed", true);
    } else {
      applyScanPayload(res.structuredContent);
      const freed = (res.structuredContent?.formattedFreed as string) ?? "";
      showToast(tr(`已将构建缓存移入废纸篓（释放 ${freed}）`, `Moved build caches to Trash (${freed})`));
    }
  } catch (err) {
    showToast(String(err), true);
  } finally {
    state.busy = false;
    render();
  }
}

async function handleCopyPrecious(item: WorktreeItemDTO): Promise<void> {
  if (state.busy) return;
  state.busy = true;
  render();
  try {
    const res = await callTool("copy_precious_files", { path: item.path });
    if (res.isError) {
      showToast(res.content?.[0]?.text ?? "Copy failed", true);
    } else {
      const msg = (res.structuredContent?.message as string) ?? tr("已拷回主仓库", "Copied to main repo");
      showToast(msg);
    }
  } catch (err) {
    showToast(String(err), true);
  } finally {
    state.busy = false;
    render();
  }
}

async function handleOpenDiff(item: WorktreeItemDTO): Promise<void> {
  state.modal = {
    type: "diff",
    title: `${item.mainRepoName} · ${item.displayBranch}`,
    text: "",
    loading: true,
  };
  render();
  try {
    const res = await callTool("get_worktree_diff", { path: item.path });
    const diffText = (res.structuredContent?.diff as string) ?? res.content?.[0]?.text ?? "";
    if (state.modal?.type === "diff") {
      state.modal.text = diffText;
      state.modal.loading = false;
      render();
    }
  } catch (err) {
    if (state.modal?.type === "diff") {
      state.modal.text = String(err);
      state.modal.loading = false;
      render();
    }
  }
}

async function handleExecutePush(): Promise<void> {
  if (!state.modal || state.modal.type !== "push" || state.busy) return;
  const m = state.modal;
  state.busy = true;
  m.error = null;
  render();
  try {
    const res = await callTool("push_worktree", {
      path: m.item.path,
      branchName: m.branchName,
      commitMessage: m.item.isDirty ? m.commitMessage : undefined,
      deleteAfterPush: m.deleteAfterPush,
      moveToTrash: true,
    });
    if (res.isError) {
      m.error = (res.structuredContent?.error as string) ?? res.content?.[0]?.text ?? "Push failed";
    } else {
      state.modal = null;
      applyScanPayload(res.structuredContent);
      showToast((res.structuredContent?.message as string) ?? tr("推送成功", "Pushed successfully"));
    }
  } catch (err) {
    m.error = String(err);
  } finally {
    state.busy = false;
    render();
  }
}

async function handleExecuteRemove(): Promise<void> {
  if (!state.modal || state.modal.type !== "remove" || state.busy) return;
  const m = state.modal;
  state.busy = true;
  m.error = null;
  render();
  try {
    const res = await callTool("remove_worktree", {
      path: m.item.path,
      backupCommitFirst: m.backupCommitFirst,
      moveToTrash: m.moveToTrash,
      deleteLocalBranch: m.deleteLocalBranch,
      ...(m.deleteOriginBranch ? { originDeletionTarget: m.item.originDeletionTarget } : {}),
      force: m.force,
    });
    if (res.isError) {
      m.error = (res.structuredContent?.error as string) ?? res.content?.[0]?.text ?? "Remove failed";
    } else {
      state.modal = null;
      applyScanPayload(res.structuredContent);
      showToast((res.structuredContent?.message as string) ?? tr("移除完成", "Removed"));
    }
  } catch (err) {
    m.error = String(err);
  } finally {
    state.busy = false;
    render();
  }
}

async function handleExecuteBatchRemove(): Promise<void> {
  if (!state.modal || state.modal.type !== "batch-remove" || state.modal.completed || state.busy) return;
  const m = state.modal;
  state.busy = true;
  m.error = null;
  render();

  let completed = 0;
  let absentOriginBranches = 0;
  const errors: string[] = [];
  const { backupCommitFirst, moveToTrash, deleteLocalBranch, deleteOriginBranch } = m;
  try {
    for (const item of m.items) {
      const target = deleteOriginBranch ? item.originDeletionTarget : undefined;
      const label = `${item.mainRepoName} · ${item.displayBranch}${target ? ` (origin/${target.branch})` : ""}`;
      try {
        const res = await callTool("remove_worktree", {
          path: item.path,
          backupCommitFirst,
          moveToTrash: item.isMissing ? false : moveToTrash,
          deleteLocalBranch: deleteLocalBranch && item.canDeleteLocalBranch,
          ...(target ? { originDeletionTarget: target } : {}),
          force: false,
          skipRescan: true,
        });
        if (res.isError) {
          const msg = (res.structuredContent?.error as string) ?? res.content?.[0]?.text ?? "Remove failed";
          errors.push(`${label}: ${msg}`);
          continue;
        }
        completed++;
        if (target) absentOriginBranches++;
        state.checkedIds.delete(item.id);
      } catch (err) {
        errors.push(`${label}: ${tr("未能确认操作结果", "Outcome unconfirmed")} · ${String(err)}`);
      }
    }
    const summary = tr(`${completed}/${m.items.length} 项清理完成`, `${completed}/${m.items.length} removals completed`)
      + (absentOriginBranches ? tr(`，${absentOriginBranches} 个目标分支已不在 origin 上`, `. ${absentOriginBranches} target branch(es) absent from origin`) : "");
    if (errors.length > 0) {
      m.completed = true;
      m.error = [summary, ...errors].join("\n");
    } else {
      state.modal = null;
      showToast(summary);
    }
    const scanRes = await callTool("scan_worktrees", { includeDiskSizes: true });
    if (scanRes.isError) throw new Error(scanRes.content?.[0]?.text ?? "Scan failed");
    applyScanPayload(scanRes.structuredContent);
  } catch (err) {
    showToast(tr(`扫描刷新失败：${err}`, `Could not refresh scan: ${err}`), true);
  } finally {
    state.busy = false;
    render();
  }
}

function buildContextMarkdown(items: WorktreeItemDTO[]): string {
  const sections = items.map((item) => {
    const lines: string[] = [
      `### Worktree: ${item.mainRepoName} · ${item.displayBranch}`,
      `- Path: \`${item.path}\``,
      `- Safety: \`${item.safetyLevel}\` (${state.zh ? item.safetySummaryZh : item.safetySummaryEn})`,
      `- Source: ${item.source} · Size: ${item.formattedSize}${item.reclaimableCacheBytes > 0 ? ` (cache: ${item.formattedCacheSize})` : ""}`,
    ];
    if (item.pr) {
      lines.push(`- PR: #${item.pr.number} (${item.pr.state}) ${item.pr.url}`);
    }
    if (item.activeProcesses.length > 0) {
      lines.push(`- Active processes: ${item.activeProcesses.join(", ")}`);
    }
    if (item.preciousIgnoredFiles.length > 0) {
      lines.push(`- Precious ignored files: ${item.preciousIgnoredFiles.join(", ")}`);
    }
    if (item.featureSummary?.agentTasks.length) {
      lines.push(`- Agent tasks: ${item.featureSummary.agentTasks.join(" | ")}`);
    }
    if (item.changedFiles.length > 0) {
      const files = item.changedFiles.slice(0, 15).map((f) => `${f.code} ${f.path}`).join(", ");
      lines.push(`- Uncommitted files (${item.modifiedCount + item.untrackedCount}): ${files}`);
    }
    if (item.unpushedCommits.length > 0) {
      const commits = item.unpushedCommits.slice(0, 8).map((c) => `${c.hash} ${c.message}`).join("; ");
      lines.push(`- Unpushed commits (${item.aheadCount}): ${commits}`);
    }
    return lines.join("\n");
  });

  return [
    `[Worktree Cleaner Context — ${items.length} worktree(s) attached for review; destructive actions are UI-confirmed only]`,
    ...sections,
  ].join("\n\n");
}

async function handleAttachContext(items: WorktreeItemDTO[]): Promise<void> {
  if (!state.canUpdateContext || items.length === 0) return;
  try {
    const markdown = buildContextMarkdown(items);
    await app.updateModelContext({
      content: [{ type: "text", text: markdown }],
    });
    state.attachedIds = new Set(items.map((i) => i.id));
    render();
    showToast(
      items.length === 1
        ? tr("已附带到聊天框上下文，可直接提问", "Attached to chat context")
        : tr(`已将 ${items.length} 项附带到聊天框上下文`, `Attached ${items.length} items to chat context`)
    );
  } catch (err) {
    showToast(String(err), true);
  }
}

async function handleAskAgent(item: WorktreeItemDTO): Promise<void> {
  if (!state.canMessage) return;
  const prompt = state.zh
    ? `请帮我检查这个 Git Worktree（${item.mainRepoName} · ${item.displayBranch}，路径 ${item.path}），总结改动是否已经合并或值得保留，再给我处理建议。`
    : `Please inspect the Git worktree "${item.mainRepoName} · ${item.displayBranch}" at ${item.path}, summarize whether its changes are worth keeping or already merged, and advise next steps.`;
  try {
    await app.sendMessage({ role: "user", content: [{ type: "text", text: prompt }] });
    showToast(tr("已发送给当前对话 Agent", "Sent to active conversation"));
  } catch (err) {
    showToast(String(err), true);
  }
}

function render(): void {
  const root = document.getElementById("root");
  if (!root) return;

  const summary = state.payload?.summary;
  const visible = filteredItems();
  const current = selectedItem();

  // 按主仓库分组，Orphaned 放最后
  const groupsMap = new Map<string, WorktreeItemDTO[]>();
  for (const item of visible) {
    const key = item.mainRepoName || "Orphaned";
    const list = groupsMap.get(key) ?? [];
    list.push(item);
    groupsMap.set(key, list);
  }
  const groupKeys = Array.from(groupsMap.keys()).sort((a, b) => {
    if (a === "Orphaned") return 1;
    if (b === "Orphaned") return -1;
    return a.localeCompare(b);
  });

  const totalCount = Math.max(summary?.totalCount ?? 0, 1);
  const segWidths = summary
    ? {
        safe: (summary.safeCount / totalCount) * 100,
        caution: (summary.cautionCount / totalCount) * 100,
        danger: (summary.dangerCount / totalCount) * 100,
        missing: (summary.missingCount / totalCount) * 100,
      }
    : { safe: 0, caution: 0, danger: 0, missing: 0 };

  const filters: { key: "all" | SafetyKey; label: string; count: number; dot?: string }[] = [
    { key: "all", label: tr("全部", "All"), count: summary?.totalCount ?? 0 },
    { key: "safe", label: tr("安全", "Safe"), count: summary?.safeCount ?? 0, dot: "dot-safe" },
    { key: "caution", label: tr("待确认", "Review"), count: summary?.cautionCount ?? 0, dot: "dot-caution" },
    { key: "danger", label: tr("有改动", "Active"), count: summary?.dangerCount ?? 0, dot: "dot-danger" },
    { key: "missing", label: tr("幽灵", "Ghost"), count: summary?.missingCount ?? 0, dot: "dot-missing" },
  ];

  if (state.displayMode === "inline") {
    root.innerHTML = renderInlineShell(summary, visible, segWidths, filters);
    bindEvents();
    return;
  }

  root.innerHTML = `
    <div class="app-shell">
      <header class="topbar">
        <div class="topbar-left">
          <span class="brand-mark">
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
              <path d="M4.6 3.5V12.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>
              <path d="M4.6 10.6C4.6 7.4 11.4 8.8 11.4 5.4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>
              <circle cx="4.6" cy="3.1" r="1.8" fill="currentColor"/>
              <circle cx="4.6" cy="12.9" r="1.8" fill="currentColor"/>
              <circle cx="11.4" cy="4.9" r="1.8" fill="currentColor"/>
            </svg>
            Worktree Cleaner
          </span>
          ${
            summary
              ? `<span class="reclaim-figure num">${esc(summary.formattedReclaimable)}</span>
                 <span class="reclaim-sub num">${tr(`${summary.safeCount + summary.missingCount} 项可安全释放 · 共 ${summary.totalCount} 项`, `${summary.safeCount + summary.missingCount} safe · ${summary.totalCount} total`)}</span>`
              : `<span class="reclaim-sub">${tr("正在扫描…", "Scanning…")}</span>`
          }
        </div>
        <div class="topbar-actions">
          ${
            (summary?.missingCount ?? 0) > 0
              ? `<button class="btn" id="btn-prune" ${state.busy ? "disabled" : ""}>${tr(`清幽灵 (${summary!.missingCount})`, `Prune (${summary!.missingCount})`)}</button>`
              : ""
          }
          <button class="btn btn-ghost" id="btn-lang">${state.zh ? "EN" : "中"}</button>
          <button class="btn btn-icon" id="btn-refresh" title="${tr("重新扫描", "Rescan")}" ${state.busy ? "disabled" : ""}>↻</button>
        </div>
      </header>

      <div class="workspace">
        <aside class="sidebar">
          <div class="sidebar-controls">
            <input
              id="search-box"
              class="search-input"
              type="text"
              value="${esc(state.search)}"
              placeholder="${tr("搜索分支、仓库或任务…", "Search branch, repo, or task…")}"
            />
            ${
              summary && summary.totalCount > 0
                ? `<div class="seg-bar">
                    ${segWidths.safe > 0 ? `<div style="width:${segWidths.safe}%;background:var(--dot-safe)"></div>` : ""}
                    ${segWidths.caution > 0 ? `<div style="width:${segWidths.caution}%;background:var(--dot-caution)"></div>` : ""}
                    ${segWidths.danger > 0 ? `<div style="width:${segWidths.danger}%;background:var(--dot-danger)"></div>` : ""}
                    ${segWidths.missing > 0 ? `<div style="width:${segWidths.missing}%;background:var(--dot-missing)"></div>` : ""}
                  </div>`
                : ""
            }
            <div class="filter-row">
              ${filters
                .map(
                  (f) => `
                <button class="filter-pill ${state.filter === f.key ? "active" : ""}" data-filter="${f.key}">
                  ${f.dot ? `<span class="dot ${f.dot}"></span>` : ""}
                  <span>${esc(f.label)}</span>
                  ${f.count > 0 ? `<span class="muted num">${f.count}</span>` : ""}
                </button>`
                )
                .join("")}
            </div>
          </div>

          <div class="list-scroll">
            ${
              state.loading
                ? `<div class="empty-state">${tr("正在扫描本机 Worktree…", "Scanning local worktrees…")}</div>`
                : groupKeys.length === 0
                  ? `<div class="empty-state">${
                      (state.payload?.items.length ?? 0) === 0
                        ? tr("没有冗余 Worktree", "No redundant worktrees")
                        : tr("无匹配结果", "No matching worktrees")
                    }</div>`
                  : groupKeys
                      .map((repo) => {
                        const list = groupsMap.get(repo)!;
                        const label = repo === "Orphaned" ? tr("孤儿残留", "Orphaned") : repo;
                        return `
                        <div class="repo-group">
                          <div class="repo-header">
                            <span>${esc(label)}</span>
                            <span class="repo-count num">${list.length}</span>
                          </div>
                          ${list
                            .map((item) => {
                              const hint = rowHint(item);
                              return `
                              <button class="wt-row ${current?.id === item.id ? "selected" : ""}" data-select="${esc(item.id)}">
                                <span class="dot dot-${item.safetyLevel}" style="margin-top:5px"></span>
                                <div class="wt-row-body">
                                  <div class="wt-row-top">
                                    <span class="wt-branch">${esc(item.displayBranch)}</span>
                                    <span class="wt-size num">${esc(item.formattedSize)}</span>
                                  </div>
                                  <div class="wt-sub">${esc(hint)}</div>
                                </div>
                              </button>`;
                            })
                            .join("")}
                        </div>`;
                      })
                      .join("")
            }
          </div>
        </aside>

        <main class="detail-pane">
          ${current ? renderDetail(current) : `<div class="empty-state">${tr("选择左侧 Worktree 查看体检详情", "Select a worktree to inspect")}</div>`}
        </main>
      </div>

      ${state.toast ? `<div class="toast"><span class="dot ${state.toast.isError ? "dot-danger" : "dot-safe"}"></span><span>${esc(state.toast.message)}</span></div>` : ""}
      ${renderModal()}
    </div>
  `;

  bindEvents();
}

function renderInlineShell(
  summary: ScanPayload["summary"] | undefined,
  visible: WorktreeItemDTO[],
  segWidths: { safe: number; caution: number; danger: number; missing: number },
  filters: { key: "all" | SafetyKey; label: string; count: number; dot?: string }[]
): string {
  const allItems = state.payload?.items ?? [];
  const inspected = state.inlineInspectId
    ? allItems.find((i) => i.id === state.inlineInspectId) ?? null
    : null;
  const checkedItems = allItems.filter((i) => state.checkedIds.has(i.id));
  const checkedBytes = checkedItems.reduce((acc, i) => acc + i.diskSizeBytes, 0);
  const safeSelectableCount = visible.filter((i) => i.safetyLevel === "safe" || i.safetyLevel === "missing").length;
  const hasDangerChecked = checkedItems.some((i) => i.safetyLevel === "danger");

  return `
    <div class="app-shell mode-inline">
      <header class="topbar">
        <div class="topbar-left">
          <span class="brand-mark">
            <svg width="15" height="15" viewBox="0 0 16 16" fill="none" aria-hidden="true">
              <path d="M4.6 3.5V12.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>
              <path d="M4.6 10.6C4.6 7.4 11.4 8.8 11.4 5.4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>
              <circle cx="4.6" cy="3.1" r="1.8" fill="currentColor"/>
              <circle cx="4.6" cy="12.9" r="1.8" fill="currentColor"/>
              <circle cx="11.4" cy="4.9" r="1.8" fill="currentColor"/>
            </svg>
            Worktree Cleaner
          </span>
          ${
            summary
              ? `<span class="reclaim-figure num">${esc(summary.formattedReclaimable)}</span>
                 <span class="reclaim-sub num">${tr(`${summary.safeCount + summary.missingCount} 可清 · 共 ${summary.totalCount} 项`, `${summary.safeCount + summary.missingCount} safe · ${summary.totalCount} total`)}</span>`
              : `<span class="reclaim-sub">${tr("正在扫描…", "Scanning…")}</span>`
          }
        </div>
        <div class="topbar-actions">
          ${
            !inspected && safeSelectableCount > 0
              ? `<button class="btn btn-xs" id="btn-select-safe" ${state.busy ? "disabled" : ""}>${tr("全选安全项", "Select Safe")}</button>`
              : ""
          }
          ${
            (summary?.missingCount ?? 0) > 0
              ? `<button class="btn btn-xs" id="btn-prune" ${state.busy ? "disabled" : ""}>${tr(`清幽灵 (${summary!.missingCount})`, `Prune (${summary!.missingCount})`)}</button>`
              : ""
          }
          <button class="btn btn-ghost btn-xs" id="btn-lang">${state.zh ? "EN" : "中"}</button>
          <button class="btn btn-icon btn-xs" id="btn-refresh" title="${tr("重新扫描", "Rescan")}" ${state.busy ? "disabled" : ""}>↻</button>
        </div>
      </header>

      ${
        inspected
          ? `
        <div class="inline-back-bar">
          <button class="btn btn-ghost btn-xs" id="btn-inline-back">← ${tr("返回列表", "Back to List")}</button>
          <span class="muted num">${esc(inspected.mainRepoName)} · ${esc(inspected.formattedSize)}</span>
        </div>
        <div class="inline-detail-wrap">
          ${renderDetail(inspected)}
        </div>
      `
          : `
        <div class="inline-controls">
          ${
            summary && summary.totalCount > 0
              ? `<div class="seg-bar">
                  ${segWidths.safe > 0 ? `<div style="width:${segWidths.safe}%;background:var(--dot-safe)"></div>` : ""}
                  ${segWidths.caution > 0 ? `<div style="width:${segWidths.caution}%;background:var(--dot-caution)"></div>` : ""}
                  ${segWidths.danger > 0 ? `<div style="width:${segWidths.danger}%;background:var(--dot-danger)"></div>` : ""}
                  ${segWidths.missing > 0 ? `<div style="width:${segWidths.missing}%;background:var(--dot-missing)"></div>` : ""}
                </div>`
              : ""
          }
          <div class="filter-row">
            ${filters
              .map(
                (f) => `
              <button class="filter-pill ${state.filter === f.key ? "active" : ""}" data-filter="${f.key}">
                ${f.dot ? `<span class="dot ${f.dot}"></span>` : ""}
                <span>${esc(f.label)}</span>
                ${f.count > 0 ? `<span class="muted num">${f.count}</span>` : ""}
              </button>`
              )
              .join("")}
          </div>
        </div>

        <div class="inline-list">
          ${
            state.loading
              ? `<div class="empty-state">${tr("正在扫描本机 Worktree…", "Scanning local worktrees…")}</div>`
              : visible.length === 0
                ? `<div class="empty-state">${
                    allItems.length === 0
                      ? tr("没有冗余 Worktree", "No redundant worktrees")
                      : tr("无匹配结果", "No matching worktrees")
                  }</div>`
                : visible
                    .map((item) => {
                      const checked = state.checkedIds.has(item.id);
                      const attached = state.attachedIds.has(item.id);
                      const hint = rowHint(item);
                      return `
                      <div class="inline-row ${checked ? "is-checked" : ""}">
                        <input
                          class="inline-check"
                          type="checkbox"
                          data-check="${esc(item.id)}"
                          ${checked ? "checked" : ""}
                          aria-label="${esc(item.displayBranch)}"
                        />
                        <span class="dot dot-${item.safetyLevel}"></span>
                        <div class="inline-row-main" data-inspect="${esc(item.id)}">
                          <div class="inline-row-title">
                            <span class="inline-repo">${esc(item.isOrphan ? tr("孤儿", "Orphan") : item.mainRepoName)}</span>
                            <span class="wt-branch">${esc(item.displayBranch)}</span>
                          </div>
                          <div class="wt-sub">${esc(hint)}</div>
                        </div>
                        <span class="wt-size num">${esc(item.formattedSize)}</span>
                        <div class="inline-row-actions">
                          ${
                            state.canUpdateContext
                              ? `<button class="btn btn-ghost btn-xs ${attached ? "btn-attached" : ""}" data-attach-one="${esc(item.id)}" title="${tr("附带到聊天框上下文", "Attach to chat context")}">${attached ? tr("已附带", "Attached") : tr("附带", "Attach")}</button>`
                              : ""
                          }
                          <button class="btn btn-ghost btn-xs" data-inspect="${esc(item.id)}">${tr("详情", "Inspect")}</button>
                        </div>
                      </div>`;
                    })
                    .join("")
          }
        </div>

        ${
          checkedItems.length > 0
            ? `
          <div class="inline-footer">
            <div class="action-group">
              <span class="reclaim-figure num">${tr(`已选 ${checkedItems.length} 项 · ${formatBytes(checkedBytes)}`, `${checkedItems.length} selected · ${formatBytes(checkedBytes)}`)}</span>
              <button class="btn btn-ghost btn-xs" id="btn-clear-checks">${tr("取消", "Clear")}</button>
            </div>
            <div class="action-group">
              ${
                state.canUpdateContext
                  ? `<button class="btn btn-xs" id="btn-attach-checked">${tr("附带到对话", "Attach to Chat")}</button>`
                  : ""
              }
              <button class="btn btn-xs ${hasDangerChecked ? "btn-danger" : "btn-primary"}" id="btn-batch-remove" ${state.busy ? "disabled" : ""}>
                ${tr(`移入废纸篓 (${checkedItems.length})`, `Move to Trash (${checkedItems.length})`)}
              </button>
            </div>
          </div>`
            : ""
        }
      `
      }

      ${state.toast ? `<div class="toast"><span class="dot ${state.toast.isError ? "dot-danger" : "dot-safe"}"></span><span>${esc(state.toast.message)}</span></div>` : ""}
      ${renderModal()}
    </div>
  `;
}

function renderDetail(item: WorktreeItemDTO): string {
  const summaryText = state.zh ? item.safetySummaryZh : item.safetySummaryEn;
  const fs = item.featureSummary;

  return `
    <div class="detail-scroll">
      <div class="detail-hero">
        <div style="min-width:0">
          <div class="detail-meta-row">
            <span>${esc(item.isOrphan ? tr("孤儿目录", "Orphaned") : item.mainRepoName)}</span>
            <span>·</span>
            <span>${esc(item.source)}</span>
            ${
              item.pr
                ? `<span>·</span>
                   <button class="pr-link" id="btn-open-pr" data-url="${esc(item.pr.url)}">
                     <span class="dot" style="background:${item.pr.state === "MERGED" ? "var(--dot-pr-merged)" : "var(--dot-safe)"}"></span>
                     PR #${item.pr.number} ${esc(item.pr.state)}
                   </button>`
                : ""
            }
            ${item.isLocked ? `<span>· Locked</span>` : ""}
          </div>
          <div class="detail-title">${esc(item.displayBranch)}</div>
        </div>
        <div class="detail-size num">${esc(item.formattedSize)}</div>
      </div>

      <div class="card card-pad">
        <div class="safety-row">
          <span class="dot dot-${item.safetyLevel}"></span>
          <span class="safety-label">${esc(safetyLabel(item.safetyLevel))}</span>
          <span class="safety-desc">${esc(summaryText)}</span>
        </div>
      </div>

      ${
        item.preciousIgnoredFiles.length > 0
          ? `
        <div class="section">
          <div class="section-head">
            <span>${tr("本地忽略孤本文件", "Precious Ignored Files")}</span>
            ${item.mainRepoPath ? `<button class="btn btn-ghost" id="btn-copy-precious" style="height:22px;font-size:11.5px">${tr("拷回主仓库", "Copy to Main Repo")}</button>` : ""}
          </div>
          <div class="card">
            ${item.preciousIgnoredFiles
              .map(
                (f) => `<div class="list-item"><span class="dot dot-caution"></span><span class="mono ellipsis">${esc(f)}</span></div>`
              )
              .join("")}
          </div>
        </div>`
          : ""
      }

      ${
        fs
          ? `
        <div class="section">
          <div class="section-head">
            <span>${tr("做了什么", "What Changed")}${fs.baseBranch ? ` <span class="muted">${tr(`相对 ${fs.baseBranch}`, `vs ${fs.baseBranch}`)}</span>` : ""}</span>
            ${
              fs.totalCommitCount > 0 || fs.filesChangedCount > 0
                ? `<span class="mono muted">${fs.totalCommitCount} commits · ${fs.filesChangedCount} files · +${fs.insertions} / -${fs.deletions}</span>`
                : ""
            }
          </div>
          <div class="card">
            ${fs.agentTasks.map((t) => `<div class="task-item"><span>✦</span><span>${esc(t)}</span></div>`).join("")}
            ${
              fs.touchedAreas.length > 0
                ? `<div class="area-chips">${fs.touchedAreas.map((a) => `<span class="area-chip">${esc(a)}</span>`).join("")}</div>`
                : ""
            }
            ${
              fs.branchCommits.length > 0
                ? fs.branchCommits
                    .map(
                      (c) => `
                    <div class="list-item">
                      <span class="commit-hash">${esc(c.hash)}</span>
                      <span class="ellipsis">${esc(c.subject)}</span>
                      <span class="muted">${esc(c.relativeDate)}</span>
                    </div>`
                    )
                    .join("")
                : fs.agentTasks.length === 0
                  ? `<div class="list-item"><span class="muted">${esc(item.headSubject || tr("无新增提交", "No commits ahead"))}</span></div>`
                  : ""
            }
          </div>
        </div>`
          : ""
      }

      ${
        item.changedFiles.length > 0
          ? `
        <div class="section">
          <div class="section-head">
            <span>${tr(`未提交改动 (${item.modifiedCount + item.untrackedCount})`, `Uncommitted Changes (${item.modifiedCount + item.untrackedCount})`)}</span>
            <button class="btn btn-ghost" id="btn-view-diff" style="height:22px;font-size:11.5px">${tr("查看 Diff", "View Diff")}</button>
          </div>
          <div class="card">
            ${item.changedFiles
              .map(
                (f) => `<div class="list-item"><span class="code-badge">${esc(f.code)}</span><span class="mono ellipsis">${esc(f.path)}</span></div>`
              )
              .join("")}
          </div>
        </div>`
          : ""
      }

      ${
        item.unpushedCommits.length > 0
          ? `
        <div class="section">
          <div class="section-head"><span>${tr(`未推送提交 (${item.aheadCount})`, `Unpushed Commits (${item.aheadCount})`)}</span></div>
          <div class="card">
            ${item.unpushedCommits
              .map(
                (c) => `<div class="list-item"><span class="commit-hash">${esc(c.hash)}</span><span class="ellipsis">${esc(c.message)}</span></div>`
              )
              .join("")}
          </div>
        </div>`
          : ""
      }

      <div class="section">
        <div class="card">
          ${
            item.mainRepoPath
              ? `<div class="list-item"><span class="muted" style="min-width:54px">${tr("主仓库", "Main Repo")}</span><span class="mono ellipsis" style="font-size:11px;color:var(--text-secondary)">${esc(item.mainRepoPath)}</span></div>`
              : ""
          }
          <div class="list-item"><span class="muted" style="min-width:54px">${tr("路径", "Path")}</span><span class="mono ellipsis" style="font-size:11px;color:var(--text-secondary)">${esc(item.path)}</span></div>
        </div>
      </div>
    </div>

    <div class="action-bar">
      <div class="action-group">
        ${item.directoryExists ? `<button class="btn" id="btn-finder">Finder</button>` : ""}
        ${
          state.canUpdateContext
            ? `<button class="btn ${state.attachedIds.has(item.id) ? "btn-attached" : ""}" id="btn-attach-context">${state.attachedIds.has(item.id) ? tr("已附带到对话", "Attached") : tr("附带到对话", "Attach to Chat")}</button>`
            : ""
        }
        ${state.canMessage ? `<button class="btn" id="btn-ask-agent">${tr("让 Agent 审查", "Ask Agent")}</button>` : ""}
      </div>
      <div class="action-group">
        ${
          item.reclaimableCacheBytes >= 10 * 1024 * 1024
            ? `<button class="btn" id="btn-slim" ${state.busy ? "disabled" : ""}>${tr(`清缓存 ${item.formattedCacheSize}`, `Slim ${item.formattedCacheSize}`)}</button>`
            : ""
        }
        ${
          item.canPush
            ? `<button class="btn" id="btn-push" ${state.busy ? "disabled" : ""}>${item.isDirty ? tr("提交并推送", "Commit & Push") : tr("推送", "Push")}</button>`
            : ""
        }
        <button class="btn ${item.safetyLevel === "danger" ? "btn-danger" : "btn-primary"}" id="btn-remove" ${state.busy ? "disabled" : ""}>
          ${item.isMissing ? tr("清理幽灵", "Prune") : tr("移除", "Remove")}
        </button>
      </div>
    </div>
  `;
}

function originDeletionOption(items: WorktreeItemDTO[], enabled: boolean): string {
  const targets = items.flatMap(item => item.originDeletionTarget ? [item.originDeletionTarget] : []);
  if (!targets.length) return "";

  const label = targets.length === 1
    ? tr(`同时删除远端分支 origin/${targets[0].branch}`, `Also delete remote branch origin/${targets[0].branch}`)
    : tr(`同时删除以下 ${targets.length} 个远端分支`, `Also delete these ${targets.length} remote branches`);
  return `<div class="origin-delete-option">
    <label class="check-row">
      <input id="rm-origin" type="checkbox" ${enabled ? "checked" : ""} ${state.busy ? "disabled" : ""} />
      <span>${esc(label)}</span>
    </label>
    <ul class="origin-target-list">${targets.map(target =>
      `<li>${items.length > 1 ? `<strong class="mono">origin/${esc(target.branch)}</strong><br>` : ""}${esc(target.mainRepoPath)} · <span class="mono">${esc(target.localBranch)} @ ${esc(target.headCommit.slice(0, 10))}</span></li>`
    ).join("")}</ul>
    <div class="field-label">${tr("远端分支不会进入 macOS 废纸篓。", "Remote branches do not go to the macOS Trash.")}</div>
  </div>`;
}

function renderModal(): string {
  const m = state.modal;
  if (!m) return "";

  if (m.type === "diff") {
    return `
      <div class="modal-backdrop" id="modal-backdrop">
        <div class="modal modal-wide">
          <div class="modal-head">
            <span>${esc(m.title)} — Diff</span>
            <button class="btn btn-icon" id="modal-close">✕</button>
          </div>
          <div class="modal-body">
            ${m.loading ? `<div class="muted">${tr("正在读取 Diff…", "Loading diff…")}</div>` : `<pre class="diff-pre">${esc(m.text)}</pre>`}
          </div>
        </div>
      </div>`;
  }

  if (m.type === "push") {
    return `
      <div class="modal-backdrop" id="modal-backdrop">
        <div class="modal">
          <div class="modal-head">
            <span>${m.item.isDirty ? tr("提交并推送到远端", "Commit & Push to Remote") : tr("推送到远端", "Push to Remote")}</span>
            <button class="btn btn-icon" id="modal-close">✕</button>
          </div>
          <div class="modal-body">
            <div>
              <label class="field-label">${tr("目标远端分支", "Target Branch")} (${esc(m.item.remoteName || "origin")})</label>
              <input id="push-branch" class="field-input mono" value="${esc(m.branchName)}" />
            </div>
            ${
              m.item.isDirty
                ? `<div>
                    <label class="field-label">${tr("Commit 说明", "Commit Message")}</label>
                    <input id="push-msg" class="field-input" value="${esc(m.commitMessage)}" />
                  </div>`
                : ""
            }
            <label class="check-row">
              <input id="push-delete-after" type="checkbox" ${m.deleteAfterPush ? "checked" : ""} />
              <span>${tr("推送成功后自动移入废纸篓（推完即清）", "Move worktree to Trash after push")}</span>
            </label>
            ${m.error ? `<div class="error-box">${esc(m.error)}</div>` : ""}
          </div>
          <div class="modal-foot">
            <button class="btn" id="modal-close-btn" ${state.busy ? "disabled" : ""}>${tr("取消", "Cancel")}</button>
            <button class="btn btn-primary" id="btn-confirm-push" ${state.busy ? "disabled" : ""}>${state.busy ? tr("推送中…", "Pushing…") : tr("立即推送", "Push")}</button>
          </div>
        </div>
      </div>`;
  }

  if (m.type === "batch-remove") {
    if (m.completed) {
      return `<div class="modal-backdrop" id="modal-backdrop"><div class="modal">
        <div class="modal-head">${tr("清理结果", "Removal results")}</div>
        <div class="modal-body"><div class="error-box">${esc(m.error ?? "")}</div></div>
        <div class="modal-foot"><button class="btn" id="modal-close-btn" ${state.busy ? "disabled" : ""}>${tr("关闭", "Close")}</button></div>
      </div></div>`;
    }
    const totalBytes = m.items.reduce((acc, i) => acc + i.diskSizeBytes, 0);
    const hasDirty = m.items.some((i) => i.isDirty);
    const hasDeletableBranch = m.items.some((i) => i.canDeleteLocalBranch);
    const hasDanger = m.items.some((i) => i.safetyLevel === "danger");
    return `
      <div class="modal-backdrop" id="modal-backdrop">
        <div class="modal">
          <div class="modal-head">
            <span>${tr(`确认清理 ${m.items.length} 项 Worktree`, `Remove ${m.items.length} Worktrees`)}</span>
            <button class="btn btn-icon" id="modal-close">✕</button>
          </div>
          <div class="modal-body">
            <div style="font-size:12.5px;font-weight:500">${tr(`共释放约 ${formatBytes(totalBytes)}`, `Reclaims ~${formatBytes(totalBytes)}`)}</div>
            <div class="card">
              ${m.items
                .slice(0, 8)
                .map(
                  (it) =>
                    `<div class="list-item"><span class="dot dot-${it.safetyLevel}"></span><span class="ellipsis">${esc(it.mainRepoName)} · ${esc(it.displayBranch)}</span><span class="muted num">${esc(it.formattedSize)}</span></div>`
                )
                .join("")}
              ${
                m.items.length > 8
                  ? `<div class="list-item"><span class="muted">${tr(`其余 ${m.items.length - 8} 项…`, `and ${m.items.length - 8} more…`)}</span></div>`
                  : ""
              }
            </div>
            <label class="check-row">
              <input id="brm-trash" type="checkbox" ${m.moveToTrash ? "checked" : ""} />
              <span>${tr("移入 macOS 废纸篓（可随时还原）", "Move to macOS Trash (recoverable)")}</span>
            </label>
            ${
              hasDirty
                ? `<label class="check-row">
                    <input id="brm-backup" type="checkbox" ${m.backupCommitFirst ? "checked" : ""} />
                    <span>${tr("对未提交改动先自动 Commit 备份", "Auto-commit uncommitted changes before removal")}</span>
                  </label>`
                : ""
            }
            ${
              hasDeletableBranch
                ? `<label class="check-row">
                    <input id="brm-branch" type="checkbox" ${m.deleteLocalBranch ? "checked" : ""} />
                    <span>${tr("同时删除对应的本地分支", "Also delete matching local branches")}</span>
                  </label>`
                : ""
            }
            ${originDeletionOption(m.items, m.deleteOriginBranch)}
            ${m.error ? `<div class="error-box">${esc(m.error)}</div>` : ""}
          </div>
          <div class="modal-foot">
            <button class="btn" id="modal-close-btn" ${state.busy ? "disabled" : ""}>${tr("取消", "Cancel")}</button>
            <button class="btn ${hasDanger || m.deleteOriginBranch ? "btn-danger" : "btn-primary"}" id="btn-confirm-batch-remove" ${state.busy ? "disabled" : ""}>
              ${state.busy ? tr("处理中…", "Removing…") : m.deleteOriginBranch ? tr("移除并删除远端分支", "Remove & delete remote branches") : m.moveToTrash ? tr(`移入废纸篓 (${m.items.length})`, `Move to Trash (${m.items.length})`) : tr(`确认移除 (${m.items.length})`, `Remove (${m.items.length})`)}
            </button>
          </div>
        </div>
      </div>`;
  }

  return `
    <div class="modal-backdrop" id="modal-backdrop">
      <div class="modal">
        <div class="modal-head">
          <span>${tr("确认移除 Worktree", "Remove Worktree")}</span>
          <button class="btn btn-icon" id="modal-close">✕</button>
        </div>
        <div class="modal-body">
          <div style="font-size:12.5px;font-weight:500">${esc(m.item.mainRepoName)} · ${esc(m.item.displayBranch)} (${esc(m.item.formattedSize)})</div>
          <div style="font-size:12px;color:var(--text-secondary)">${esc(state.zh ? m.item.safetySummaryZh : m.item.safetySummaryEn)}</div>
          ${
            !m.item.isMissing
              ? `<label class="check-row">
                  <input id="rm-trash" type="checkbox" ${m.moveToTrash ? "checked" : ""} />
                  <span>${tr("移入 macOS 废纸篓（可随时还原）", "Move to macOS Trash (recoverable)")}</span>
                </label>`
              : ""
          }
          ${
            m.item.isDirty
              ? `<label class="check-row">
                  <input id="rm-backup" type="checkbox" ${m.backupCommitFirst ? "checked" : ""} />
                  <span>${tr("移除前先自动 Commit 备份改动", "Auto-commit uncommitted changes before removal")}</span>
                </label>`
              : ""
          }
          ${
            m.item.canDeleteLocalBranch
              ? `<label class="check-row">
                  <input id="rm-branch" type="checkbox" ${m.deleteLocalBranch ? "checked" : ""} />
                  <span>${tr("同时删除对应的本地分支", "Also delete matching local branch")}</span>
                </label>`
              : ""
          }
          ${
            m.item.activeProcesses.length > 0
              ? `<label class="check-row">
                  <input id="rm-force" type="checkbox" ${m.force ? "checked" : ""} />
                  <span>${tr("忽略运行中进程警告并强制移除", "Ignore active processes and force removal")}</span>
                </label>`
              : ""
          }
          ${originDeletionOption([m.item], m.deleteOriginBranch)}
          ${m.error ? `<div class="error-box">${esc(m.error)}</div>` : ""}
        </div>
        <div class="modal-foot">
          <button class="btn" id="modal-close-btn" ${state.busy ? "disabled" : ""}>${tr("取消", "Cancel")}</button>
          <button class="btn ${m.item.safetyLevel === "danger" || m.deleteOriginBranch ? "btn-danger" : "btn-primary"}" id="btn-confirm-remove" ${state.busy ? "disabled" : ""}>
            ${state.busy ? tr("处理中…", "Removing…") : m.deleteOriginBranch ? tr("移除并删除远端分支", "Remove & delete remote branch") : m.moveToTrash ? tr("移入废纸篓", "Move to Trash") : tr("确认移除", "Remove")}
          </button>
        </div>
      </div>
    </div>`;
}

function bindEvents(): void {
  const searchEl = document.getElementById("search-box") as HTMLInputElement | null;
  if (searchEl) {
    searchEl.oninput = () => {
      const pos = searchEl.selectionStart ?? searchEl.value.length;
      state.search = searchEl.value;
      render();
      const restored = document.getElementById("search-box") as HTMLInputElement | null;
      if (restored) {
        restored.focus();
        restored.setSelectionRange(pos, pos);
      }
    };
  }

  document.getElementById("btn-refresh")?.addEventListener("click", () => void refreshScan());
  document.getElementById("btn-prune")?.addEventListener("click", () => void handlePruneGhost());
  document.getElementById("btn-lang")?.addEventListener("click", () => {
    state.zh = !state.zh;
    render();
  });

  document.querySelectorAll<HTMLButtonElement>("[data-filter]").forEach((btn) => {
    btn.onclick = () => {
      state.filter = (btn.dataset.filter ?? "all") as typeof state.filter;
      render();
    };
  });

  document.querySelectorAll<HTMLButtonElement>("[data-select]").forEach((btn) => {
    btn.onclick = () => {
      state.selectedId = btn.dataset.select ?? null;
      render();
    };
  });

  // 内联卡片复选框、详情切换与单条/批量附带上下文
  document.querySelectorAll<HTMLInputElement>("[data-check]").forEach((box) => {
    box.onchange = () => {
      const id = box.dataset.check;
      if (!id) return;
      if (box.checked) state.checkedIds.add(id);
      else state.checkedIds.delete(id);
      render();
    };
  });

  document.querySelectorAll<HTMLElement>("[data-inspect]").forEach((el) => {
    el.onclick = () => {
      const id = el.dataset.inspect;
      if (!id) return;
      state.inlineInspectId = id;
      state.selectedId = id;
      render();
    };
  });

  document.querySelectorAll<HTMLButtonElement>("[data-attach-one]").forEach((btn) => {
    btn.onclick = () => {
      const id = btn.dataset.attachOne;
      const target = state.payload?.items.find((i) => i.id === id);
      if (target) void handleAttachContext([target]);
    };
  });

  document.getElementById("btn-inline-back")?.addEventListener("click", () => {
    state.inlineInspectId = null;
    render();
  });

  document.getElementById("btn-select-safe")?.addEventListener("click", () => {
    for (const it of filteredItems()) {
      if (it.safetyLevel === "safe" || it.safetyLevel === "missing") {
        state.checkedIds.add(it.id);
      }
    }
    render();
  });

  document.getElementById("btn-clear-checks")?.addEventListener("click", () => {
    state.checkedIds.clear();
    render();
  });

  document.getElementById("btn-attach-checked")?.addEventListener("click", () => {
    const items = (state.payload?.items ?? []).filter((i) => state.checkedIds.has(i.id));
    void handleAttachContext(items);
  });

  document.getElementById("btn-batch-remove")?.addEventListener("click", () => {
    const items = (state.payload?.items ?? []).filter((i) => state.checkedIds.has(i.id));
    if (items.length === 0) return;
    state.modal = {
      type: "batch-remove",
      items,
      moveToTrash: true,
      backupCommitFirst: true,
      deleteLocalBranch: false,
      deleteOriginBranch: false,
      completed: false,
      error: null,
    };
    render();
  });

  const item =
    state.displayMode === "inline" && state.inlineInspectId
      ? state.payload?.items.find((i) => i.id === state.inlineInspectId) ?? null
      : selectedItem();
  if (item) {
    document.getElementById("btn-finder")?.addEventListener("click", () => {
      void callTool("open_in_finder", { path: item.path });
    });
    document.getElementById("btn-attach-context")?.addEventListener("click", () => void handleAttachContext([item]));
    document.getElementById("btn-ask-agent")?.addEventListener("click", () => void handleAskAgent(item));
    document.getElementById("btn-slim")?.addEventListener("click", () => void handleSlimCaches(item));
    document.getElementById("btn-copy-precious")?.addEventListener("click", () => void handleCopyPrecious(item));
    document.getElementById("btn-view-diff")?.addEventListener("click", () => void handleOpenDiff(item));
    document.getElementById("btn-open-pr")?.addEventListener("click", (ev) => {
      const url = (ev.currentTarget as HTMLElement).dataset.url;
      if (url && state.canOpenLinks) {
        void app.openLink({ url });
      }
    });
    document.getElementById("btn-push")?.addEventListener("click", () => {
      state.modal = {
        type: "push",
        item,
        branchName: item.suggestedPushBranchName,
        commitMessage: item.suggestedCommitMessage,
        deleteAfterPush: false,
        error: null,
      };
      render();
    });
    document.getElementById("btn-remove")?.addEventListener("click", () => {
      state.modal = {
        type: "remove",
        item,
        moveToTrash: !item.isMissing,
        backupCommitFirst: true,
        deleteLocalBranch: false,
        deleteOriginBranch: false,
        force: false,
        error: null,
      };
      render();
    });
  }

  const closeModal = () => {
    if (!state.busy) {
      state.modal = null;
      render();
    }
  };
  document.getElementById("modal-close")?.addEventListener("click", closeModal);
  document.getElementById("modal-close-btn")?.addEventListener("click", closeModal);
  document.getElementById("modal-backdrop")?.addEventListener("click", (ev) => {
    if (ev.target === ev.currentTarget) closeModal();
  });

  if (state.modal?.type === "push") {
    const m = state.modal;
    const branchEl = document.getElementById("push-branch") as HTMLInputElement | null;
    const msgEl = document.getElementById("push-msg") as HTMLInputElement | null;
    const delEl = document.getElementById("push-delete-after") as HTMLInputElement | null;
    if (branchEl) branchEl.oninput = () => (m.branchName = branchEl.value);
    if (msgEl) msgEl.oninput = () => (m.commitMessage = msgEl.value);
    if (delEl) delEl.onchange = () => (m.deleteAfterPush = delEl.checked);
    document.getElementById("btn-confirm-push")?.addEventListener("click", () => void handleExecutePush());
  }

  if (state.modal?.type === "remove" || state.modal?.type === "batch-remove") {
    const m = state.modal;
    const origin = document.getElementById("rm-origin") as HTMLInputElement | null;
    if (origin) origin.onchange = () => { m.deleteOriginBranch = origin.checked; render(); };
  }
  if (state.modal?.type === "remove") {
    const m = state.modal;
    const trashEl = document.getElementById("rm-trash") as HTMLInputElement | null;
    const backupEl = document.getElementById("rm-backup") as HTMLInputElement | null;
    const branchEl = document.getElementById("rm-branch") as HTMLInputElement | null;
    const forceEl = document.getElementById("rm-force") as HTMLInputElement | null;
    if (trashEl) trashEl.onchange = () => { m.moveToTrash = trashEl.checked; render(); };
    if (backupEl) backupEl.onchange = () => { m.backupCommitFirst = backupEl.checked; };
    if (branchEl) branchEl.onchange = () => { m.deleteLocalBranch = branchEl.checked; };
    if (forceEl) forceEl.onchange = () => { m.force = forceEl.checked; };
    document.getElementById("btn-confirm-remove")?.addEventListener("click", () => void handleExecuteRemove());
  }
  if (state.modal?.type === "batch-remove") {
    const m = state.modal;
    const trashEl = document.getElementById("brm-trash") as HTMLInputElement | null;
    const backupEl = document.getElementById("brm-backup") as HTMLInputElement | null;
    const branchEl = document.getElementById("brm-branch") as HTMLInputElement | null;
    if (trashEl) trashEl.onchange = () => { m.moveToTrash = trashEl.checked; render(); };
    if (backupEl) backupEl.onchange = () => { m.backupCommitFirst = backupEl.checked; };
    if (branchEl) branchEl.onchange = () => { m.deleteLocalBranch = branchEl.checked; };
    document.getElementById("btn-confirm-batch-remove")?.addEventListener("click", () => void handleExecuteBatchRemove());
  }
}

function applyHostContext(ctx: ReturnType<App["getHostContext"]>): void {
  if (!ctx) return;
  if (ctx.theme) {
    applyDocumentTheme(ctx.theme);
    document.documentElement.dataset.theme = ctx.theme;
  }
  if (ctx.styles?.variables) {
    applyHostStyleVariables(ctx.styles.variables);
  }
  if (ctx.locale) {
    state.zh = ctx.locale.toLowerCase().startsWith("zh");
  }
  if (ctx.displayMode === "inline" && !state.payload?.displayMode) {
    state.displayMode = "inline";
  }
}

// 必须在 connect() 之前注册所有处理器，避免错过初始 toolresult
app.ontoolinput = () => {
  if (!state.payload) {
    state.loading = true;
    render();
  }
};

app.ontoolresult = (result) => {
  const sc = (result as { structuredContent?: unknown }).structuredContent;
  if (sc) {
    applyScanPayload(sc);
  } else {
    void refreshScan();
  }
};

app.onhostcontextchanged = (ctx) => {
  applyHostContext(ctx);
  render();
};

render();

void (async () => {
  try {
    await app.connect();
    const caps = app.getHostCapabilities();
    state.canMessage = Boolean(caps?.message);
    state.canUpdateContext = Boolean(caps?.updateModelContext);
    state.canOpenLinks = Boolean(caps?.openLinks);
    applyHostContext(app.getHostContext());
    render();
  } catch (err) {
    showToast(`Connect error: ${String(err)}`, true);
  }
})();
