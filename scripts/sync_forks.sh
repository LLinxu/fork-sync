#!/usr/bin/env bash
# =============================================================================
# fork-sync · 每日自动同步账号下所有 fork 仓库与上游代码
#
# 工作流程：
#   1. 通过 GitHub REST API 列出当前账号拥有（affiliation=owner）的全部 fork 仓库
#   2. 用 compare 接口把每个 fork 的默认分支与上游默认分支对比
#      （跨仓库对比语法：fork分支...上游owner:上游分支，同一仓库网络内有效）
#   3. 落后（behind）时调用官方 merge-upstream 接口执行同步
#      （即 GitHub 网页端「Sync fork」按钮背后的 API）
#   4. 汇总报告写入 GITHUB_STEP_SUMMARY；仅当出现真实错误时以非零码退出
#
# 环境变量：
#   GH_TOKEN    必填  具有 repo 权限的 GitHub PAT（仓库 Secret：FORK_SYNC_PAT）
#   DRY_RUN     可选  true 时只对比不合并（演练模式）
#   KEEPALIVE   可选  false 时跳过 60 天保活提交（默认开启）
#
# 依赖：gh CLI（GitHub Actions ubuntu-latest 运行器自带）+ bash + git
# =============================================================================

set -uo pipefail

DRY_RUN="${DRY_RUN:-false}"
KEEPALIVE="${KEEPALIVE:-true}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

log() { printf '%s\n' "$*"; }
err() { printf '::error::%s\n' "$*" >&2; }

# ---------- 前置检查 ----------
if [ -z "${GH_TOKEN:-}" ]; then
  err "缺少 GH_TOKEN：请在仓库 Settings → Secrets and variables → Actions → Secrets 中配置 FORK_SYNC_PAT（需要 repo 权限的 PAT）"
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  err "未找到 gh CLI（GitHub Actions 的 ubuntu-latest 运行器已预装）"
  exit 1
fi
export GH_TOKEN

REPORT_FILE="$(mktemp)"
FORKS_FILE="$(mktemp)"
CMP_ERR_FILE="$(mktemp)"
trap 'rm -f "$REPORT_FILE" "$FORKS_FILE" "$CMP_ERR_FILE"' EXIT

# ---------- 汇总报告辅助 ----------
# report <fork> <upstream> <result> <detail>
report() {
  printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" >> "$REPORT_FILE"
}

finish_summary() {
  {
    echo "## Fork 每日同步报告"
    echo
    echo "- 执行时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- 账号：\`${LOGIN:-unknown}\`"
    if [ "$DRY_RUN" = "true" ]; then echo "- 模式：**演练模式（未执行任何合并）**"; fi
    echo
    echo "| 仓库 | 上游 | 结果 | 说明 |"
    echo "| --- | --- | --- | --- |"
    cat "$REPORT_FILE"
    echo
    echo "**合计：共 ${TOTAL} 个 fork —— 🔄 已同步 ${SYNCED} · ✅ 已最新 ${UPTODATE} · ⏭️ 跳过 ${SKIPPED} · ⚠️ 需人工 ${MANUAL} · ❌ 失败 ${FAILED}**"
    if [ "${MANUAL}" -gt 0 ]; then
      echo
      echo "> ⚠️ 标记「需人工」的 fork 与上游已分叉（本地有独立提交，无法自动合并）。"
      echo "> 处理方式：在 GitHub 网页打开该 fork 点 **Sync fork**（有冲突时需在本地解决后推送），"
      echo "> 或清理 fork 内多余提交后再交给本工作流自动同步。"
    fi
  } >> "$SUMMARY"
}

# compare_fork <fork> <fork_branch> <parent_owner> <parent_branch>
# 注意：head 只接受「上游owner:分支」格式，带仓库名（owner/repo:branch）会 404
# 输出 "status behind ahead"；连续 3 次失败返回非零（应对偶发 5xx/网络抖动），
# 最后一次错误信息留在 CMP_ERR_FILE 供报告使用
compare_fork() {
  local out=""
  local attempt
  for attempt in 1 2 3; do
    if out="$(gh api "repos/$1/compare/$2...$3:$4" \
              --jq '[.status, (.behind_by|tostring), (.ahead_by|tostring)] | @tsv' 2>"$CMP_ERR_FILE")"; then
      printf '%s\n' "$out"
      return 0
    fi
    sleep 2
  done
  return 1
}

# ---------- 1. 认证并列出所有 fork ----------
if ! LOGIN="$(gh api user --jq '.login' 2>/dev/null)"; then
  err "PAT 认证失败：请确认 FORK_SYNC_PAT 有效且具有 repo 权限（classic token 勾选 repo；或 fine-grained token 授予 Contents: Read/Write 并覆盖所有仓库）"
  exit 1
fi
log "==> 当前账号：${LOGIN}"

# 先只列出 fork 的完整名：user/repos 列表接口不返回 parent/source 字段
# （实测列表里 parent 恒为 null，上游信息必须在下面逐个仓库获取）
if ! gh api "user/repos?affiliation=owner&per_page=100" --paginate \
     --jq '.[] | select(.fork == true) | .full_name' > "$FORKS_FILE" 2>/dev/null; then
  err "列出仓库失败（API 限流或网络问题），请稍后重试或查看 Actions 日志"
  exit 1
fi

TOTAL="$(grep -c . "$FORKS_FILE" || true)"
log "==> 共发现 ${TOTAL} 个 fork 仓库"

SYNCED=0; UPTODATE=0; SKIPPED=0; MANUAL=0; FAILED=0

# ---------- 2. 逐个获取上游信息、对比并同步 ----------
while IFS= read -r FORK; do
  [ -z "${FORK:-}" ] && continue
  log "--> ${FORK}"

  # 逐个获取仓库详情：只有单仓库接口才返回 parent（上游）信息
  # 注意：字段一律用 "NONE" 占位而非空串——IFS 制表符会被 read 当作空白折叠，
  # 空字段会导致后续列整体错位（本地 mock 测试实测过这个坑）
  if ! DETAIL="$(gh api "repos/$FORK" \
                 --jq '[.default_branch, (.parent.full_name // "NONE"),
                        (.parent.default_branch // "NONE"), (.archived | tostring)] | @tsv' 2>/dev/null)"; then
    FAILED=$((FAILED+1))
    report "$FORK" "-" "❌ 失败" "获取仓库详情失败（无访问权限或接口异常）"
    continue
  fi
  IFS=$'\t' read -r BRANCH PARENT PARENT_BRANCH ARCHIVED <<< "$DETAIL"
  [ -z "${BRANCH:-}" ] && BRANCH="main"

  # 上游已被删除或转为不可见
  if [ "${PARENT:-NONE}" = "NONE" ]; then
    SKIPPED=$((SKIPPED+1))
    report "$FORK" "-" "⏭️ 跳过" "未找到上游仓库（已删除或转为私有）"
    continue
  fi
  # 已归档的仓库无法推送
  if [ "${ARCHIVED:-false}" = "true" ]; then
    SKIPPED=$((SKIPPED+1))
    report "$FORK" "$PARENT" "⏭️ 跳过" "仓库已归档，无法同步"
    continue
  fi
  [ "${PARENT_BRANCH:-NONE}" = "NONE" ] && PARENT_BRANCH="$BRANCH"
  # compare 的 head 只认「上游owner:分支」，不能带仓库名（owner/repo:branch 会 404）
  PARENT_OWNER="${PARENT%%/*}"

  log "    默认分支 ${BRANCH}，上游 ${PARENT}:${PARENT_BRANCH}"

  if ! CMP="$(compare_fork "$FORK" "$BRANCH" "$PARENT_OWNER" "$PARENT_BRANCH")"; then
    FAILED=$((FAILED+1))
    report "$FORK" "$PARENT" "❌ 失败" "compare 失败：$(head -1 "$CMP_ERR_FILE" | cut -c1-80)"
    continue
  fi
  IFS=$'\t' read -r STATUS BEHIND AHEAD <<< "$CMP"

  case "$STATUS" in
    identical)
      UPTODATE=$((UPTODATE+1))
      report "$FORK" "$PARENT" "✅ 已最新" "与上游完全一致"
      ;;
    ahead)
      UPTODATE=$((UPTODATE+1))
      report "$FORK" "$PARENT" "✅ 无需同步" "本地领先上游 ${AHEAD} 个提交，上游无新更新"
      ;;
    behind)
      if [ "$DRY_RUN" = "true" ]; then
        report "$FORK" "$PARENT" "🔍 待同步" "落后上游 ${BEHIND} 个提交（演练模式未合并）"
        continue
      fi
      if OUT="$(gh api -X POST "repos/$FORK/merge-upstream" -f branch="$BRANCH" 2>&1)"; then
        SYNCED=$((SYNCED+1))
        report "$FORK" "$PARENT" "🔄 已同步" "已合并上游 ${BEHIND} 个提交"
      elif printf '%s' "$OUT" | grep -q "HTTP 409"; then
        MANUAL=$((MANUAL+1))
        report "$FORK" "$PARENT" "⚠️ 需人工" "自动合并冲突，请手动 Sync fork 或在本地解决后推送"
      else
        MANUAL=$((MANUAL+1))
        report "$FORK" "$PARENT" "⚠️ 需人工" "merge-upstream 返回异常：$(printf '%s' "$OUT" | head -1 | cut -c1-80)"
      fi
      ;;
    diverged)
      MANUAL=$((MANUAL+1))
      report "$FORK" "$PARENT" "⚠️ 需人工" "与上游已分叉（本地领先 ${AHEAD}、落后 ${BEHIND}），无法自动合并"
      ;;
    *)
      FAILED=$((FAILED+1))
      report "$FORK" "$PARENT" "❌ 失败" "compare 返回未知状态：${STATUS}"
      ;;
  esac
done < "$FORKS_FILE"

# ---------- 3. 60 天保活 ----------
# GitHub 会在仓库 60 天无活动时自动禁用定时工作流（官方文档明确写了公开仓库，
# 私有仓库同样存在该风险）。若本仓库默认分支 45 天以上没有新提交，
# 生成一个空提交保持活跃，确保每日同步不中断。
if [ "$KEEPALIVE" = "true" ] && [ "$DRY_RUN" != "true" ] \
   && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -d .git ]; then
  LAST_TS="$(git log -1 --format=%ct 2>/dev/null || echo 0)"
  NOW_TS="$(date +%s)"
  if [ "$LAST_TS" -gt 0 ] && [ $((NOW_TS - LAST_TS)) -gt $((45 * 86400)) ]; then
    log "==> 本仓库已超过 45 天无提交，生成保活提交（防止定时工作流被 60 天规则禁用）"
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git commit --allow-empty -m "chore: keepalive to keep scheduled fork-sync workflow enabled"
    # PAT 出现在 URL 中会被 Actions 日志自动打码，属官方推荐写法
    if git push "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" \
         "HEAD:${GITHUB_REF_NAME:-main}" 2>/dev/null; then
      log "==> 保活提交已推送"
    else
      err "保活提交推送失败（不影响本次同步结果，请检查 PAT 对本仓库的写权限）"
    fi
  fi
fi

# ---------- 4. 输出汇总 ----------
finish_summary
log ""
log "==> 同步完成：共 ${TOTAL} 个 fork —— 已同步 ${SYNCED}，已最新 ${UPTODATE}，跳过 ${SKIPPED}，需人工 ${MANUAL}，失败 ${FAILED}"

# 仅当出现真实错误（认证/接口失败）时让工作流标红，便于及时发现问题；
# 「需人工」的分叉 fork 属于已知状态，不作为工作流失败，避免每日误报。
[ "${FAILED}" -eq 0 ] || exit 1
