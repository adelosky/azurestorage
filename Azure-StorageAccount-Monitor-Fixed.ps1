#Requires -Modules Az.Accounts, Az.Monitor, Az.Storage

<#
.SYNOPSIS
    Azure Storage Accounts Overview Monitoring Script (Fixed Version)
    
.DESCRIPTION
    PowerShell script that replicates and extends Azure Accounts Overview Workbook functionality.
    Provides comprehensive monitoring across multiple subscriptions using Azure PowerShell cmdlets.
    
    FIXES:
    - TimeGrain parameter conversion from ISO 8601 to PowerShell TimeSpan
    - Added better error handling and retry logic
    - Improved progress reporting
    
.PARAMETER SubscriptionIds
    Array of subscription IDs to monitor. If not specified, monitors all accessible subscriptions.
    
.PARAMETER TimeRange
    Time range for metrics collection. Valid values: 1h, 6h, 12h, 1d, 7d, 30d. Default: 1d
    
.PARAMETER MetricGranularity
    Metric time granularity. Valid values: PT1M, PT5M, PT15M, PT1H, P1D. Default: PT1H
    
.PARAMETER OutputFormat
    Output format. Valid values: CSV, JSON, Console, LogAnalytics. Default: Console
    
.PARAMETER OutputPath
    Output file path for CSV/JSON exports. Default: Current directory
    
.PARAMETER IncludeMetrics
    Array of metrics to collect. Default: All core metrics
    
.EXAMPLE
    .\Azure-StorageAccount-Monitor-Fixed.ps1 -TimeRange "6h" -OutputFormat "CSV"
    
.EXAMPLE
    .\Azure-StorageAccount-Monitor-Fixed.ps1 -SubscriptionIds @("sub1", "sub2") -MetricGranularity "PT15M"
#>

param(
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("1h", "6h", "12h", "1d", "7d", "30d")]
    [string]$TimeRange = "1d",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("PT1M", "PT5M", "PT15M", "PT1H", "P1D")]
    [string]$MetricGranularity = "PT1H",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("CSV", "JSON", "Console", "LogAnalytics")]
    [string]$OutputFormat = "Console",
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",
    
    [Parameter(Mandatory = $false)]
    [string[]]$IncludeMetrics = @("Transactions", "Availability", "UsedCapacity", "SuccessE2ELatency", "SuccessServerLatency"),

    [Parameter(Mandatory = $false)]
    [switch]$ContinueOnError = $false,

    [Parameter(Mandatory = $false)]
    [int]$MaxRetries = 3,

    [Parameter(Mandatory = $false)]
    [int]$RetryDelaySeconds = 5
)

# Global variables
$script:TotalStorageAccounts = 0
$script:ProcessedAccounts = 0
$script:ErrorAccounts = @()
$script:CollectedData = @()
$script:SuccessfullyProcessed = 0
$script:FailedToProcess = 0

#region Helper Functions

function Write-ProgressUpdate {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete = -1
    )
    
    if ($PercentComplete -ge 0) {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
    } else {
        Write-Progress -Activity $Activity -Status $Status
    }
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Status" -ForegroundColor Cyan
}

function Convert-TimeRangeToDateTime {
    param([string]$TimeRange)
    
    $endTime = Get-Date
    $startTime = switch ($TimeRange) {
        "1h" { $endTime.AddHours(-1) }
        "6h" { $endTime.AddHours(-6) }
        "12h" { $endTime.AddHours(-12) }
        "1d" { $endTime.AddDays(-1) }
        "7d" { $endTime.AddDays(-7) }
        "30d" { $endTime.AddDays(-30) }
        default { $endTime.AddDays(-1) }
    }
    
    return @{
        StartTime = $startTime
        EndTime = $endTime
    }
}

function Convert-ISO8601ToTimeSpan {
    param([string]$ISO8601Duration)
    
    # Convert ISO 8601 duration strings to PowerShell TimeSpan objects
    switch ($ISO8601Duration) {
        "PT1M" { return New-TimeSpan -Minutes 1 }
        "PT5M" { return New-TimeSpan -Minutes 5 }
        "PT15M" { return New-TimeSpan -Minutes 15 }
        "PT1H" { return New-TimeSpan -Hours 1 }
        "P1D" { return New-TimeSpan -Days 1 }
        default { 
            Write-Warning "Unknown granularity: $ISO8601Duration, defaulting to 1 hour"
            return New-TimeSpan -Hours 1 
        }
    }
}

function Test-AzureConnection {
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Host "No Azure context found. Please run Connect-AzAccount first." -ForegroundColor Red
            return $false
        }
        
        Write-Host "Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
        Write-Host "Current subscription: $($context.Subscription.Name)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Failed to verify Azure connection: $($_.Exception.Message)"
        return $false
    }
}

function Get-AllStorageAccounts {
    param([string[]]$SubscriptionIds)
    
    Write-ProgressUpdate -Activity "Discovery" -Status "Discovering storage accounts across subscriptions..."
    
    try {
        $allStorageAccounts = @()
        
        # Get list of subscriptions to process
        if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
            $subscriptions = $SubscriptionIds | ForEach-Object {
                try {
                    Get-AzSubscription -SubscriptionId $_ -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Warning "Failed to access subscription $_: $($_.Exception.Message)"
                    $null
                }
            } | Where-Object { $null -ne $_ }
        } else {
            $subscriptions = Get-AzSubscription
        }
        
        if (-not $subscriptions) {
            Write-Warning "No accessible subscriptions found."
            return @()
        }
        
        Write-Host "Processing $($subscriptions.Count) subscription(s)" -ForegroundColor Cyan
        
        foreach ($subscription in $subscriptions) {
            Write-ProgressUpdate -Activity "Discovery" -Status "Processing subscription: $($subscription.Name)"
            
            try {
                # Set context to current subscription
                Set-AzContext -SubscriptionId $subscription.Id | Out-Null
                
                # Get storage accounts in this subscription
                $storageAccounts = Get-AzStorageAccount
                
                if ($storageAccounts) {
                    foreach ($storageAccount in $storageAccounts) {
                        $allStorageAccounts += [PSCustomObject]@{
                            StorageAccount = $storageAccount
                            SubscriptionId = $subscription.Id
                            SubscriptionName = $subscription.Name
                        }
                    }
                    Write-Host "Found $($storageAccounts.Count) storage accounts in subscription: $($subscription.Name)" -ForegroundColor Green
                } else {
                    Write-Host "Found 0 storage accounts in subscription: $($subscription.Name)" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Warning "Failed to process subscription $($subscription.Name): $($_.Exception.Message)"
                if (-not $ContinueOnError) {
                    throw
                }
            }
        }
        
        $script:TotalStorageAccounts = $allStorageAccounts.Count
        
        Write-Host "Total storage accounts found across all subscriptions: $($allStorageAccounts.Count)" -ForegroundColor Green
        
        if ($allStorageAccounts.Count -eq 0) {
            Write-Warning "No storage accounts found in any accessible subscriptions."
        }
        
        return $allStorageAccounts
    }
    catch {
        Write-Error "Failed to discover storage accounts: $($_.Exception.Message)"
        throw
    }
}

function Get-StorageAccountMetrics {
    param(
        [PSCustomObject]$StorageAccountInfo,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [System.TimeSpan]$TimeGrain,
        [string[]]$MetricNames,
        [int]$RetryCount = 0
    )
    
    $script:ProcessedAccounts++
    $storageAccount = $StorageAccountInfo.StorageAccount
    $percentComplete = [Math]::Round(($script:ProcessedAccounts / $script:TotalStorageAccounts) * 100, 2)
    
    Write-ProgressUpdate -Activity "Metrics Collection" -Status "Processing $($storageAccount.StorageAccountName) ($script:ProcessedAccounts/$script:TotalStorageAccounts)" -PercentComplete $percentComplete
    
    try {
        # Set context to the correct subscription for this storage account
        Set-AzContext -SubscriptionId $StorageAccountInfo.SubscriptionId | Out-Null
        
        $metricsData = @{}
        $resourceId = $storageAccount.Id
        
        foreach ($metricName in $MetricNames) {
            try {
                # Retry logic for individual metrics
                $currentRetry = 0
                $metricCollected = $false
                
                while (-not $metricCollected -and $currentRetry -le $MaxRetries) {
                    try {
                        $metrics = Get-AzMetric -ResourceId $resourceId -MetricName $metricName -StartTime $StartTime -EndTime $EndTime -TimeGrain $TimeGrain -ErrorAction Stop
                        
                        if ($metrics -and $metrics.Data) {
                            $latestValue = $metrics.Data | Sort-Object TimeStamp -Descending | Select-Object -First 1
                            
                            if ($latestValue) {
                                # Determine which property to use based on metric type
                                $value = $null
                                if ($null -ne $latestValue.Average) { $value = $latestValue.Average }
                                elseif ($null -ne $latestValue.Total) { $value = $latestValue.Total }
                                elseif ($null -ne $latestValue.Maximum) { $value = $latestValue.Maximum }
                                elseif ($null -ne $latestValue.Count) { $value = $latestValue.Count }
                                
                                $metricsData[$metricName] = @{
                                    Value = $value
                                    Unit = $metrics.Unit
                                    TimeStamp = $latestValue.TimeStamp
                                }
                            } else {
                                $metricsData[$metricName] = @{
                                    Value = $null
                                    Unit = "No data"
                                    TimeStamp = $null
                                }
                            }
                        } else {
                            $metricsData[$metricName] = @{
                                Value = $null
                                Unit = "No data"
                                TimeStamp = $null
                            }
                        }
                        $metricCollected = $true
                    }
                    catch {
                        $currentRetry++
                        if ($currentRetry -le $MaxRetries) {
                            Write-Warning "Retry $currentRetry/$MaxRetries for metric $metricName on $($storageAccount.StorageAccountName): $($_.Exception.Message)"
                            Start-Sleep -Seconds $RetryDelaySeconds
                        } else {
                            Write-Warning "Failed to collect $metricName for $($storageAccount.StorageAccountName) after $MaxRetries retries: $($_.Exception.Message)"
                            $metricsData[$metricName] = @{
                                Value = "Error"
                                Unit = "Error"
                                TimeStamp = $null
                                Error = $_.Exception.Message
                            }
                        }
                    }
                }
            }
            catch {
                Write-Warning "Failed to collect $metricName for $($storageAccount.StorageAccountName): $($_.Exception.Message)"
                $metricsData[$metricName] = @{
                    Value = "Error"
                    Unit = "Error"
                    TimeStamp = $null
                    Error = $_.Exception.Message
                }
            }
        }
        
        # Create result object
        $result = [PSCustomObject]@{
            SubscriptionId = $StorageAccountInfo.SubscriptionId
            SubscriptionName = $StorageAccountInfo.SubscriptionName
            StorageAccountName = $storageAccount.StorageAccountName
            ResourceGroupName = $storageAccount.ResourceGroupName
            Location = $storageAccount.Location
            SkuName = $storageAccount.Sku.Name
            Kind = $storageAccount.Kind
            AccessTier = $storageAccount.AccessTier
            EnableHttpsTrafficOnly = $storageAccount.EnableHttpsTrafficOnly
            CreationTime = $storageAccount.CreationTime
        }
        
        # Add metrics data to result
        foreach ($metricName in $MetricNames) {
            $metricData = $metricsData[$metricName]
            $result | Add-Member -NotePropertyName "$metricName`_Value" -NotePropertyValue $metricData.Value
            $result | Add-Member -NotePropertyName "$metricName`_Unit" -NotePropertyValue $metricData.Unit
            $result | Add-Member -NotePropertyName "$metricName`_TimeStamp" -NotePropertyValue $metricData.TimeStamp
            
            if ($metricData.Error) {
                $result | Add-Member -NotePropertyName "$metricName`_Error" -NotePropertyValue $metricData.Error
            }
        }
        
        $script:CollectedData += $result
        $script:SuccessfullyProcessed++
        
        return $result
    }
    catch {
        $script:FailedToProcess++
        $errorInfo = @{
            StorageAccountName = $storageAccount.StorageAccountName
            SubscriptionName = $StorageAccountInfo.SubscriptionName
            Error = $_.Exception.Message
        }
        $script:ErrorAccounts += $errorInfo
        
        Write-Error "Failed to process storage account $($storageAccount.StorageAccountName): $($_.Exception.Message)"
        
        if (-not $ContinueOnError) {
            throw
        }
        
        return $null
    }
}

function Export-Results {
    param(
        [array]$Data,
        [string]$Format,
        [string]$OutputPath
    )
    
    if (-not $Data -or $Data.Count -eq 0) {
        Write-Warning "No data to export."
        return
    }
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    
    switch ($Format) {
        "CSV" {
            $fileName = "Azure_StorageAccount_Metrics_$timestamp.csv"
            $fullPath = Join-Path $OutputPath $fileName
            $Data | Export-Csv -Path $fullPath -NoTypeInformation
            Write-Host "Data exported to: $fullPath" -ForegroundColor Green
        }
        "JSON" {
            $fileName = "Azure_StorageAccount_Metrics_$timestamp.json"
            $fullPath = Join-Path $OutputPath $fileName
            $Data | ConvertTo-Json -Depth 10 | Out-File -FilePath $fullPath
            Write-Host "Data exported to: $fullPath" -ForegroundColor Green
        }
        "Console" {
            Write-Host "`n=== Storage Account Metrics Summary ===" -ForegroundColor Green
            $Data | Format-Table -AutoSize
        }
        "LogAnalytics" {
            # Placeholder for Log Analytics integration
            Write-Host "Log Analytics export not yet implemented." -ForegroundColor Yellow
        }
    }
}

function Show-Summary {
    Write-Host "`n=== Execution Summary ===" -ForegroundColor Cyan
    Write-Host "Total storage accounts found: $script:TotalStorageAccounts" -ForegroundColor White
    Write-Host "Successfully processed: $script:SuccessfullyProcessed" -ForegroundColor Green
    Write-Host "Failed to process: $script:FailedToProcess" -ForegroundColor Red
    
    if ($script:ErrorAccounts.Count -gt 0) {
        Write-Host "`nFailed Storage Accounts:" -ForegroundColor Red
        $script:ErrorAccounts | Format-Table -AutoSize
    }
    
    $endTime = Get-Date
    Write-Host "`nScript completed at: $endTime" -ForegroundColor Cyan
}

#endregion

#region Main Execution

try {
    Write-Host "=== Azure Storage Accounts Overview Monitor (Fixed Version) ===" -ForegroundColor Cyan
    $startTime = Get-Date
    Write-Host "Starting at $startTime" -ForegroundColor Cyan
    Write-Host "Time Range: $TimeRange | Granularity: $MetricGranularity | Format: $OutputFormat" -ForegroundColor Cyan
    
    # Test Azure connection
    if (-not (Test-AzureConnection)) {
        throw "Azure connection test failed. Please ensure you're logged in with Connect-AzAccount."
    }
    
    # Convert time range to datetime objects
    $timeInfo = Convert-TimeRangeToDateTime -TimeRange $TimeRange
    Write-Host "Collecting metrics from $($timeInfo.StartTime) to $($timeInfo.EndTime)" -ForegroundColor Cyan
    
    # Convert granularity to TimeSpan object
    $timeGrain = Convert-ISO8601ToTimeSpan -ISO8601Duration $MetricGranularity
    Write-Host "Using TimeGrain: $timeGrain" -ForegroundColor Cyan
    
    # Discover storage accounts
    $storageAccountsInfo = Get-AllStorageAccounts -SubscriptionIds $SubscriptionIds
    
    if (-not $storageAccountsInfo -or $storageAccountsInfo.Count -eq 0) {
        Write-Warning "No storage accounts found to process."
        return
    }
    
    Write-Host "Metrics to collect: $($IncludeMetrics -join ', ')" -ForegroundColor Cyan
    
    # Collect metrics for each storage account
    foreach ($storageAccountInfo in $storageAccountsInfo) {
        try {
            Get-StorageAccountMetrics -StorageAccountInfo $storageAccountInfo -StartTime $timeInfo.StartTime -EndTime $timeInfo.EndTime -TimeGrain $timeGrain -MetricNames $IncludeMetrics
        }
        catch {
            if (-not $ContinueOnError) {
                throw
            }
        }
    }
    
    # Export results
    Export-Results -Data $script:CollectedData -Format $OutputFormat -OutputPath $OutputPath
    
    # Show summary
    Show-Summary
}
catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    Show-Summary
    exit 1
}
finally {
    Write-Progress -Activity "Processing" -Completed
}

#endregion