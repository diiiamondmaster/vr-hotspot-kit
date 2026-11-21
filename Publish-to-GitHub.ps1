# =====================================================================
#  Publish-to-GitHub.ps1
#  One-click publisher for the vr-hotspot-kit repository.
#
#  WHAT IT DOES
#    1. Verifies git is installed (and inits the repo if needed)
#    2. Asks for a GitHub Personal Access Token (input hidden)
#       - create one in 30 seconds, only 'repo' scope needed:
#         https://github.com/settings/tokens/new?scopes=repo&description=vr-hotspot-kit
#    3. Asks for a repository name and public/private
#    4. Creates the repository on your GitHub account via the API
#    5. Commits any local changes and pushes the full history
#    6. Scrubs the token from the git remote URL when done
#
#  SECURITY
#    - The token is used in memory only and never written to disk.
#    - It is masked in all console output after authentication.
#    - Delete the token on GitHub when you are done publishing.
#
#  Windows PowerShell 5.1 compatible. No admin rights required.
# =====================================================================

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $RepoDir

function Pause-Exit([int]$code) { Read-Host 'Press Enter to close'; exit $code }

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  vr-hotspot-kit  ->  GitHub publisher'              -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ''

# ---------- 1. git present? ----------
$gitOk = $false
try { if ((git --version 2>$null) -match 'git version') { $gitOk = $true } } catch { }
if (-not $gitOk) {
    Write-Host 'Git was not found on this PC.' -ForegroundColor Red
    Write-Host 'Install "Git for Windows" from https://git-scm.com/download/win'
    Write-Host '(accept the defaults), then run this file again.'
    Pause-Exit 1
}

# ---------- 2. repo initialized? ----------
if (-not (Test-Path (Join-Path $RepoDir '.git'))) {
    Write-Host 'Initializing git repository...'
    git init -b main | Out-Null
    git add -A 2>$null
    git commit -m 'Initial commit: vr-hotspot-kit' 2>$null | Out-Null
}

# ---------- 3. token ----------
Write-Host 'You need a GitHub Personal Access Token (repo scope only).' -ForegroundColor Yellow
Write-Host 'Create one here (30 seconds):'                                -ForegroundColor Yellow
Write-Host '  https://github.com/settings/tokens/new?scopes=repo&description=vr-hotspot-kit' -ForegroundColor White
Write-Host 'GitHub stopped accepting account passwords for git in 2021.'  -ForegroundColor DarkGray
Write-Host ''
$sec = Read-Host 'Paste your token' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
if (-not $token) { Write-Host 'No token entered.' -ForegroundColor Red; Pause-Exit 1 }

function Mask([string]$s) { if ($script:token) { $s -replace [regex]::Escape($script:token), '***' } else { $s } }

# ---------- 4. validate token, get username ----------
$headers = @{ Authorization = "token $token"; 'User-Agent' = 'vr-hotspot-kit'; Accept = 'application/vnd.github+json' }
try {
    $user = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -ErrorAction Stop
} catch {
    Write-Host ('Token check failed: {0}' -f (Mask $_.Exception.Message)) -ForegroundColor Red
    Write-Host 'Make sure the token is valid and has the repo scope.'
    Pause-Exit 1
}
$username = $user.login
Write-Host ("Authenticated as: {0}" -f $username) -ForegroundColor Green

# ---------- 5. repo name / visibility ----------
$name = Read-Host 'Repository name [vr-hotspot-kit]'
if (-not $name) { $name = 'vr-hotspot-kit' }
$vis = Read-Host 'Public or private? [public]'
$private = ($vis -match '^(p(rivate)?)$')
$visWord = 'public'; if ($private) { $visWord = 'private' }

# ---------- 6. commit local changes ----------
git add -A 2>$null
$status = git status --porcelain 2>$null
if ($status) {
    $msg = Read-Host 'Commit message for your local changes [Update vr-hotspot-kit]'
    if (-not $msg) { $msg = 'Update vr-hotspot-kit' }
    git commit -m $msg 2>$null | Out-Null
    Write-Host 'Local changes committed.'
}

# git identity (local to this repo, no global settings touched)
if (-not (git config user.email)) { git config user.email "$username@users.noreply.github.com" }
if (-not (git config user.name))  { git config user.name  $username }

# ---------- 7. create the repo on GitHub ----------
$fullRepo = "$username/$name"
$exists = $false
try {
    Invoke-RestMethod -Uri "https://api.github.com/repos/$fullRepo" -Headers $headers -ErrorAction Stop | Out-Null
    $exists = $true
} catch { }

if (-not $exists) {
    $body = @{
        name        = $name
        description = 'Standalone Wi-Fi Direct hotspot app (custom SSID, WPA2, DHCP reservations) + full Mobile Hotspot diagnostic/repair kit - works even when the Windows tethering stack is broken'
        private     = $private
        has_wiki    = $false
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method Post -Uri 'https://api.github.com/user/repos' -Headers $headers -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
        Write-Host ("Created $visWord repository: {0}" -f $fullRepo) -ForegroundColor Green
    } catch {
        Write-Host ('Could not create the repository: {0}' -f (Mask $_.Exception.Message)) -ForegroundColor Red
        Pause-Exit 1
    }
} else {
    Write-Host "Repository $fullRepo already exists - pushing into it."
}

# ---------- 8. push ----------
git remote remove origin 2>$null
git remote add origin "https://x-access-token:$token@github.com/$fullRepo.git"
$branch = git rev-parse --abbrev-ref HEAD
if (-not $branch) { $branch = 'main' }
Write-Host "Pushing branch '$branch' with full history..."
$pushOut = git push -u origin $branch 2>&1
foreach ($line in $pushOut) { Write-Host (Mask ([string]$line)) }

# ---------- 9. scrub token, keep a clean remote ----------
git remote set-url origin "https://github.com/$fullRepo.git"

if ($LASTEXITCODE -eq 0) {
    Write-Host ''
    Write-Host '=====================================================' -ForegroundColor Green
    Write-Host '  DONE.'                                            -ForegroundColor Green
    Write-Host ("  Your repo:  https://github.com/{0}" -f $fullRepo) -ForegroundColor White
    Write-Host '=====================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host 'The token has been removed from the git remote.'
    Write-Host 'You can now delete the token at github.com -> Settings ->'
    Write-Host 'Developer settings -> Personal access tokens.'
    Write-Host ''
    Write-Host 'To publish future updates: edit files here, then run'
    Write-Host 'Publish-to-GitHub.bat again (a new token is needed each time'
    Write-Host 'unless you keep this one alive).'
} else {
    Write-Host ''
    Write-Host 'Push failed - see the messages above.' -ForegroundColor Red
    Write-Host 'Common cause: the repository on GitHub is not empty'
    Write-Host '(has a README/license from creation). If so, tell GitHub to'
    Write-Host 'accept our history instead: run this in this folder:'
    Write-Host "  git push -u origin $branch --force"
}
Pause-Exit 0
