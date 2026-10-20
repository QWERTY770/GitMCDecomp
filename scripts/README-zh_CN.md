# 从本地触发 `listen-mc-decompile` 工作流

用本地脚本调用 GitHub REST API 的 `workflow_dispatch`，效果等同于点 Actions 页面上的
**Run workflow**，用来替代延迟严重的 `schedule` 定时任务。

```
scripts/
├─ trigger-mc-decompile.ps1   # 主脚本（Windows PowerShell 5.1+，零依赖）
├─ trigger-mc-decompile.cmd   # 双击运行用的外壳，带 -ExecutionPolicy Bypass
└─ README-zh_CN.md            # 本文档
```

## 为什么 `schedule` 不靠谱

GitHub 官方文档对 `schedule` 的原话是：

> The `schedule` event can be delayed during periods of high loads of GitHub Actions workflow runs.
> High load times include the start of every hour. **If the load is sufficiently high enough, some
> queued jobs may be dropped.** To decrease the chance of delay, schedule your workflow to run at a
> different time of the hour.

也就是说：定时事件只是"尽力而为"。高峰期会被推迟（整点是重灾区），负载再高就直接丢弃、
而且不会补跑。所以会出现"5 分钟一次的任务十几小时才跑一次"的现象。

另外两条容易踩的坑：

- 公共仓库里，**60 天没有任何仓库活动**时，定时工作流会被自动禁用（`state: disabled_*`）。
- `schedule` 只在默认分支上生效。

而 `workflow_dispatch` 是事件驱动、即时入队的，没有排队延迟，也不会被丢弃。
本脚本就是让机器替你去"点"这个按钮。

## 原理

```
本地脚本 --(POST /repos/{owner}/{repo}/actions/workflows/{file}/dispatches)--> GitHub API
                                                                              |
                                              .github/workflows/listen-mc-decompile.yml
                                              on: workflow_dispatch  <--------+
```

`listen-mc-decompile.yml` 已经声明了 `workflow_dispatch:`，所以不需要改工作流文件。

## 第一步：创建 token

推荐**细粒度 PAT**（Fine-grained personal access token），权限最小：

1. 打开 <https://github.com/settings/personal-access-tokens/new>
2. **Token name** 随便填，例如 `GitMCDecomp local trigger`
3. **Expiration** 建议 90 天（到期后脚本会报 401，重新生成即可）
4. **Repository access** → `Only select repositories` → 勾选 `QWERTY770/GitMCDecomp`
5. **Permissions** → `Repository permissions` → 找到 **Actions** → 选 **Read and write**
6. 点 **Generate token**，复制以 `github_pat_` 开头的那串（只显示一次）

<details>
<summary>用经典 PAT 的等价做法</summary>

<https://github.com/settings/tokens/new> → 勾选 **`repo`** 范围（如果存放仓库是私有的，
再勾 **`workflow`**）→ Generate token，复制 `ghp_` 开头的那串。

经典 PAT 是仓库级全权限，不如细粒度 PAT 安全，能选细粒度就别用经典。
</details>

## 第二步：把 token 交给脚本

脚本按顺序查找，命中第一个就用：

1. 参数 `-Token "..."`
2. 环境变量 `GITHUB_TOKEN`
3. 环境变量 `GH_TOKEN`
4. token 文件（默认仓库根目录 `.gh-trigger-token`，已加入 `.gitignore`）

**方式 A：环境变量（推荐）**

```powershell
setx GITHUB_TOKEN "github_pat_xxxxxxxx"
```

`setx` 写的是用户级环境变量，**需要新开一个窗口**才生效。这种方式对计划任务也有效。

**方式 B：token 文件**

把 token 写进 `D:\java\main\GitMCDecomp\.gh-trigger-token`，脚本只读第一行。
这个文件已经被 `.gitignore` 排除，不会被提交。

**方式 C：只在当前窗口临时用**

```powershell
$env:GITHUB_TOKEN = "github_pat_xxxxxxxx"
```

## 第三步：跑起来

```powershell
cd D:\java\main\GitMCDecomp

# 1) 自检：只做只读请求，验证网络 / 代理 / 工作流 / token，不触发任何东西
.\scripts\trigger-mc-decompile.ps1 -DryRun

# 2) 触发一次（若已有运行在排队/执行中则跳过）
.\scripts\trigger-mc-decompile.ps1

# 3) 强制触发并等到结束，失败时打印是哪个任务、哪一步挂了
.\scripts\trigger-mc-decompile.ps1 -Force -Wait
```

也可以双击 `scripts\trigger-mc-decompile.cmd`（会带上 `-ExecutionPolicy Bypass`，
避免执行策略拦截，运行完窗口停住等你看结果）。

如果提示无法加载脚本，请在当前窗口单独执行一次：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\trigger-mc-decompile.ps1 -DryRun
```

### 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Repo` | `QWERTY770/GitMCDecomp` | 目标仓库 `owner/name` |
| `-Workflow` | `listen-mc-decompile.yml` | 工作流文件名，也可用数字 ID |
| `-Ref` | `master` | 触发用的分支；工作流文件必须存在于该分支 |
| `-Token` | | 直接给 token，会留在命令历史里，不推荐 |
| `-TokenFile` | `<仓库根>\.gh-trigger-token` | token 文件路径 |
| `-Proxy` | 系统代理 | 例如 `http://127.0.0.1:7897` |
| `-NoProxy` | | 强制直连，忽略系统代理 |
| `-Force` | | 关掉"已有运行就跳过"的检查 |
| `-Wait` | | 等待本次运行结束 |
| `-WaitTimeoutSec` | `3600` | `-Wait` 的最长等待秒数 |
| `-IntervalSec` | `0` | 大于 0 时常驻循环，每 N 秒触发一次 |
| `-DryRun` | | 只做只读检查，不发送触发请求 |
| `-LogFile` | `logs\trigger-workflow.log` | 日志路径；在 PowerShell 里传 `-LogFile ''` 可以关掉写文件 |

退出码：`0` 成功 / 跳过 / DryRun 正常；`1` 失败（任何网络的、权限的、运行失败的情况）。

### 关于去重

工作流一次要跑好几分钟（编译 + 反编译）。如果本地每 5 分钟无脑触发，运行会越堆越多，
多个运行还会同时往同一个分支 push，互相打架。

脚本默认会先查一遍运行列表，只要还有 `queued / in_progress / waiting / pending / requested`
的运行就跳过本次触发。想无视这个检查，加 `-Force`。

## 让它"定时"跑

### 方案 1：前台常驻

```powershell
.\scripts\trigger-mc-decompile.ps1 -IntervalSec 300
```

窗口保持打开，每 5 分钟检查一次。关窗口就停。

### 方案 2：Windows 计划任务（重启后依然有效）

在**普通** PowerShell 窗口执行（创建自己的任务一般不需要管理员）：

```powershell
$ps1      = 'D:\java\main\GitMCDecomp\scripts\trigger-mc-decompile.ps1'
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
              -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""
$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
              -RepetitionInterval (New-TimeSpan -Minutes 5) `
              -RepetitionDuration ([TimeSpan]::FromDays(3650))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'GitMCDecomp-trigger' -Action $action -Trigger $trigger -Settings $settings
```

等价的 `schtasks` 写法（脚本路径里**没有空格**时可以直接用，否则请用上面的写法）：

```bat
schtasks /Create /F /TN "GitMCDecomp-trigger" /SC MINUTE /MO 5 /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File D:\java\main\GitMCDecomp\scripts\trigger-mc-decompile.ps1"
```

管理它：

```powershell
Start-ScheduledTask  -TaskName 'GitMCDecomp-trigger'   # 立刻跑一次，验证配置
Get-ScheduledTask    -TaskName 'GitMCDecomp-trigger' | Get-ScheduledTaskInfo
Unregister-ScheduledTask -TaskName 'GitMCDecomp-trigger' -Confirm:$false   # 删除
```

注意两点：

- 计划任务**不会**继承你当前窗口里的 `$env:GITHUB_TOKEN`，所以 token 必须用 `setx` 或
  token 文件持久化。
- 窗口是隐藏的，看不到输出，出问题请查 `logs\trigger-workflow.log`。
- 不要给计划任务加 `-Wait`，它会长时间占着一个进程。`-Wait` 是给手动排查用的。

### 方案 3：保留 GitHub 的 `schedule` 作为兜底

本地的计划任务负责准时，GitHub 的 cron 留着也无妨。两者叠加时脚本的去重逻辑会防止同一时段
重复触发；如果两边恰好同时起跑，也可以在 `listen-mc-decompile.yml` 里加一个并发组来兜底：

```yaml
concurrency:
  group: listen-mc-decompile
  cancel-in-progress: false   # 排队而不是取消
```

## 排错

| 现象 | 原因与处理 |
| --- | --- |
| `401 Unauthorized` | token 打错、过期、被撤销，或文件里有引号/空行。重新生成并只粘贴 token 本体 |
| `403 Resource not accessible by personal access token` | 权限不够。细粒度 PAT 的 **Actions** 必须是 `Read and write`；经典 PAT 需要 `repo`（私有仓库再加 `workflow`）。也可能是触发了 API 频率限制，等一会儿 |
| `404 Not Found` | 仓库/工作流名写错，或 token 无权访问该仓库（细粒度 PAT 没把仓库加进 `Only select repositories`） |
| `422 Unprocessable Entity` | 通常是 `-Ref` 指向的分支不存在，或者该工作流没有声明 `workflow_dispatch` |
| `基础连接已经关闭 / 接收时发生错误` | 网络层失败。国内直连 `api.github.com` 常常不通：确认代理已开启，用 `-Proxy http://127.0.0.1:7897` 显式指定；脚本默认会自动读取 Windows 系统代理 |
| 日志显示 `该工作流当前是 disabled_*` | 工作流被禁用了（公共仓库 60 天无活动会自动禁用）。去 Actions 页面点 **Enable workflow** |
| 触发成功但运行失败 | 用 `-Wait` 跑一次，脚本会打印失败的任务名和步骤名 |
| 一启动就报一堆「意外的标记」「缺少右 “)”」这类语法错误 | 脚本被存成了**无 BOM 的 UTF-8**，Windows PowerShell 5.1 会按 GBK 解读里面的中文而语法崩坏。用 VS Code 另存为 **UTF-8 with BOM**（文件开头应有 `EF BB BF` 三个字节） |

日志在 `logs\trigger-workflow.log`（超过 2 MB 自动轮转成 `.log.1`），token 会被替换成 `***`
再写入，不会泄漏。

## 和仓库里 `listen.py` 的关系

根目录的 `listen.py` 是上游留下的思路：轮询 Mojang 的 `version_manifest.json` 的
`Last-Modified`，发现变了才 dispatch。它需要手填 `<USER>/<REPO>/<TOKEN>`，还要装 `requests`。

本脚本不轮询上游清单，纯按本地节奏触发（职责和工作流里的 `CheckMinecraft` 一致，由工作流
自己判断"是不是最新版本"），零依赖、可以直接扔进计划任务。
