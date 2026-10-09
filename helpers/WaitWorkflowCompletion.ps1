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

function Test-FailedConclusion($Conclusion) {
    return $Conclusion -notin ("success", "skipped", "neutral", $null)
}

function Get-JobErrorMessage($JobId) {
    # Report only failure annotations (exit code, timeout, cancellation) instead of the job log,
    # since the log of the private CI repository must not be exposed in public PR checks
    try {
        $annotations = $gitHubApi.GetCheckRunAnnotations($JobId)
    } catch {
        Write-Warning "Unable to get annotations for job ${JobId}: $($_.Exception.Message)"
        return
    }

    $annotations | Where-Object { $_.annotation_level -eq "failure" -and $_.message } | ForEach-Object { "$($_.message)".Trim() }
}

function Write-WorkflowFailureDetails($WorkflowRun) {
    $failedJobs = $gitHubApi.GetWorkflowRunJobs($WorkflowRun.id).jobs | Where-Object { Test-FailedConclusion $_.conclusion }

    if (-not $failedJobs) {
        Write-Host "::error title=Remote CI failed::Workflow run finished with result '$($WorkflowRun.conclusion)', but no failed jobs were found."
        return
    }

    "## Remote CI failure details" | Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
    foreach ($job in $failedJobs) {
        $failedSteps = @($job.steps | Where-Object { Test-FailedConclusion $_.conclusion })
        $jobErrorMessages = @(Get-JobErrorMessage -JobId $job.id)

        "- [$($job.name)]($($job.html_url)): $($job.conclusion)" | Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
        foreach ($step in $failedSteps) {
            "  - Step ``$($step.name)``: $($step.conclusion)" | Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
        }
        foreach ($jobErrorMessage in $jobErrorMessages) {
            "  - Error: $($jobErrorMessage -replace '\s+', ' ')" | Out-File -Append -FilePath $env:GITHUB_STEP_SUMMARY
        }

        if ($failedSteps) {
            $errorLines = @($failedSteps | ForEach-Object { "Job '$($job.name)', step '$($_.name)': $($_.conclusion)" })
        } else {
            $errorLines = @("Job '$($job.name)': $($job.conclusion)")
        }
        $errorMessage = ($errorLines + $jobErrorMessages) -join "`n"
        Write-Host "::error title=Remote CI failed::$(ConvertTo-WorkflowCommandValue $errorMessage)"
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
    try {
        Write-WorkflowFailureDetails -WorkflowRun $finishedWorkflowRun
    } catch {
        $errorMessage = "Workflow run finished with result '$($finishedWorkflowRun.conclusion)'. Unable to get failure details: $($_.Exception.Message)"
        Write-Host "::error title=Remote CI failed::$(ConvertTo-WorkflowCommandValue $errorMessage)"
    }
    exit 1
}
