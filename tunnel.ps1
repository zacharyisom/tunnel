<#
.SYNOPSIS
  Start Cloudflare Quick Tunnel (detached), capture a *.trycloudflare.com URL, and update index.html via GitHub API.
.NOTES
  - PowerShell 7+ recommended.
  - Uses env vars GITHUB_USER, GITHUB_REPO, GITHUB_PAT (will prompt + setx if missing).
  - index.html assumed at repo root and containing a meta-refresh tag.
  - cloudflared is started detached and hidden; logs are written to a tempfile which the script reads.
#>

# ---------- Helpers ----------
function Write-Color { param($Text, $Color='White'); Write-Host $Text -ForegroundColor $Color }

function Get-OrSetEnv {
    param([string]$Name,[string]$PromptText=$null,[bool]$Secret=$false)
    $val = [Environment]::GetEnvironmentVariable($Name,'User')
    if (-not $val -or $val.Trim() -eq '') {
        if ($Secret) {
            $secure = Read-Host -Prompt $PromptText -AsSecureString
            $val = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        } else {
            $val = Read-Host -Prompt $PromptText
        }
        if ($val) { setx $Name $val | Out-Null; [Environment]::SetEnvironmentVariable($Name,$val,'Process') }
    }
    return $val
}

Clear-Host
Write-Color "=== Cloudflare Quick Tunnel → GitHub index.html updater ===`n" Cyan

# ---------- GitHub settings ----------
$GITHUB_USER   = Get-OrSetEnv -Name 'GITHUB_USER' -PromptText 'GitHub username (owner)'
$GITHUB_REPO   = Get-OrSetEnv -Name 'GITHUB_REPO' -PromptText 'GitHub repository name (repo)'
$GITHUB_PAT    = Get-OrSetEnv -Name 'GITHUB_PAT' -PromptText 'GitHub Personal Access Token (scopes: repo or public_repo)' -Secret $true
$GITHUB_BRANCH = [Environment]::GetEnvironmentVariable('GITHUB_BRANCH','User')
if (-not $GITHUB_BRANCH) { $GITHUB_BRANCH='main'; setx GITHUB_BRANCH $GITHUB_BRANCH | Out-Null }

if (-not $GITHUB_USER -or -not $GITHUB_REPO -or -not $GITHUB_PAT) {
    Write-Color "Missing GitHub settings. Aborting." Red
    exit 1
}

$FilePath = 'index.html'
$ApiUrl   = "https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO/contents/$FilePath"

# ---------- Ensure cloudflared ----------
Write-Color "`n[1/5] Checking for cloudflared..." Yellow
$cloudCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
if (-not $cloudCmd) {
    Write-Color "cloudflared not found. Installing via winget..." Yellow
    try {
        Start-Process winget -ArgumentList 'install','--id','Cloudflare.cloudflared','-e' -NoNewWindow -Wait -ErrorAction Stop
    } catch {
        Write-Color "Failed to install cloudflared via winget. Please install manually and re-run." Red
        exit 1
    }
    $cloudCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cloudCmd) { Write-Color "cloudflared still not found after install. Restart shell or provide full path." Red; exit 1 }
}
$cloudPath = $cloudCmd.Path
Write-Color "cloudflared found: $cloudPath" Green

# ---------- Start cloudflared DETACHED (hidden) ----------
# It will still write logs to $logFile, but will not write to this console.
$logFile = Join-Path $env:TEMP ("cloudflared_quicktunnel_" + (Get-Random) + ".log")
New-Item -Path $logFile -ItemType File -Force | Out-Null

$cloudArgs = @('tunnel','--url','http://localhost:8080','--loglevel','info','--logfile',$logFile)

Write-Color "`n[2/5] Starting cloudflared (detached; logs -> $logFile)..." Yellow
try {
    # DON'T use -NoNewWindow: that can keep cloudflared attached to this console.
    # Use -WindowStyle Hidden to run it without visible window. Start-Process without -NoNewWindow detaches.
    $proc = Start-Process -FilePath $cloudPath -ArgumentList $cloudArgs -PassThru -WindowStyle Hidden
} catch {
    Write-Color "Failed to start cloudflared: $($_.Exception.Message)" Red
    exit 1
}

Write-Color "cloudflared started (detached). PID: $($proc.Id)" Cyan
Write-Color "To stop the tunnel later: Stop-Process -Id $($proc.Id)  (or taskkill /PID $($proc.Id) /F)" Cyan
Write-Color "Logfile: $logFile" DarkCyan

# ---------- Strict detection: only accept trycloudflare or cfargotunnel ----------
Write-Color "`n[3/5] Waiting for a trycloudflare/cfargotunnel URL in the logfile..." Yellow

$timeoutSeconds = 180
$elapsed = 0
$tunnelUrl = $null

# Patterns (case-insensitive)
$tryCloudPattern = "(?i)https?://[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.trycloudflare\.com(?:/[^\s\""'<>]*)?"
$cfargoPattern   = "(?i)https?://[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.cfargotunnel\.com(?:/[^\s\""'<>]*)?"

$tryCloudRegex = [regex]$tryCloudPattern
$cfargoRegex   = [regex]$cfargoPattern

# We'll read the last N lines and join them to catch wrapped lines.
$tailLinesToRead = 800

while ($elapsed -lt $timeoutSeconds -and -not $tunnelUrl) {
    Start-Sleep -Seconds 1
    $elapsed += 1

    if (Test-Path $logFile) {
        try {
            $tailLines = Get-Content -Path $logFile -Tail $tailLinesToRead -ErrorAction SilentlyContinue
            if ($tailLines -and $tailLines.Count -gt 0) {
                $tailText = ($tailLines -join ' ')
                $m1 = $tryCloudRegex.Match($tailText)
                if ($m1.Success) { $tunnelUrl = $m1.Value.TrimEnd('.',',',';'); break }

                $m2 = $cfargoRegex.Match($tailText)
                if ($m2.Success) { $tunnelUrl = $m2.Value.TrimEnd('.',',',';'); break }

                if ($tailText -match '"url"\s*:\s*"(https?://[A-Za-z0-9\.\-]+\.trycloudflare\.com(?:/[^"]*)?)"') {
                    $tunnelUrl = $matches[1]; break
                }
                if ($tailText -match '"url"\s*:\s*"(https?://[A-Za-z0-9\.\-]+\.cfargotunnel\.com(?:/[^"]*)?)"') {
                    $tunnelUrl = $matches[1]; break
                }
            }
        } catch {
            # ignore transient read errors
        }
    }

    Write-Progress -Activity "Waiting for trycloudflare URL" -Status "Elapsed ${elapsed}s / ${timeoutSeconds}s" -PercentComplete ([int](($elapsed/$timeoutSeconds)*100))
}
Write-Progress -Activity "Waiting for trycloudflare URL" -Completed

if (-not $tunnelUrl) {
    Write-Color "ERROR: No trycloudflare or cfargotunnel URL found within ${timeoutSeconds}s." Red
    Write-Color "Check logfile: $logFile" Yellow
    if (Test-Path $logFile) {
        Write-Color "`n--- Last 120 lines of logfile ---" DarkCyan
        Get-Content -Path $logFile -Tail 120 | ForEach-Object { Write-Host $_ }
    }
    exit 1
}

Write-Color "Tunnel URL found: $tunnelUrl" Green
$ghPagesUrl = "$GITHUB_USER.github.io/$GITHUB_REPO"
Write-Color "GitHub Pages (likely): https://$ghPagesUrl" Cyan

# ---------- Fetch index.html from GitHub ----------
Write-Color "`n[4/5] Fetching current index.html from GitHub..." Yellow
$headers = @{
    Authorization = "token $GITHUB_PAT"
    'User-Agent'  = $GITHUB_USER
    Accept = 'application/vnd.github+json'
}

try {
    $response = Invoke-RestMethod -Uri ($ApiUrl + "?ref=$GITHUB_BRANCH") -Headers $headers -Method Get -ErrorAction Stop
} catch {
    Write-Color "Failed to fetch index.html from GitHub: $($_.Exception.Message)" Red
    if ($_.Exception.Response -ne $null) {
        try { $errBody = (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd(); Write-Color $errBody DarkYellow } catch {}
    }
    exit 1
}

$existingSha = $response.sha
$existingContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($response.content))

# ---------- Replace only meta-refresh URL (fixed replacement) ----------
Write-Color "`n[5/5] Replacing meta-refresh URL in index.html..." Yellow

$metaPattern = "(?i)<meta[^>]*http-equiv\s*=\s*['""]refresh['""][^>]*content\s*=\s*['""][^'""]*url=([^'""]+)"
$metaRegex = [regex]$metaPattern

if ($metaRegex.IsMatch($existingContent)) {
    $newContent = $metaRegex.Replace($existingContent, { param($m)
        $full = $m.Value
        $oldUrl = $m.Groups[1].Value
        # Use -replace with two args (pattern, replacement). We escape the oldUrl for regex safety.
        $replaced = $full -replace [regex]::Escape($oldUrl), $tunnelUrl
        return $replaced
    }, 1)
    Write-Color "Meta-refresh URL replaced." Green
} else {
    # Fallback: replace first occurrence of a trycloudflare/cfargotunnel URL if present
    $foundInFile = $null
    $m1 = $tryCloudRegex.Match($existingContent)
    if ($m1.Success) { $foundInFile = $m1.Value }
    else {
        $m2 = $cfargoRegex.Match($existingContent)
        if ($m2.Success) { $foundInFile = $m2.Value }
    }

    if ($foundInFile) {
        $newContent = $existingContent -replace [regex]::Escape($foundInFile), $tunnelUrl, 1
        Write-Color "Replaced existing trycloudflare/cfargotunnel URL in file." Green
    } else {
        $newContent = "<!DOCTYPE html>`n<html>`n<head>`n  <meta http-equiv=`"refresh`" content=`"0; url=$tunnelUrl`">`n</head>`n</html>"
        Write-Color "No meta-refresh or trycloudflare URL found in file. Overwriting with a redirect index.html." DarkYellow
    }
}

# ---------- Prepare & push update ----------
$bytes = [System.Text.Encoding]::UTF8.GetBytes($newContent)
$base64New = [System.Convert]::ToBase64String($bytes)
$commitMsg = "Update tunnel URL via script"
$payload = @{ message = $commitMsg; content = $base64New; sha = $existingSha; branch = $GITHUB_BRANCH } | ConvertTo-Json -Depth 6

Write-Progress -Activity "Pushing updated index.html to GitHub" -Status "Preparing" -PercentComplete 30
try {
    $putResp = Invoke-RestMethod -Uri $ApiUrl -Headers $headers -Method Put -Body $payload -ContentType 'application/json' -ErrorAction Stop
    Write-Progress -Activity "Pushing updated index.html" -Status "Completed" -PercentComplete 100
    Write-Color "`nSuccess! index.html updated in repo $GITHUB_USER/$GITHUB_REPO" Green
    if ($putResp.commit -and $putResp.commit.html_url) { Write-Color ("Commit: " + $putResp.commit.html_url) Cyan }
} catch {
    Write-Color "Failed to update index.html: $($_.Exception.Message)" Red
    if ($_.Exception.Response -ne $null) {
        try { $errBody = (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd(); Write-Color $errBody DarkYellow } catch {}
    }
    exit 1
}

# ---------- Summary ----------
Write-Color "`n=== Summary ===" Cyan
Write-Color ("cloudflared PID: $($proc.Id)") Cyan
Write-Color ("Stop command: Stop-Process -Id $($proc.Id)") Cyan
Write-Color ("Tunnel URL: $tunnelUrl") Green
Write-Color ("GitHub Pages (likely): https://$ghPagesUrl") Green
Write-Color ("Updated file: https://github.com/$GITHUB_USER/$GITHUB_REPO/blob/$GITHUB_BRANCH/$FilePath") Cyan

# Note: we intentionally DO NOT tail the logfile automatically here.
Write-Color "`ncloudflared is running detached. To inspect logs manually run:" DarkCyan
Write-Color "  Get-Content -Path '$logFile' -Tail 200" DarkCyan
Write-Color "or to follow live logs:" DarkCyan
Write-Color "  Get-Content -Path '$logFile' -Wait -Tail 50" DarkCyan
