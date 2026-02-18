Param (
    [Parameter(Mandatory)]
    [string] $WorkflowRunId,
    [Parameter(Mandatory)]
    [string] $Repository,
    [Parameter(Mandatory)]
    [string] $AccessToken,
    [int] $RetryIntervalSeconds = 300,
    [int] $MaxRetryCount = 0
)

Import-Module (Join-Path $PSScriptRoot "GitHubApi.psm1")

function Wait-ForWorkflowCompletion($WorkflowRunId, $RetryIntervalSeconds) {
    do {
        Start-Sleep -Seconds $RetryIntervalSeconds
        $workflowRun = $gitHubApi.GetWorkflowRun($WorkflowRunId)
    } until ($workflowRun.status -eq "completed")

    return $workflowRun
}

function Write-FailedJobLogs {
    param (
        $WorkflowJobs,
        $GitHubApi,
        [int] $TailLines = 0
    )

    if (-not ($WorkflowJobs -and $WorkflowJobs.jobs)) {
        return
    }

    $failedJobs = $WorkflowJobs.jobs | Where-Object { $_.conclusion -eq "failure" }

    function Get-ProvisionerWindow {
        param([string[]] $Lines)

        if (-not $Lines) { return @() }

        $start = $null
        for ($i = $Lines.Length - 1; $i -ge 0; $i--) {
            if ($Lines[$i] -match "Provisioning with") {
                $start = $i
                break
            }
        }

        if ($start -eq $null) { return @() }

        $end = $Lines.Length - 1
        for ($j = $start; $j -lt $Lines.Length; $j++) {
            if ($Lines[$j] -match "Provisioning step had errors: Running the cleanup provisioner, if present") {
                $end = $j - 1
                break
            }
        }

        if ($end -lt $start) { return @() }
        return $Lines[$start..$end]
    }

    function Invoke-CopilotLogAnalysis {
        param([string[]] $LogLines)

        if (-not $LogLines -or $LogLines.Count -eq 0) { return }
        if ([string]::IsNullOrWhiteSpace($env:COPILOT_GITHUB_TOKEN)) { return }

        $copilotCmd = $null
        $cmdInfo = Get-Command copilot -ErrorAction SilentlyContinue
        if ($cmdInfo) {
            $copilotCmd = $cmdInfo.Source
        } else {
            $candidatePaths = @(
                (Join-Path $env:HOME ".local/bin/copilot"),
                "/usr/local/bin/copilot",
                "/opt/homebrew/bin/copilot"
            )
            $copilotCmd = $candidatePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        if ([string]::IsNullOrWhiteSpace($copilotCmd)) { return }

        $prompt = @"
Analyze the following CI provisioner failure log.
Return only 2 short lines:
1) Root cause
2) Suggested fix

Log:
$($LogLines -join "`n")
"@

        $promptFile = Join-Path $env:RUNNER_TEMP "copilot-log-analysis.txt"
        $prompt | Out-File -FilePath $promptFile -Encoding utf8NoBOM

        try {
            if ([string]::IsNullOrWhiteSpace($env:COPILOT_AUTO_UPDATE)) { $env:COPILOT_AUTO_UPDATE = "false" }
            if ([string]::IsNullOrWhiteSpace($env:COPILOT_MODEL)) { $env:COPILOT_MODEL = "gpt-5" }
            if ([string]::IsNullOrWhiteSpace($env:COPILOT_ALLOW_ALL)) { $env:COPILOT_ALLOW_ALL = "false" }
            if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { $env:GH_TOKEN = $env:COPILOT_GITHUB_TOKEN }
            if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { $env:GITHUB_TOKEN = $env:COPILOT_GITHUB_TOKEN }

            $analysis = (Get-Content -Path $promptFile -Raw | & $copilotCmd --no-ask-user --no-custom-instructions 2>&1 | Out-String).Trim()
            if ($analysis -match "No authentication information found") {
                return
            }

            if (-not [string]::IsNullOrWhiteSpace($analysis)) {
                Write-Host $analysis
            }
        } catch {
        } finally {
            Remove-Item -Path $promptFile -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($job in $failedJobs) {
        $zipPath = Join-Path $env:RUNNER_TEMP "job-$($job.id)-logs.zip"
        $extractPath = Join-Path $env:RUNNER_TEMP "job-$($job.id)-logs"

        try {
            $GitHubApi.DownloadJobLogs($job.id, $zipPath)
            if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -eq 0) {
                continue
            }

            $slice = @()
            try {
                Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop | Out-Null
                $logFiles = Get-ChildItem -Path $extractPath -Recurse -File | Sort-Object Length -Descending
                if ($logFiles.Count -gt 0) {
                    $logContent = Get-Content -Path $logFiles[0].FullName
                    $slice = Get-ProvisionerWindow -Lines $logContent
                }
            } catch {
                $rawContent = Get-Content -Path $zipPath -ErrorAction SilentlyContinue
                if ($rawContent) {
                    $slice = Get-ProvisionerWindow -Lines $rawContent
                }
            }

            if ($slice.Count -gt 0) {
                Invoke-CopilotLogAnalysis -LogLines $slice
                ($slice | Select-Object -Last ($(if ($TailLines -gt 0) { $TailLines } else { $slice.Count }))) -join "`n" | Write-Host
            }
        } finally {
            Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$gitHubApi = Get-GithubApi -Repository $Repository -AccessToken $AccessToken

$attempt = 1
do {
    $finishedWorkflowRun = Wait-ForWorkflowCompletion -WorkflowRunId $WorkflowRunId -RetryIntervalSeconds $RetryIntervalSeconds
    if ($finishedWorkflowRun.conclusion -in ("success", "cancelled", "timed_out")) {
        break
    } elseif ($finishedWorkflowRun.conclusion -eq "failure") {
        if ($attempt -le $MaxRetryCount) {
            $gitHubApi.ReRunFailedJobs($WorkflowRunId)
            $attempt += 1
        } else {
            break
        }
    }
} while ($true)

try {
    $workflowJobs = $gitHubApi.GetWorkflowRunJobs($WorkflowRunId)
    if ($finishedWorkflowRun.conclusion -eq "failure") {
        Write-FailedJobLogs -WorkflowJobs $workflowJobs -GitHubApi $gitHubApi -TailLines 0
    }
} catch {
}
"CI_WORKFLOW_RUN_RESULT=$($finishedWorkflowRun.conclusion)" | Out-File -Append -FilePath $env:GITHUB_ENV

if ($finishedWorkflowRun.conclusion -in ("failure", "cancelled", "timed_out")) {
    exit 1
}
