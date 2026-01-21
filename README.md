# azurestorage
Tools and scripts to manage Azure Storage Accounts and Containers

Plan: Azure Storage Accounts Monitoring PowerShell Script
A comprehensive PowerShell solution that replicates and extends Azure Accounts Overview Workbook functionality, overcoming the 200 storage account limitation through Azure Resource Graph and batch monitoring techniques.

Steps
Set up Azure authentication and module dependencies - Install Az.ResourceGraph, Az.Monitor, Az.Storage modules and establish authenticated sessions across subscriptions
Implement resource discovery using Azure Resource Graph - Query all storage accounts across subscriptions using KQL to bypass the 200-account workbook limit
Create batch metric collection functions - Build PowerShell functions using Get-AzMetricsBatch for efficient parallel collection of availability, capacity, transactions, and latency metrics
Design data processing and aggregation logic - Process collected metrics into workbook-compatible format with error handling, success rates, and performance calculations
Build export capabilities for custom workbook integration - Generate CSV/JSON outputs and Azure Monitor custom logs that can feed new Azure Workbooks or dashboards
Implement scheduling and automation framework - Create runbook-ready script with configurable intervals, logging, and alert integration for production deployment

Further Considerations
Metric scope and frequency: Should we focus on specific metrics (transactions, capacity, availability) or collect comprehensive data? Hourly vs daily collection intervals?
Output format preference: Export to CSV for Excel analysis, JSON for custom dashboards, or direct Log Analytics ingestion for Azure Workbook integration?
Authentication approach: Service principal for automation, managed identity in Azure Automation, or interactive authentication for manual runs?
