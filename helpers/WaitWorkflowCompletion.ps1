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
        Write-Host "Waiting for workflow ${WorkflowRunId}: status=$($workflowRun.status) conclusion=$($workflowRun.conclusion)"
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

        if (-not $Lines) { return $Lines }

        $start = $null
        for ($i = $Lines.Length - 1; $i -ge 0; $i--) {
            if ($Lines[$i] -match "Provisioning with") {
                $start = $i
                break
            }
        }

        if ($start -eq $null) { return $Lines }

        $end = $null
        for ($j = $start; $j -lt $Lines.Length; $j++) {
            if ($Lines[$j] -match "Provisioning step had errors: Running the cleanup provisioner, if present") {
                $end = $j
                break
            }
        }

        if ($end -eq $null) { return $Lines[$start..($Lines.Length - 1)] }
        return $Lines[$start..$end]
    }
    foreach ($job in $failedJobs) {
        $zipPath = Join-Path $env:RUNNER_TEMP "job-$($job.id)-logs.zip"
        $extractPath = Join-Path $env:RUNNER_TEMP "job-$($job.id)-logs"

        try {
            Write-Host "Fetching logs for failed job: $($job.name) ($($job.id))"
            $GitHubApi.DownloadJobLogs($job.id, $zipPath)
            if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -eq 0) {
                Write-Host "No log archive downloaded for job $($job.name)."
                continue
            }

            try {
                Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
                $logFiles = Get-ChildItem -Path $extractPath -Recurse -File | Sort-Object Length -Descending
                if ($logFiles.Count -gt 0) {
                    $logContent = Get-Content -Path $logFiles[0].FullName
                    $slice = Get-ProvisionerWindow -Lines $logContent
                    Write-Host "---- Provisioner log for $($job.name) ----"
                    if ($TailLines -gt 0) {
                        ($slice | Select-Object -Last $TailLines) -join "`n" | Write-Host
                    } else {
                        $slice -join "`n" | Write-Host
                    }
                    Write-Host "---- End provisioner log ----"
                } else {
                    Write-Host "No log files found for job $($job.name)."
                }
            } catch {
                Write-Host "Archive extraction failed for job $($job.name): $($_.Exception.Message)"
                Write-Host "Dumping raw content tail from downloaded file"
                $rawContent = Get-Content -Path $zipPath -ErrorAction SilentlyContinue
                if ($rawContent) {
                    if ($TailLines -gt 0) {
                        ($rawContent | Select-Object -Last $TailLines) -join "`n" | Write-Host
                    } else {
                        $rawContent -join "`n" | Write-Host
                    }
                } else {
                    Write-Host "No raw content available to display."
                }
            }
        } catch {
            Write-Host "Failed to fetch logs for job $($job.name): $($_.Exception.Message)"
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
    Write-Host "Workflow run finished with result: $($finishedWorkflowRun.conclusion)"
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

Write-Host "Last result: $($finishedWorkflowRun.conclusion)."
try {
    $workflowJobs = $gitHubApi.GetWorkflowRunJobs($WorkflowRunId)
    Write-WorkflowDiagnostics -WorkflowRun $finishedWorkflowRun -WorkflowJobs $workflowJobs
    if ($finishedWorkflowRun.conclusion -eq "failure") {
        Write-FailedJobLogs -WorkflowJobs $workflowJobs -GitHubApi $gitHubApi -TailLines 0
    }
} catch {
    Write-Host "Failed to fetch workflow job details: $($_.Exception.Message)"
}
"CI_WORKFLOW_RUN_RESULT=$($finishedWorkflowRun.conclusion)" | Out-File -Append -FilePath $env:GITHUB_ENV

if ($finishedWorkflowRun.conclusion -in ("failure", "cancelled", "timed_out")) {
    exit 1
}
