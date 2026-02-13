Param (
    [Parameter(Mandatory)]
    [string] $WorkflowRunId,
    [Parameter(Mandatory)]
    [string] $Repository,
    [Parameter(Mandatory)]
    [string] $AccessToken,
    [int] $RetryIntervalSeconds = 300,
    [int] $MaxRetryCount = 0,
    [switch] $ProvisionerOnly = $true
)

Import-Module (Join-Path $PSScriptRoot "GitHubApi.psm1")

function Wait-ForWorkflowCompletion($WorkflowRunId, $RetryIntervalSeconds) {
    do {
        Start-Sleep -Seconds $RetryIntervalSeconds
        $workflowRun = $gitHubApi.GetWorkflowRun($WorkflowRunId)
        if (-not $ProvisionerOnly) {
            Write-Host "Waiting for workflow ${WorkflowRunId}: status=$($workflowRun.status) conclusion=$($workflowRun.conclusion)"
        }
    } until ($workflowRun.status -eq "completed")

    return $workflowRun
}

function Write-WorkflowDiagnostics {
    param (
        $WorkflowRun,
        $WorkflowJobs
    )

    if ($WorkflowRun) {
        Write-Host "Workflow URL: $($WorkflowRun.html_url)"
        Write-Host "Event: $($WorkflowRun.event); Attempt: $($WorkflowRun.run_attempt); Status: $($WorkflowRun.status); Conclusion: $($WorkflowRun.conclusion)"
        if ($WorkflowRun.head_commit) {
            Write-Host "Head commit: $($WorkflowRun.head_commit.id) - $($WorkflowRun.head_commit.message)"
        }
    }

    if ($WorkflowJobs -and $WorkflowJobs.jobs) {
        Write-Host "Jobs summary:"
        foreach ($job in $WorkflowJobs.jobs) {
            $stepSummaries = @()
            if ($job.steps) {
                $stepSummaries = $job.steps | ForEach-Object { "[$($_.name) => $($_.conclusion ?? $_.status)]" }
            }
            $stepSummaryText = if ($stepSummaries.Count -gt 0) { $stepSummaries -join '; ' } else { 'no steps reported' }
            $jobUrl = if ($job.html_url) { $job.html_url } else { 'N/A' }
            Write-Host " - $($job.name) (attempt $($job.run_attempt)) => $($job.conclusion ?? $job.status); steps: $stepSummaryText; url: $jobUrl"
        }
    }
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
    if (-not $ProvisionerOnly) {
        Write-Host "Workflow run finished with result: $($finishedWorkflowRun.conclusion)"
    }
    if ($finishedWorkflowRun.conclusion -in ("success", "cancelled", "timed_out")) {
        break
    } elseif ($finishedWorkflowRun.conclusion -eq "failure") {
        if ($attempt -le $MaxRetryCount) {
            Write-Host "Workflow run will be restarted. Attempt $attempt of $MaxRetryCount"
            $gitHubApi.ReRunFailedJobs($WorkflowRunId)
            $attempt += 1
        } else {
            break
        }
    }
} while ($true)

if (-not $ProvisionerOnly) {
    Write-Host "Last result: $($finishedWorkflowRun.conclusion)."
}
try {
    $workflowJobs = $gitHubApi.GetWorkflowRunJobs($WorkflowRunId)
    if (-not $ProvisionerOnly) {
        Write-WorkflowDiagnostics -WorkflowRun $finishedWorkflowRun -WorkflowJobs $workflowJobs
    }
    if ($finishedWorkflowRun.conclusion -eq "failure") {
        Write-FailedJobLogs -WorkflowJobs $workflowJobs -GitHubApi $gitHubApi -TailLines 0
    }
} catch {
    if (-not $ProvisionerOnly) {
        Write-Host "Failed to fetch workflow job details: $($_.Exception.Message)"
    }
}
"CI_WORKFLOW_RUN_RESULT=$($finishedWorkflowRun.conclusion)" | Out-File -Append -FilePath $env:GITHUB_ENV

if ($finishedWorkflowRun.conclusion -in ("failure", "cancelled", "timed_out")) {
    exit 1
}
