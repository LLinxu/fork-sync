# fork-sync · Fork 仓库每日自动同步

每日定时把**当前账号下所有 fork 的仓库**自动更新到上游（upstream）最新代码，基于 GitHub Actions + GitHub 官方 REST API 实现，无需本地电脑开机。

- 同步动作走 GitHub 官方 `merge-upstream` 接口（即网页端 **Sync fork** 按钮背后的 API），不需要在每个 fork 里单独启用 Actions
- 已与上游一致的 fork 不发起任何写操作；与上游分叉的 fork 只在报告里标记「需人工」，不会强行覆盖你的本地提交
- 支持手动触发、演练模式（只对比不合并）、60 天自动保活

## 目录结构

```
fork-sync/
├── .github/
│   └── workflows/
│       └── sync-forks.yml    # 每日定时 + 手动触发的工作流
├── scripts/
│   └── sync_forks.sh         # 同步主脚本（列出 fork → 对比上游 → 合并 → 汇总报告）
├── .gitignore
└── README.md
```

## 工作原理

```
定时触发（每天 02:20 北京时间）
   │
   ▼
① 用 PAT 调 GET /user/repos?affiliation=owner&fork=true，列出账号下所有 fork
   │
   ▼
② 对每个 fork 调 compare 接口：
   repos/{fork}/compare/{fork默认分支}...{上游owner}:{上游默认分支}
   │
   ├─ identical / ahead ──► 无需同步，记录 ✅
   ├─ behind ───────────► ③ 调 POST /repos/{fork}/merge-upstream 同步
   ├─ diverged ─────────► 标记 ⚠️ 需人工（本地有独立提交，不强行合并）
   └─ 上游删除 / 仓库归档 ──► 标记 ⏭️ 跳过
   │
   ▼
④ 汇总报告写入 Actions 运行摘要（Run Summary）
```

## 快速开始（4 步）

### 1. 创建 GitHub PAT（同步的唯一凭据）

> 同步是跨仓库操作，`GITHUB_TOKEN` 无权访问其他仓库，必须用个人访问令牌（PAT）。
> 推荐创建**专用令牌**，只给这一件事用。

**方式 A · classic token（简单，推荐）**

1. 打开 <https://github.com/settings/tokens/new>（Tokens (classic) → Generate new token (classic)）
2. 勾选 **`repo`**（Full control of private repositories），过期时间按需设置
3. 生成后复制令牌（只显示一次）

**方式 B · fine-grained token（最小权限）**

1. 打开 <https://github.com/settings/personal-access-tokens/new>
2. Repository access 选 **All repositories**（必须包含未来新建的仓库）
3. Permissions → Repository permissions → **Contents: Read and write**、**Metadata: Read**

### 2. 把本仓库放到你的 GitHub 账号下

任选其一：

- 直接下载本目录上传为公开仓库（推荐公开仓库：Actions 免费不限分钟数）
- 或先 Fork 本仓库再取消与上游的关联（删掉 parent 即可）

### 3. 添加 Secret

仓库页面 → **Settings → Secrets and variables → Actions → Secrets → New repository secret**

| Name | Value |
| --- | --- |
| `FORK_SYNC_PAT` | 第 1 步创建的 PAT |

### 4. 启用 Actions 并手动验证一次

1. **Settings → Actions → General**，确认 Allow all actions（新建仓库默认允许）
2. **Actions → Fork Daily Sync → Run workflow**，先勾选 **dry_run = true** 跑一次演练模式，确认报告里列出的 fork 清单和待同步数量符合预期
3. 再取消 dry_run 手动跑一次，确认同步成功
4. 之后每天北京时间 02:20 自动执行，无需任何操作

## 定时规则

- 默认：每天 **02:20（Asia/Shanghai）** 执行
- 想改时间：编辑 `.github/workflows/sync-forks.yml` 里的 `cron` 和 `timezone`
  - `timezone` 支持 IANA 时区（如 `Asia/Shanghai`）；不写则按 UTC
  - 避开整点是官方建议：整点是定时高峰，容易延迟甚至被丢弃
- 最短只能每 5 分钟一次；更频繁没有意义（上游代码不会那么快更新）
- 可同时保留 `workflow_dispatch` 手动触发，互不影响

## 同步结果解读

| 报告标记 | 含义 | 是否需要处理 |
| --- | --- | --- |
| 🔄 已同步 | 落后上游，已通过 merge-upstream 合并 | 否 |
| ✅ 已最新 | 与上游一致，或无上游更新 | 否 |
| ⏭️ 跳过 | 上游已删除/转私有，或仓库已归档 | 视需要 |
| ⚠️ 需人工 | fork 与上游已分叉（本地有独立提交），或有合并冲突 | **是** |
| ❌ 失败 | compare 接口连续失败（如上游分支不存在、无访问权限） | 建议排查 |

⚠️ 需人工的 fork：在 GitHub 网页打开该 fork 点 **Sync fork**（有冲突时需本地解决后推送），
或清理 fork 内多余提交后再交给本工作流自动同步。脚本**不会**强制推送覆盖你的提交。

## GitHub 的限制（重要）

**能做到，且完全在免费额度内。** 相关限制如下：

### 1. Actions 配额

| 项目 | 限制 | 对本项目的影响 |
| --- | --- | --- |
| 分钟数（公开仓库） | **免费无限** | 控制仓库用公开仓库即可，0 成本 |
| 分钟数（私有仓库） | Free 2,000 分钟/月 | 每次运行约 1–3 分钟 × 30 天 ≈ 30–90 分钟/月，远够用 |
| 单 job 时长 | 最长 6 小时 | 实际几分钟 |
| 并发 job 数 | Free 20 | 本项目只用 1 个，另有 `concurrency` 防叠加 |
| 仓库存储 | 500 MB（Free） | 本仓库不足 100 KB |

> 控制仓库建议设为**公开**（里面只有工作流和脚本，无任何敏感信息，PAT 存在 Secret 里），公开仓库 Actions 不限分钟数。

### 2. 定时任务的特性

- **时区**：`cron` 默认按 UTC；本工作流已用 `timezone: "Asia/Shanghai"` 显式指定北京时间
- **延迟**：高峰期（尤其整点）定时任务可能延迟几分钟甚至被丢弃，已避开整点并选了凌晨低峰
- **60 天规则**：仓库 60 天无活动时，GitHub 会**自动禁用定时工作流**。脚本内置保活：本仓库超过 45 天无提交时自动生成一个空提交（可在 Variables 里设 `KEEPALIVE=false` 关闭）
- 定时工作流只在**默认分支**上运行，改 cron 要提交到默认分支
- 改动 `cron` 语法后，通知会发给最后修改工作流文件的人

### 3. API 速率限制

| 凭据 | 限制 | 本项目用量 |
| --- | --- | --- |
| PAT | 5,000 次/小时 | 每次运行 ≈ fork 数 × 2 + 1 次（1 次列出 + 每个 fork 各 1 次 compare + 需同步的 1 次 merge） |
| GITHUB_TOKEN | 1,000 次/小时/仓库，且**只能访问本仓库** | 不使用（跨仓库必须 PAT） |

100 个 fork 也只需约 200 次请求，距离限额非常远。脚本对 compare 有 3 次重试。

### 4. fork 自身状态导致的同步不了

| 情况 | 表现 | 说明 |
| --- | --- | --- |
| fork 有本地独立提交（diverged） | ⚠️ 需人工 | 与上游双向分叉，GitHub 不允许自动合并（网页端 Sync fork 按钮此时也是灰的） |
| 合并冲突 | ⚠️ 需人工（HTTP 409） | 需本地解决冲突后推送 |
| 仓库已归档（archived） | ⏭️ 跳过 | 归档仓库禁止推送 |
| 上游被删除/转私有 | ⏭️ 跳过 | 无上游可同步 |
| fork 与上游默认分支名不同 | 可能 ⚠️ 需人工 | 脚本按各自默认分支名对比；极少数改名场景需手动处理 |
| fork 是私有仓库 | 正常同步 | PAT 有 repo 权限即可，不受影响 |

### 5. 安全提醒

- PAT 只存放在仓库 Secret，不要写进任何代码或提交到仓库
- 建议用专用令牌 + 设置过期时间，定期轮换
- 仓库公开没有泄密风险（工作流和脚本均不含敏感信息）

## 常见问题

**Q：新建的 fork 会被自动纳入吗？**
会。每次运行都重新拉取全量 fork 列表，无需改任何配置。

**Q：会把我 fork 里的本地提交冲掉吗？**
不会。只有"落后且无分叉"时才合并；分叉时只标记不动作。合并不构成强推。

**Q：同步是快进还是产生合并提交？**
能快进就快进（fast-forward）；不能快进时由 GitHub 自动生成合并提交，都属于正常同步行为。

**Q：报告在哪里看？**
Actions → 最近一次运行 → 页面右侧 **Run Summary**，或展开 `Run fork sync` 步骤看逐仓库日志。

**Q：工作流没跑/突然停了？**
按顺序排查：① Actions 页是否显示 "This scheduled workflow is disabled"（60 天规则，点一下启用即可，保活机制会防止再次发生）；② Secret 是否失效（PAT 过期会被 GitHub 邮件提醒）；③ 手动 Run workflow 看具体报错。

**Q：想每周同步而不是每天？**
把 `cron: '20 2 * * *'` 改成 `cron: '20 2 * * 1'`（每周一 02:20）。
