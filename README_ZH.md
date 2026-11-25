<div align="center">

# Worktree Cleaner

**专为 AI 编程时代打造的 macOS 原生 Liquid Glass Git Worktree 体检与安全清理工具**

*一眼看清每个 Worktree 到底做了什么，一键提交推送、只清 `node_modules` 瘦身、移入废纸篓防误删。*

[English](README.md) · [Releases](https://github.com/isdou/WorktreeCleaner/releases)

</div>

---

## 为什么做 Worktree Cleaner？

在使用 **Codex**、**Claude Code**、**Cursor**、**Trae** 并行开发几天后，电脑里往往会悄悄攒出几十个 `~/.codex/worktrees`、`.claude/worktrees`：

- 动辄吞掉 **10–50+ GB** 磁盘空间；
- 命令行里根本记不清 **这个 worktree 到底做过什么功能**、有没有藏着未备份的 `.env.local`、或者后台还有没有进程正在运行，结果完全不敢删。

**Worktree Cleaner** 把「回忆上下文 → 检查风险 → 推送或瘦身 → 移入废纸篓」做成了一款克制纯粹的 macOS 原生应用。

---

## 核心功能

- **全盘发现 + 孤儿目录物理对账**
  - 自动扫描 `~/Projects`、`~/Developer`、`~/Code`、`~/Workspace`、`~/src`、`~/Desktop`、`~/Downloads`（支持 2 层子目录）以及 `~/.codex/worktrees`、`~/.claude/worktrees`、`~/.cursor/worktrees`、`~/.trae-cn/worktrees`、`<repo>/.claude/worktrees`。
  - 主动揪出主仓库已删的**断根目录**和 Agent 目录里无 `.git` 的**空壳残骸**（`git worktree list` 扫不到的盲区）。
- **记忆唤醒：一眼看清「做了什么」**
  - 只读读取 **Codex**（`~/.codex/state_5.sqlite`）与 **Claude Code**（`~/.claude/projects/*.jsonl`）的原始任务标题与首句指令。
  - 对比默认主分支：提交数、改动模块、增删行数，支持 **`git cherry` Squash/Rebase 等价合并识别**，并可选联动本机 `gh` 显示 **GitHub PR 状态**。
- **四重防误删安全护栏**
  - **运行中进程锁**：通过 `lsof` 检测当前 `cwd` 仍落在该目录的进程并标红预警。
  - **新鲜度冷却保护**：默认 24 小时内活跃过的干净目录自动标记「近期」，不纳入「全选安全项」。
  - **敏感忽略孤本文件预警**：扫描 `.gitignore` 隐藏的 `.env*`、`secrets.json`、`.pem`、`.sqlite` 等本地重要文件，支持一键**拷回主仓库**。
  - **移入废纸篓后悔药**：默认移入 macOS 废纸篓并执行 `git worktree prune`，手滑随时可从废纸篓恢复。
- **灵活处置闭环**
  - **仅瘦身清缓存**：只将 `node_modules`、`.next`、`.build`、`target`、`DerivedData`、`.venv` 移入废纸篓，完整保留全部源码和未提交改动。
  - **一键提交并推送**：自动预填任务 Commit 说明（支持 Detached HEAD 新建分支），推完可顺手移除目录。
  - **可选清理本地分支**：移除时按需同步删除安全的本地分支（永久保护 `main`/`master`/`develop`/`prd`）。
- **正宗 macOS 原生体验**
  - 顶部菜单栏常驻悬浮卡片 + 双栏 Liquid Glass 主窗口（支持 `⌘K` 搜索、`⌘R` 刷新、`↑`/`↓` 切换、右键菜单、一键用 Cursor/VS Code/Zed/Xcode 打开、中英双语实时切换、开机自启）。

---

## 安装与构建

### 从源码编译并打包 `.app` / `.dmg`

环境要求：macOS 14+（macOS 26+ 启用完整 Liquid Glass 效果）、Xcode 16+ / Swift 6.0+：

```bash
git clone https://github.com/isdou/WorktreeCleaner.git
cd WorktreeCleaner
swift test
./scripts/build_app.sh --dmg
open dist/WorktreeCleaner.app
```

如果从 GitHub Releases 下载未公证安装包首次打开被系统拦截，可执行：

```bash
xattr -cr "/Applications/Worktree Cleaner.app"
```

---

## 开源协议

[MIT License](LICENSE)
