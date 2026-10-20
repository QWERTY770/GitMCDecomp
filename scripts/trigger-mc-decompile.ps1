#Requires -Version 5.1
<#
.SYNOPSIS
    从本地调用 GitHub REST API 触发 GitMCDecomp 的 Actions 工作流（workflow_dispatch）。

.DESCRIPTION
    GitHub 的 schedule 触发器是"尽力而为"的：高峰期可能被延迟几十分钟、甚至整次丢弃，
    而且不会补偿。相比之下 workflow_dispatch 走 REST API 是即时入队的，等价于在网页上
    点 "Run workflow"。本脚本把这个动作自动化，方便在本地用计划任务替代 GitHub 的 cron。

    行为要点：
      * 默认只在当前没有"排队中 / 运行中"的同工作流运行时才触发，
        避免本地高频调用把运行堆积起来（用 -Force 关闭这个检查）。
      * 触发后可以用 -Wait 等到本次运行结束并打印结论。
      * -IntervalSec 让脚本常驻，自己按间隔循环。
      * 自动使用 Windows 系统代理（WinINET / PAC），可用 -Proxy 或 -NoProxy 覆盖。

    Token 查找顺序：-Token 参数 → 环境变量 GITHUB_TOKEN → GH_TOKEN → token 文件。

.EXAMPLE
    .\trigger-mc-decompile.ps1 -DryRun
    只做只读检查（网络、代理、工作流是否存在、token 是否有效），不发触发请求。

.EXAMPLE
    .\trigger-mc-decompile.ps1
    触发一次；若已有运行在排队 / 执行中则跳过。

.EXAMPLE
    .\trigger-mc-decompile.ps1 -Force -Wait
    强制再触发一次，并等到这次运行结束，打印结论和失败的任务名。

.EXAMPLE
    .\trigger-mc-decompile.ps1 -IntervalSec 300
    常驻后台，每 5 分钟检查并触发一次（前台窗口需保持打开）。

.NOTES
    需要 token 具备触发工作流的权限：细粒度 PAT 勾选 "Actions: Read and write"，
    或经典 PAT 勾选 repo（私有仓库场景还需 workflow）。
#>
[CmdletBinding()]
param(
    # 目标仓库，owner/name
    [string] $Repo = 'QWERTY770/GitMCDecomp',

    # 工作流文件名或数字 ID，取自 .github/workflows/ 下的文件名
    [string] $Workflow = 'listen-mc-decompile.yml',

    # workflow_dispatch 的 ref：必须是包含该工作流文件的分支/标签
    [string] $Ref = 'master',

    # 直接给 token（不推荐写在命令历史里，优先用环境变量或 token 文件）
    [string] $Token,

    # token 文件路径，默认仓库根目录的 .gh-trigger-token（已加入 .gitignore）
    [string] $TokenFile,

    # 显式指定代理，例如 http://127.0.0.1:7897
    [string] $Proxy,

    # 不走任何代理，强制直连
    [switch] $NoProxy,

    # 即使已有排队 / 运行中的运行也照常触发
    [switch] $Force,

    # 等到本次运行结束
    [switch] $Wait,

    # -Wait 的最长等待秒数
    [int] $WaitTimeoutSec = 3600,

    # > 0 时进入常驻循环，每 N 秒触发一次
    [int] $IntervalSec = 0,

    # 只做只读检查，不发送 dispatch
    [switch] $DryRun,

    # 日志文件，默认仓库根目录 logs/trigger-workflow.log；传空字符串则不写文件
    [string] $LogFile,

    # 自测用的 API 入口，一般不用改
    [string] $ApiBase = 'https://api.github.com'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 基础设施

# PowerShell 5.1 默认可能不带 TLS 1.2，GitHub 现在只接受 TLS 1.2+
try {
    $proto = [Net.ServicePointManager]::SecurityProtocol
    if (($proto -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
        [Net.ServicePointManager]::SecurityProtocol = $proto -bor [Net.SecurityProtocolType]::Tls12
    }
}
catch {
    # 在受限语言模式下这里会失败，交给调用时再暴露真实错误
}

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$RepoRoot = Split-Path -Parent $ScriptDir

# 用 PSBoundParameters 判断，这样显式传空字符串才能真正关掉默认值
if (-not $PSBoundParameters.ContainsKey('TokenFile')) { $TokenFile = Join-Path $RepoRoot '.gh-trigger-token' }
if (-not $PSBoundParameters.ContainsKey('LogFile')) { $LogFile = Join-Path $RepoRoot 'logs\trigger-workflow.log' }

$script:AuthToken = $null
$script:TokenSource = 'none'
$script:ProxyUri = $null
$script:UserAgent = 'GitMCDecomp-local-trigger/1.0'

$ActiveStatuses = @('queued', 'in_progress', 'waiting', 'pending', 'requested')

function Write-Log {
    param(
        [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = 'Gray'
    if ($Level -eq 'WARN') { $color = 'Yellow' }
    if ($Level -eq 'ERROR') { $color = 'Red' }
    Write-Host $line -ForegroundColor $color

    if (-not $LogFile) { return }
    try {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # 简单滚动：超过 2 MB 就换一份
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 2MB)) {
            Move-Item $LogFile ($LogFile + '.1') -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
    catch {
        # 日志写不进去不影响主流程
    }
}

# 任何要打印的异常信息都先去掉 token，避免泄进日志
function Protect-Secret {
    param([string] $Text)
    if (-not $Text) { return $Text }
    if ($script:AuthToken) { return $Text.Replace($script:AuthToken, '***') }
    return $Text
}

function Resolve-Token {
    if ($Token) {
        $script:AuthToken = $Token.Trim()
        $script:TokenSource = '参数 -Token'
        return
    }
    if ($env:GITHUB_TOKEN) {
        $script:AuthToken = $env:GITHUB_TOKEN.Trim()
        $script:TokenSource = '环境变量 GITHUB_TOKEN'
        return
    }
    if ($env:GH_TOKEN) {
        $script:AuthToken = $env:GH_TOKEN.Trim()
        $script:TokenSource = '环境变量 GH_TOKEN'
        return
    }
    if ($TokenFile -and (Test-Path $TokenFile)) {
        $content = Get-Content -Path $TokenFile -TotalCount 1
        if ($content) {
            $script:AuthToken = $content.Trim()
            $script:TokenSource = '文件 ' + $TokenFile
            return
        }
    }
    $script:AuthToken = $null
    $script:TokenSource = 'none'
}

function Resolve-Proxy {
    if ($NoProxy) {
        $script:ProxyUri = $null
        return
    }
    $candidate = $Proxy
    if (-not $candidate) {
        if ($env:HTTPS_PROXY) { $candidate = $env:HTTPS_PROXY }
        elseif ($env:HTTP_PROXY) { $candidate = $env:HTTP_PROXY }
    }
    if (-not $candidate) {
        # 用 Windows 系统代理（设置 → 网络 → 代理，含 PAC 脚本）
        try {
            $sys = [Net.WebRequest]::GetSystemWebProxy().GetProxy([uri]'https://api.github.com')
            if ($sys -and $sys.AbsoluteUri -ne 'https://api.github.com/') { $candidate = $sys.AbsoluteUri }
        }
        catch {
            $candidate = $null
        }
    }
    if ($candidate) {
        if ($candidate -notmatch '^[a-zA-Z][a-zA-Z0-9+.\-]*://') { $candidate = 'http://' + $candidate }
        try {
            $script:ProxyUri = [uri]$candidate
        }
        catch {
            Write-Log ("忽略无法识别的代理地址: " + $candidate) 'WARN'
            $script:ProxyUri = $null
        }
    }
}

function Get-HttpStatus {
    param($ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) { return [int]$resp.StatusCode }
    }
    catch { }
    return 0
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        $Body,
        [switch] $Anonymous
    )

    $uri = $ApiBase.TrimEnd('/') + $Path
    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = $script:UserAgent
    }
    if (-not $Anonymous -and $script:AuthToken) {
        $headers['Authorization'] = 'Bearer ' + $script:AuthToken
    }

    # 注意：不要用 $args 当变量名，它是 PowerShell 的自动变量
    $request = @{
        Method          = $Method
        Uri             = $uri
        Headers         = $headers
        UseBasicParsing = $true
        TimeoutSec      = 40
    }
    if ($null -ne $Body) {
        $request['Body'] = (ConvertTo-Json -InputObject $Body -Compress)
        $request['ContentType'] = 'application/json; charset=utf-8'
    }
    if ($script:ProxyUri) { $request['Proxy'] = $script:ProxyUri }

    return Invoke-RestMethod @request
}

# 把 API 失败翻译成人能看懂的原因
function Show-ApiFailure {
    param(
        [string] $Action,
        $ErrorRecord
    )

    $status = Get-HttpStatus $ErrorRecord
    $msg = Protect-Secret $ErrorRecord.Exception.Message
    Write-Log ("$Action 失败：" + $msg) 'ERROR'

    switch ($status) {
        401 {
            Write-Log 'token 无效或已过期/撤销。重新生成 PAT，并确认 token 文件里没有多余空行或引号。' 'ERROR'
        }
        403 {
            Write-Log ('权限不足或触发了频率限制。细粒度 PAT 需要 "Actions: Read and write"；' +
                '经典 PAT 需要 repo（私有仓库还需 workflow）范围。') 'ERROR'
            Write-Log ("当前 token 来源：" + $script:TokenSource) 'ERROR'
        }
        404 {
            Write-Log ("仓库、工作流或 ref 不存在，或者 token 无权访问：" +
                "$Repo / $Workflow / $Ref。注意工作流文件必须存在于 ref 指向的分支上。") 'ERROR'
        }
        422 {
            Write-Log ("请求被拒绝：通常是 ref '$Ref' 不存在，或该工作流没有 workflow_dispatch 触发器。") 'ERROR'
        }
        0 {
            Write-Log ("网络层失败。这台机器直连 api.github.com 可能不通，请确认代理：" +
                "当前代理 = " + $(if ($script:ProxyUri) { $script:ProxyUri.AbsoluteUri } else { '(未使用)' })) 'ERROR'
            Write-Log '可用 -Proxy http://127.0.0.1:7897 显式指定，或 -NoProxy 强制直连。' 'ERROR'
        }
    }
}

function ConvertTo-DateTimeOffset {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [DateTimeOffset]::MinValue }
    try {
        return [DateTimeOffset]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal)
    }
    catch {
        return [DateTimeOffset]::MinValue
    }
}

function Get-WorkflowRuns {
    param([int] $PerPage = 20, [string] $Event)
    $path = "/repos/$Repo/actions/workflows/$Workflow/runs?per_page=$PerPage"
    if ($Event) { $path = $path + '&event=' + $Event }
    $resp = Invoke-GitHubApi -Method 'GET' -Path $path
    if ($null -eq $resp) { return @() }
    # @($null) 会产生一个 $null 元素，这里顺手滤掉
    return @($resp.workflow_runs | Where-Object { $_ })
}

# ---------------------------------------------------------------- 主流程

function Invoke-Trigger {
    param([switch] $AnonymousRead)

    # 1) 确认工作流存在 —— 这一步同时验证了网络、代理、TLS 和 token
    $wf = $null
    try {
        $wf = Invoke-GitHubApi -Method 'GET' -Path "/repos/$Repo/actions/workflows/$Workflow" -Anonymous:$AnonymousRead
    }
    catch {
        Show-ApiFailure -Action "读取工作流 $Workflow" -ErrorRecord $_
        throw
    }

    Write-Log ("工作流：" + $wf.name + "（" + $wf.path + "），状态：" + $wf.state)
    if ($wf.state -ne 'active') {
        Write-Log ('该工作流当前是 ' + $wf.state + '，被禁用的工作流无法通过 dispatch 触发。' +
            '如果是公共仓库长期没有活动被自动禁用，先去 Actions 页面点 "Enable workflow"。') 'WARN'
    }

    # 2) 去重：已有排队/运行中的运行就跳过，避免和本地高频调用叠加
    if (-not $Force) {
        try {
            $runs = Get-WorkflowRuns -PerPage 20
        }
        catch {
            Show-ApiFailure -Action '查询运行列表' -ErrorRecord $_
            throw
        }
        $active = @($runs | Where-Object { $ActiveStatuses -contains $_.status })
        if ($active.Count -gt 0) {
            $first = $active[0]
            Write-Log ("已有 " + $active.Count + " 个运行在排队或执行中（最新 #" + $first.run_number +
                ' ' + $first.status + '），本次跳过。用 -Force 可以强制再触发。') 'WARN'
            return 'skipped'
        }
        if ($runs.Count -gt 0) {
            Write-Log ('当前没有排队/执行中的运行（最近一次 #' + $runs[0].run_number + ' ' + $runs[0].status + '）。')
        }
        else {
            Write-Log '当前没有排队/执行中的运行（历史上还没有任何运行记录）。'
        }
    }

    # 3) 发送 workflow_dispatch
    if ($DryRun) {
        $preview = '{"ref":"' + $Ref + '"}'
        Write-Log ("[DryRun] 将发送：POST " + $ApiBase.TrimEnd('/') +
            "/repos/$Repo/actions/workflows/$Workflow/dispatches  body=" + $preview)
        return 'dryrun'
    }

    $sentAt = [DateTimeOffset]::UtcNow
    try {
        Invoke-GitHubApi -Method 'POST' -Path "/repos/$Repo/actions/workflows/$Workflow/dispatches" -Body @{ ref = $Ref } | Out-Null
    }
    catch {
        Show-ApiFailure -Action '触发工作流' -ErrorRecord $_
        throw
    }
    Write-Log ("已向 $Repo 的 $Workflow 发送 workflow_dispatch（ref=$Ref）。")

    # 4) dispatch 返回 204 没有 body，只能回查刚创建的那个运行
    $run = $null
    $deadline = (Get-Date).AddSeconds(90)
    while (-not $run -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        try {
            $candidates = Get-WorkflowRuns -PerPage 20 -Event 'workflow_dispatch'
        }
        catch {
            Show-ApiFailure -Action '查询新建的运行' -ErrorRecord $_
            throw
        }
        $fresh = @($candidates | Where-Object {
                (ConvertTo-DateTimeOffset $_.created_at) -ge $sentAt.AddSeconds(-20)
            })
        if ($fresh.Count -gt 0) {
            $run = $fresh | Sort-Object { ConvertTo-DateTimeOffset $_.created_at } -Descending | Select-Object -First 1
        }
    }

    if (-not $run) {
        Write-Log ('已发出触发请求，但 90 秒内没在列表里看到对应的运行。' +
            "去 https://github.com/$Repo/actions/workflows/$Workflow 确认一下。") 'WARN'
        return 'dispatched'
    }

    Write-Log ("运行已创建：#" + $run.run_number + "  " + $run.html_url)
    if (-not $Wait) { return 'dispatched' }

    # 5) 等结果
    $started = Get-Date
    $lastStatus = ''
    while ($true) {
        if (((Get-Date) - $started).TotalSeconds -gt $WaitTimeoutSec) {
            Write-Log ("等待超时（" + $WaitTimeoutSec + ' 秒），运行仍在 ' + $run.status + '。') 'WARN'
            return 'timeout'
        }

        try {
            $current = Invoke-GitHubApi -Method 'GET' -Path "/repos/$Repo/actions/runs/" + $run.id
        }
        catch {
            Show-ApiFailure -Action '查询运行状态' -ErrorRecord $_
            throw
        }

        if ($current.status -ne $lastStatus) {
            Write-Log ('状态：' + $current.status + ' / ' + $current.conclusion)
            $lastStatus = $current.status
        }
        if ($current.status -eq 'completed') {
            $conclusion = $current.conclusion
            if ($conclusion -eq 'success') {
                Write-Log '运行成功结束。'
            }
            else {
                Write-Log ('运行结束，结论：' + $conclusion) 'WARN'
                try {
                    $jobs = Invoke-GitHubApi -Method 'GET' -Path "/repos/$Repo/actions/runs/" + $run.id + '/jobs?per_page=50'
                    foreach ($job in @($jobs.jobs | Where-Object { $_ })) {
                        Write-Log ('  任务 ' + $job.name + ' → ' + $job.status + ' / ' + $job.conclusion)
                        foreach ($step in @($job.steps | Where-Object { $_ })) {
                            if ($step.conclusion -eq 'failure') {
                                Write-Log ('    失败步骤：' + $step.name) 'WARN'
                            }
                        }
                    }
                }
                catch {
                    # 拉不到任务明细不影响结论
                }
            }
            Write-Log ('详情：' + $current.html_url)
            if ($conclusion -eq 'success') { return 'success' }
            return 'failed'
        }

        Start-Sleep -Seconds 15
        # 复用 $run 上的 url，下一轮用同一个运行 id
    }
}

# 运行环境自检
Resolve-Token
Resolve-Proxy

Write-Log '===== 触发 GitHub Actions 工作流 ====='
Write-Log ("仓库：" + $Repo + "  工作流：" + $Workflow + "  ref：" + $Ref)
Write-Log ("代理：" + $(if ($script:ProxyUri) { $script:ProxyUri.AbsoluteUri } else { '(不使用)' }))

$anonymousRead = $false
if ($script:AuthToken) {
    Write-Log ('token：已加载（来源：' + $script:TokenSource + '，长度 ' + $script:AuthToken.Length + '）')
}
elseif ($DryRun) {
    Write-Log 'token：未找到，DryRun 将以匿名方式做只读检查（无法验证触发权限）。' 'WARN'
    $anonymousRead = $true
}
else {
    Write-Log '找不到 token，无法触发工作流。按下面任一方式提供，然后重试：' 'ERROR'
    Write-Log '  1) 临时：$env:GITHUB_TOKEN = "ghp_xxx"   （仅当前窗口有效）' 'ERROR'
    Write-Log '  2) 持久：setx GITHUB_TOKEN "ghp_xxx"     （新开窗口生效）' 'ERROR'
    Write-Log ('  3) 文件：把 token 写进 ' + $TokenFile + '（已加入 .gitignore，只读第一行）') 'ERROR'
    Write-Log '  4) 参数：.\trigger-mc-decompile.ps1 -Token "ghp_xxx"' 'ERROR'
    Write-Log 'token 需要 "Actions: Read and write"（细粒度）或 repo 范围（经典 PAT）。' 'ERROR'
    exit 1
}

if ($IntervalSec -gt 0) {
    Write-Log ('进入常驻模式，每 ' + $IntervalSec + ' 秒触发一次。Ctrl+C 退出。')
    while ($true) {
        try {
            $result = Invoke-Trigger -AnonymousRead:$anonymousRead
            Write-Log ('本次结果：' + $result)
        }
        catch {
            Write-Log ('本次失败：' + (Protect-Secret $_.Exception.Message)) 'ERROR'
        }
        Start-Sleep -Seconds $IntervalSec
    }
}

try {
    $result = Invoke-Trigger -AnonymousRead:$anonymousRead
    Write-Log ('本次结果：' + $result)
    if ($result -eq 'failed') { exit 1 }
    exit 0
}
catch {
    Write-Log ('失败退出：' + (Protect-Secret $_.Exception.Message)) 'ERROR'
    exit 1
}
