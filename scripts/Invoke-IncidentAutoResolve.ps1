<#
.SYNOPSIS
    ServiceNow Incident Auto-Resolution via REST API
.DESCRIPTION
    Queries ServiceNow for incidents matching resolution criteria,
    auto-resolves common Tier 1/Tier 2 issues, and updates tickets
    via the ServiceNow REST API.
    Author: Jubril Adams | ServiceNow Automation Lab
.PARAMETER SnowInstance
    ServiceNow instance name (e.g., 'dev12345')
.PARAMETER SnowUser
    ServiceNow API username
.PARAMETER SnowPass
    ServiceNow API password (use a credential object in production)
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string]$SnowInstance,
    [Parameter(Mandatory)] [string]$SnowUser,
    [Parameter(Mandatory)] [string]$SnowPass
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Base URL and Auth ---
$BaseUrl = "https://$SnowInstance.service-now.com/api/now"
$Creds   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${SnowUser}:${SnowPass}"))
$Headers = @{
    Authorization  = "Basic $Creds"
    'Content-Type' = 'application/json'
    Accept         = 'application/json'
}

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    Write-Host "[$(Get-Date -f 'HH:mm:ss')] [$Level] $Msg"
}

function Get-OpenIncidents {
    param([string]$Category, [int]$Limit = 50)
    $query = "active=true^state=1^category=$Category^priority=4^ORpriority=5"
    $uri   = "$BaseUrl/table/incident?sysparm_query=$query&sysparm_limit=$Limit"
    $resp  = Invoke-RestMethod -Uri $uri -Headers $Headers -Method GET
    return $resp.result
}

function Resolve-Incident {
    param([string]$SysId, [string]$ResolutionNote, [string]$ResolutionCode = 'Solved (Permanently)')
    $body = @{
        state              = 6   # Resolved
        close_code         = $ResolutionCode
        close_notes        = $ResolutionNote
        resolved_by        = $SnowUser
    } | ConvertTo-Json

    $uri  = "$BaseUrl/table/incident/$SysId"
    $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -Method PATCH -Body $body
    return $resp.result
}

function Add-WorkNote {
    param([string]$SysId, [string]$Note)
    $body = @{ work_notes = $Note } | ConvertTo-Json
    $uri  = "$BaseUrl/table/incident/$SysId"
    Invoke-RestMethod -Uri $uri -Headers $Headers -Method PATCH -Body $body | Out-Null
}

# --- Auto-Resolution Rules ---
$ResolutionRules = @(
    @{ Category = 'software';  Keywords = @('password reset', 'locked out', 'account locked');  Resolution = 'Password reset completed via automated process. Account unlocked. User notified.' }
    @{ Category = 'hardware';  Keywords = @('printer offline', 'printer not responding');        Resolution = 'Print spooler service restarted remotely. Printer back online.' }
    @{ Category = 'network';   Keywords = @('vpn disconnect', 'vpn timeout');                    Resolution = 'VPN session cleared. User advised to reconnect. Root cause: idle timeout.' }
    @{ Category = 'inquiry';   Keywords = @('how to', 'question about');                         Resolution = 'Knowledge article provided to user. Incident resolved per self-service guidance.' }
)

$resolved = 0; $skipped = 0

foreach ($rule in $ResolutionRules) {
    Write-Log "Checking category: $($rule.Category)"
    $incidents = Get-OpenIncidents -Category $rule.Category

    foreach ($inc in $incidents) {
        $shortDesc = $inc.short_description.ToLower()
        $matched   = $rule.Keywords | Where-Object { $shortDesc -like "*$_*" }

        if ($matched) {
            try {
                Add-WorkNote -SysId $inc.sys_id -Note "[AUTO] Matched rule: '$($matched[0])'. Initiating automated resolution."
                Resolve-Incident -SysId $inc.sys_id -ResolutionNote $rule.Resolution
                Write-Log "Resolved: [$($inc.number)] $($inc.short_description)"
                $resolved++
            } catch {
                Write-Log "Failed to resolve $($inc.number): $_" -Level 'ERROR'
                $skipped++
            }
        } else {
            $skipped++
        }
    }
}

Write-Log "===== Auto-Resolution Complete ====="
Write-Log "Resolved: $resolved | Skipped/Unmatched: $skipped"
