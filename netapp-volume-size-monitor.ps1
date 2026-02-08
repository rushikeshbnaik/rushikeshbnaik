param(
    [Parameter(Mandatory = $true)]
    [string]$Cluster,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [double]$UsedPercentThreshold = 90,

    [double]$AvailableSpaceThresholdGB = 500,

    [switch]$SkipCertificateValidation
)

if ($SkipCertificateValidation) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$baseUri = "https://$Cluster/api/storage/volumes"
$authPair = "{0}:{1}" -f $Username, $Password
$authToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($authPair))
$headers = @{
    Authorization = "Basic $authToken"
    Accept        = "application/json"
}

function Get-BytesToGB {
    param([double]$Bytes)
    return [Math]::Round(($Bytes / 1GB), 2)
}

try {
    $response = Invoke-RestMethod -Method Get -Uri "$baseUri?fields=name,svm.name,space,size,uuid" -Headers $headers
}
catch {
    Write-Error "Failed to query NetApp cluster '$Cluster'. $($_.Exception.Message)"
    exit 1
}

if (-not $response.records) {
    Write-Host "No volumes found on cluster $Cluster."
    exit 0
}

$alertVolumes = foreach ($vol in $response.records) {
    $totalBytes = [double]$vol.space.size
    $availableBytes = [double]$vol.space.available

    if ($totalBytes -le 0) {
        continue
    }

    $usedPercent = [Math]::Round((($totalBytes - $availableBytes) / $totalBytes) * 100, 2)
    $availableGB = Get-BytesToGB -Bytes $availableBytes

    if ($usedPercent -gt $UsedPercentThreshold -and $availableGB -lt $AvailableSpaceThresholdGB) {
        [PSCustomObject]@{
            Cluster          = $Cluster
            SVM              = $vol.svm.name
            Volume           = $vol.name
            UsedPercent      = $usedPercent
            AvailableSpaceGB = $availableGB
            TotalSpaceGB     = Get-BytesToGB -Bytes $totalBytes
            UUID             = $vol.uuid
        }
    }
}

if (-not $alertVolumes) {
    Write-Host "No volumes matched alert criteria (Used > $UsedPercentThreshold% and Available < $AvailableSpaceThresholdGB GB)."
    exit 0
}

Write-Host "Volumes requiring attention:"
$alertVolumes | Sort-Object UsedPercent -Descending | Format-Table -AutoSize

# Uncomment this line if you want script exits non-zero when alert condition exists
# exit 2
