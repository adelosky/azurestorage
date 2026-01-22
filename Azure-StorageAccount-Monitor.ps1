#Requires -Modules Az.Accounts, Az.Monitor, Az.Storage

<#
.SYNOPSIS
    Azure Storage Accounts Overview Monitoring Script
    
.DESCRIPTION
    PowerShell script that replicates and extends Azure Accounts Overview Workbook functionality.
    Provides comprehensive monitoring across multiple subscriptions using Azure PowerShell cmdlets.
    
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
    .\Azure-StorageAccount-Monitor.ps1 -TimeRange "6h" -OutputFormat "CSV"
    
.EXAMPLE
    .\Azure-StorageAccount-Monitor.ps1 -SubscriptionIds @("sub1", "sub2") -MetricGranularity "PT15M"
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
    [string[]]$IncludeMetrics = @("Transactions", "Availability", "UsedCapacity", "SuccessE2ELatency", "SuccessServerLatency")
)

# Global variables
$script:TotalStorageAccounts = 0
$script:ProcessedAccounts = 0
$script:ErrorAccounts = @()
$script:CollectedData = @()

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
                Get-AzSubscription -SubscriptionId $_ -ErrorAction SilentlyContinue
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
                
                Write-Host "Found $($storageAccounts.Count) storage accounts in subscription: $($subscription.Name)" -ForegroundColor Green
                
                # Convert to consistent format
                foreach ($account in $storageAccounts) {
                    $accountData = [PSCustomObject]@{
                        subscriptionId = $subscription.Id
                        resourceGroup = $account.ResourceGroupName
                        name = $account.StorageAccountName
                        location = $account.Location
                        id = $account.Id
                        kind = $account.Kind
                        sku = @{
                            name = $account.Sku.Name
                            tier = $account.Sku.Tier
                        }
                        properties = @{
                            creationTime = $account.CreationTime
                        }
                    }
                    $allStorageAccounts += $accountData
                }
            }
            catch {
                Write-Warning "Failed to process subscription $($subscription.Name): $($_.Exception.Message)"
                continue
            }
        }
        
        $script:TotalStorageAccounts = $allStorageAccounts.Count
        
        Write-Host "Total storage accounts found across all subscriptions: $($allStorageAccounts.Count)" -ForegroundColor Green
        
        if ($allStorageAccounts.Count -eq 0) {
            Write-Warning "No storage accounts found. Please check your permissions."
        }
        
        return $allStorageAccounts
    }
    catch {
        Write-Error "Failed to discover storage accounts: $($_.Exception.Message)"
        return @()
    }
}

function Get-StorageAccountMetrics {
    param(
        [object]$StorageAccount,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$TimeGrain,
        [string[]]$MetricNames
    )
    
    $script:ProcessedAccounts++
    $percentComplete = if ($script:TotalStorageAccounts -gt 0) { [math]::Round(($script:ProcessedAccounts / $script:TotalStorageAccounts) * 100, 0) } else { 0 }
    
    Write-ProgressUpdate -Activity "Metrics Collection" -Status "Processing $($StorageAccount.name) ($script:ProcessedAccounts/$script:TotalStorageAccounts)" -PercentComplete $percentComplete
    
    $accountMetrics = [PSCustomObject]@{
        SubscriptionId = $StorageAccount.subscriptionId
        ResourceGroup = $StorageAccount.resourceGroup
        StorageAccountName = $StorageAccount.name
        Location = $StorageAccount.location
        Kind = $StorageAccount.kind
        SkuName = $StorageAccount.sku.name
        SkuTier = $StorageAccount.sku.tier
        CreatedTime = $StorageAccount.properties.creationTime
        ResourceId = $StorageAccount.id
        CollectionTime = Get-Date
        Metrics = @{}
        Status = "Success"
        ErrorMessage = $null
    }
    
    try {
        foreach ($metricName in $MetricNames) {
            try {
                $metricData = Get-AzMetric -ResourceId $StorageAccount.id -MetricName $metricName -TimeGrain $TimeGrain -StartTime $StartTime -EndTime $EndTime -ErrorAction Stop
                
                if ($metricData -and $metricData.Data) {
                    $values = $metricData.Data | Where-Object { $null -ne $_.Average -or $null -ne $_.Total -or $null -ne $_.Count }
                    
                    $metricSummary = @{
                        MetricName = $metricName
                        Unit = $metricData.Unit
                        DataPoints = $values.Count
                        Average = if ($values.Average -and $values.Average.Count -gt 0) { ($values.Average | Measure-Object -Average).Average } else { $null }
                        Total = if ($values.Total -and $values.Total.Count -gt 0) { ($values.Total | Measure-Object -Sum).Sum } else { $null }
                        Maximum = if ($values.Maximum -and $values.Maximum.Count -gt 0) { ($values.Maximum | Measure-Object -Maximum).Maximum } else { $null }
                        Minimum = if ($values.Minimum -and $values.Minimum.Count -gt 0) { ($values.Minimum | Measure-Object -Minimum).Minimum } else { $null }
                        LastValue = if ($values.Count -gt 0 -and $values[-1]) { $values[-1].Average -or $values[-1].Total -or $values[-1].Count } else { $null }
                    }
                    
                    $accountMetrics.Metrics[$metricName] = $metricSummary
                }
                else {
                    $accountMetrics.Metrics[$metricName] = @{
                        MetricName = $metricName
                        DataPoints = 0
                        Error = "No data available"
                    }
                }
            }
            catch {
                Write-Warning "Failed to collect $metricName for $($StorageAccount.name): $($_.Exception.Message)"
                $accountMetrics.Metrics[$metricName] = @{
                    MetricName = $metricName
                    Error = $_.Exception.Message
                }
            }
        }
    }
    catch {
        $accountMetrics.Status = "Error"
        $accountMetrics.ErrorMessage = $_.Exception.Message
        $script:ErrorAccounts += $StorageAccount.name
        Write-Warning "Failed to collect metrics for storage account $($StorageAccount.name): $($_.Exception.Message)"
    }
    
    return $accountMetrics
}

function Export-Results {
    param(
        [object[]]$Data,
        [string]$Format,
        [string]$Path
    )
    
    Write-ProgressUpdate -Activity "Export" -Status "Exporting results in $Format format..."
    
    switch ($Format) {
        "CSV" {
            $csvData = @()
            foreach ($account in $Data) {
                $row = [PSCustomObject]@{
                    SubscriptionId = $account.SubscriptionId
                    ResourceGroup = $account.ResourceGroup
                    StorageAccountName = $account.StorageAccountName
                    Location = $account.Location
                    Kind = $account.Kind
                    SkuName = $account.SkuName
                    SkuTier = $account.SkuTier
                    Status = $account.Status
                    ErrorMessage = $account.ErrorMessage
                    CollectionTime = $account.CollectionTime
                }
                
                # Add metric columns
                foreach ($metricName in $account.Metrics.Keys) {
                    $metric = $account.Metrics[$metricName]
                    $row | Add-Member -NotePropertyName "$metricName-Average" -NotePropertyValue $metric.Average
                    $row | Add-Member -NotePropertyName "$metricName-Total" -NotePropertyValue $metric.Total
                    $row | Add-Member -NotePropertyName "$metricName-Maximum" -NotePropertyValue $metric.Maximum
                    $row | Add-Member -NotePropertyName "$metricName-Minimum" -NotePropertyValue $metric.Minimum
                    $row | Add-Member -NotePropertyName "$metricName-DataPoints" -NotePropertyValue $metric.DataPoints
                    $row | Add-Member -NotePropertyName "$metricName-Unit" -NotePropertyValue $metric.Unit
                }
                
                $csvData += $row
            }
            
            $fileName = "StorageAccountMetrics_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
            $filePath = Join-Path $Path $fileName
            $csvData | Export-Csv -Path $filePath -NoTypeInformation
            Write-Host "CSV exported to: $filePath" -ForegroundColor Green
        }
        
        "JSON" {
            $fileName = "StorageAccountMetrics_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
            $filePath = Join-Path $Path $fileName
            $Data | ConvertTo-Json -Depth 10 | Out-File -FilePath $filePath -Encoding utf8
            Write-Host "JSON exported to: $filePath" -ForegroundColor Green
        }
        
        "Console" {
            Write-Host "`n=== AZURE STORAGE ACCOUNTS OVERVIEW ===" -ForegroundColor Yellow
            Write-Host "Collection Time: $(Get-Date)" -ForegroundColor Cyan
            Write-Host "Total Accounts Processed: $($Data.Count)" -ForegroundColor Cyan
            Write-Host "Successful Collections: $(($Data | Where-Object { $_.Status -eq 'Success' }).Count)" -ForegroundColor Green
            Write-Host "Failed Collections: $(($Data | Where-Object { $_.Status -eq 'Error' }).Count)" -ForegroundColor Red
            
            if ($script:ErrorAccounts.Count -gt 0) {
                Write-Host "`nAccounts with Errors:" -ForegroundColor Red
                $script:ErrorAccounts | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
            }
            
            Write-Host "`n=== SUMMARY BY METRIC ===" -ForegroundColor Yellow
            
            $successfulAccounts = $Data | Where-Object { $_.Status -eq 'Success' }
            
            if ($successfulAccounts.Count -gt 0) {
                $sampleAccount = $successfulAccounts[0]
                foreach ($metricName in $sampleAccount.Metrics.Keys) {
                    $metricValues = $successfulAccounts | ForEach-Object { $_.Metrics[$metricName] } | Where-Object { $null -ne $_.Average -or $null -ne $_.Total }
                    
                    if ($metricValues.Count -gt 0) {
                        Write-Host "`n--- $metricName ---" -ForegroundColor Cyan
                        
                        if ($null -ne $metricValues[0].Average) {
                            $avgValues = $metricValues | Where-Object { $null -ne $_.Average } | ForEach-Object { $_.Average }
                            if ($avgValues.Count -gt 0) {
                                Write-Host "  Average across accounts: $([math]::Round(($avgValues | Measure-Object -Average).Average, 2))" -ForegroundColor White
                                Write-Host "  Max: $([math]::Round(($avgValues | Measure-Object -Maximum).Maximum, 2))" -ForegroundColor White
                                Write-Host "  Min: $([math]::Round(($avgValues | Measure-Object -Minimum).Minimum, 2))" -ForegroundColor White
                            }
                        }
                        
                        if ($null -ne $metricValues[0].Total) {
                            $totalValues = $metricValues | Where-Object { $null -ne $_.Total } | ForEach-Object { $_.Total }
                            if ($totalValues.Count -gt 0) {
                                Write-Host "  Total across accounts: $([math]::Round(($totalValues | Measure-Object -Sum).Sum, 2))" -ForegroundColor White
                            }
                        }
                        
                        $unit = $metricValues[0].Unit
                        if ($unit) {
                            Write-Host "  Unit: $unit" -ForegroundColor Gray
                        }
                    }
                }
                
                Write-Host "`n=== TOP STORAGE ACCOUNTS BY TRANSACTIONS ===" -ForegroundColor Yellow
                $topByTransactions = $successfulAccounts | 
                    Where-Object { $_.Metrics.Transactions -and $null -ne $_.Metrics.Transactions.Total } |
                    Sort-Object { $_.Metrics.Transactions.Total } -Descending |
                    Select-Object -First 10
                
                foreach ($account in $topByTransactions) {
                    $transactions = [math]::Round($account.Metrics.Transactions.Total, 0)
                    Write-Host "  $($account.StorageAccountName): $transactions transactions" -ForegroundColor White
                }
            }
        }
        
        "LogAnalytics" {
            Write-Host "LogAnalytics export not implemented in this version. Use JSON format and import to Log Analytics." -ForegroundColor Yellow
        }
    }
}

#endregion

#region Main Execution

function Main {
    Write-Host "=== Azure Storage Accounts Overview Monitor ===" -ForegroundColor Yellow
    Write-Host "Starting at $(Get-Date)" -ForegroundColor Cyan
    Write-Host "Time Range: $TimeRange | Granularity: $MetricGranularity | Format: $OutputFormat" -ForegroundColor Cyan
    
    # Test Azure connection
    if (-not (Test-AzureConnection)) {
        Write-Error "Azure connection test failed. Please ensure you are logged in with Connect-AzAccount."
        return
    }
    
    # Calculate time range
    $timeRange = Convert-TimeRangeToDateTime -TimeRange $TimeRange
    Write-Host "Collecting metrics from $($timeRange.StartTime) to $($timeRange.EndTime)" -ForegroundColor Cyan
    
    # Discover storage accounts
    $storageAccounts = Get-AllStorageAccounts -SubscriptionIds $SubscriptionIds
    
    if ($storageAccounts.Count -eq 0) {
        Write-Warning "No storage accounts found. Exiting."
        return
    }
    
    Write-Host "Metrics to collect: $($IncludeMetrics -join ', ')" -ForegroundColor Cyan
    
    # Collect metrics for each storage account
    $script:CollectedData = @()
    
    foreach ($storageAccount in $storageAccounts) {
        $accountMetrics = Get-StorageAccountMetrics -StorageAccount $storageAccount -StartTime $timeRange.StartTime -EndTime $timeRange.EndTime -TimeGrain $MetricGranularity -MetricNames $IncludeMetrics
        $script:CollectedData += $accountMetrics
    }
    
    # Export results
    Export-Results -Data $script:CollectedData -Format $OutputFormat -Path $OutputPath
    
    Write-Host "`n=== Monitoring Complete ===" -ForegroundColor Green
    Write-Host "Total processing time: $((Get-Date) - $startTime)" -ForegroundColor Cyan
    Write-Host "Successfully processed: $(($script:CollectedData | Where-Object { $_.Status -eq 'Success' }).Count)/$($script:CollectedData.Count) storage accounts" -ForegroundColor Green
}

# Script entry point
$startTime = Get-Date

try {
    Main
}
catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
}
finally {
    Write-Progress -Activity "Monitoring" -Completed
}

#endregion