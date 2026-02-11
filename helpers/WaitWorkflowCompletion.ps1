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
} catch {
    Write-Host "Failed to fetch workflow job details: $($_.Exception.Message)"
}
"CI_WORKFLOW_RUN_RESULT=$($finishedWorkflowRun.conclusion)" | Out-File -Append -FilePath $env:GITHUB_ENV

if ($finishedWorkflowRun.conclusion -in ("failure", "cancelled", "timed_out")) {
    exit 1
}
