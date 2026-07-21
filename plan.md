# Plan: 重新创建并发布 WallpaperMac 公开 GitHub 仓库

## Goal
删除 GitHub 上确认无用的旧私有 `WallpaperMac` 仓库，重新创建同名公开仓库，并将当前 0.2.2 源代码发布到默认 `main` 分支。

## Context
- 用户已明确确认旧仓库是失败案例，应直接删除，不需要保留历史分支或迁移旧内容。
- 当前本地分支为 `codex/multi-queue-management`，最近产品整理提交为 `82ed6ee`。
- 新仓库应保留当前 GitHub Actions、Issue/PR 模板、中文文档、忽略规则和全部现有提交历史。
- README 需补充用户指定的自用 vibecoding 项目说明。

## Steps
1. 在 README 补充自用 vibecoding 项目说明，检查并提交本次发布计划，确保本地工作区干净。
2. 删除旧的私有 `MrLLLLLLLLLL/WallpaperMac` 仓库。
3. 创建新的同名公开仓库，配置为本地 `origin`。
4. 以当前本地提交创建并推送远程 `main`，再核验公开可访问性、默认分支、远程地址与提交一致性。

## Risks / Considerations
- 删除仓库会永久移除旧仓库内容、Issue、PR、Actions 记录和设置；用户已明确授权此操作。
- 创建后的仓库公开可见，必须确保 `.build/`、`dist/`、用户壁纸、日志和凭据没有进入 Git 历史。

## Verification
- `git status -sb`、`git diff --check`
- `gh repo view MrLLLLLLLLLL/WallpaperMac --json visibility,defaultBranchRef,url`
- `git ls-remote --heads origin` 与本地/远程 `main` 提交 SHA 比较
