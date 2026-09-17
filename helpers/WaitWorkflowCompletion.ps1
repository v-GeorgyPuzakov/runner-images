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

function ConvertTo-WorkflowCommandValue($Value) {
    return "$Value".Replace("%", "%25").Replace("`r", "%0D").Replace("`n", "%0A")
}

function Write-WorkflowFailureDetails($WorkflowRunId) {
    $failedJobs = $gitHubApi.GetWorkflowRunJobs($WorkflowRunId).jobs | Where-Object {
        $_.conclusion -notin ("success", "skipped", $null)
    }

    if (-not $failedJobs) {
        Write-Host "::error title=Remote CI failed::No failed job details were returned."
        return
    }

    "## Remote CI failure details" | Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
    foreach ($job in $failedJobs) {
        "- [$($job.name)]($($job.html_url)): $($job.conclusion)" | Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY

        $failedSteps = $job.steps | Where-Object { $_.conclusion -notin ("success", "skipped", $null) }
        foreach ($step in $failedSteps) {
            "  - Step ``$($step.name)``: $($step.conclusion)" | Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
            $errorMessage = "Job '$($job.name)', step '$($step.name)': $($step.conclusion)"
            Write-Host "::error title=Remote CI failed::$(ConvertTo-WorkflowCommandValue $errorMessage)"
        }
    }
}

$gitHubApi = Get-GithubApi -Repository $Repository -AccessToken $AccessToken

$attempt = 1
do {
    $finishedWorkflowRun = Wait-ForWorkflowCompletion -WorkflowRunId $WorkflowRunId -RetryIntervalSeconds $RetryIntervalSeconds
    Write-Host "Workflow run finished with result: $($finishedWorkflowRun.conclusion)"
    if ($finishedWorkflowRun.conclusion -eq "success") {
        break
    } elseif ($finishedWorkflowRun.conclusion -eq "failure") {
        if ($attempt -le $MaxRetryCount) {
            Write-Host "Workflow run will be restarted. Attempt $attempt of $MaxRetryCount"
            $gitHubApi.ReRunFailedJobs($WorkflowRunId)
            $attempt += 1
        } else {
            break
        }
    } else {
        break
    }
} while ($true)

Write-Host "Last result: $($finishedWorkflowRun.conclusion)."
"CI_WORKFLOW_RUN_RESULT=$($finishedWorkflowRun.conclusion)" | Out-File -Append -FilePath $env:GITHUB_ENV

if ($finishedWorkflowRun.conclusion -ne "success") {
    Write-WorkflowFailureDetails -WorkflowRunId $WorkflowRunId
    exit 1
}
