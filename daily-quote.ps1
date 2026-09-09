<#
    daily-quote.ps1
    Fetches a Windows Spotlight image, draws today's quote nicely on top,
    and sets the result as desktop wallpaper.

    Rotates through the quotes in a shuffled order, reshuffling into a new
    order each time the list is exhausted; new random image for each run.
#>

[CmdletBinding()]
param(
    [string]$QuotesFile,
    [ValidateSet('BottomLeft', 'BottomCenter', 'Center')]
    [string]$Position    = 'BottomLeft',
    [int]$MinWidth       = 1600,  # ignore small/portrait assets
    [int]$MaxLatest      = 20     # FILO buffer: max wallpapers kept in the latest folder
)

Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not guaranteed to be populated in param-default; resolve the path here
if (-not $QuotesFile) { $QuotesFile = Join-Path $PSScriptRoot 'quotes.txt' }
$work     = Join-Path $env:LOCALAPPDATA 'DailyQuote'
$pool     = Join-Path $work 'spotlight'
$latest   = Join-Path $work 'latest'
New-Item -ItemType Directory -Force -Path $work, $pool, $latest | Out-Null

# ---------------------------------------------------------------- quote ----
$quotes = @(Get-Content $QuotesFile -Encoding UTF8 | Where-Object { $_.Trim() })
if (-not $quotes) { throw "Found no quotes in $QuotesFile" }

# Rotate through the quotes in a shuffled order; reshuffle (into a new order) once exhausted
$stateFile = Join-Path $work 'quote-state.txt'
$order = $null
$pos = -1
if (Test-Path $stateFile) {
    $lines = Get-Content $stateFile -ErrorAction SilentlyContinue
    if ($lines.Count -ge 2) {
        $parsedOrder = @($lines[0] -split ',' | ForEach-Object { [int]$_ })
        $parsedPos = -1
        if ([int]::TryParse($lines[1], [ref]$parsedPos) -and $parsedOrder.Count -eq $quotes.Count) {
            $order = $parsedOrder
            $pos = $parsedPos
        }
    }
}

$next = $pos + 1
if (-not $order -or $next -ge $order.Count) {
    do {
        $newOrder = @(0..($quotes.Count - 1) | Sort-Object { Get-Random })
    } while ($order -and $quotes.Count -gt 1 -and ($newOrder -join ',') -eq ($order -join ','))
    $order = $newOrder
    $next = 0
}

Set-Content $stateFile -Value @(($order -join ','), $next) -Encoding UTF8
$quote = $quotes[$order[$next]].Trim()

# ------------------------------------------------ fetch fresh spotlight ----
# Windows Spotlight's public API (same as Win11 uses) provides fresh
# images on request, so we are not dependent on the local cache which
# is rarely updated.
function Get-SpotlightFromApi {
    param(
        [Parameter(Mandatory)][string]$Destination
    )
    # Pool already has plenty to pick from, so just top it up with one new image
    $poolCount = @(Get-ChildItem -Path $Destination -Filter *.jpg -File -ErrorAction SilentlyContinue).Count
    $count = if ($poolCount -ge 10) { 1 } else { 4 }
    $endpoint = 'https://fd.api.iris.microsoft.com/v4/api/selection?placement=88000820&bcnt={0}&country=US&locale=en-US&fmt=json' -f $count
    try {
        $resp = Invoke-RestMethod -Uri $endpoint -UseBasicParsing -TimeoutSec 20
    } catch {
        Write-Warning "Could not fetch Spotlight from API: $($_.Exception.Message)"
        return
    }
    foreach ($it in $resp.batchrsp.items) {
        try {
            $ad  = ($it.item | ConvertFrom-Json).ad
            $url = $ad.landscapeImage.asset
            if (-not $url) { continue }
            $name = if ($ad.entityId) { $ad.entityId } else { [guid]::NewGuid().ToString() }
            # Clean filename for invalid characters
            $name = ($name -replace '[^\w\-]', '_')
            $dest = Join-Path $Destination ("api-$name.jpg")
            if (-not (Test-Path $dest)) {
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 30
            }
        } catch {
            Write-Warning "Skipping one Spotlight element: $($_.Exception.Message)"
        }
    }
}

Get-SpotlightFromApi -Destination $pool

# ------------------------------------------------------ collect spotlight ----
# Fallback: copy from the local Spotlight cache if API didn't provide anything
$sources = @(
    Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy\LocalState\Assets'
    Join-Path $env:APPDATA      'Microsoft\Windows\Themes\CachedFiles'
    Join-Path $env:APPDATA      'Microsoft\Windows\Themes'
)

foreach ($src in $sources) {
    if (-not (Test-Path $src)) { continue }
    Get-ChildItem -Path $src -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 250KB } |
        ForEach-Object {
            $dest = Join-Path $pool ($_.BaseName + '.jpg')
            if (-not (Test-Path $dest)) {
                Copy-Item $_.FullName $dest -ErrorAction SilentlyContinue
            }
        }
}

# A JPEG must end with the End-Of-Image marker (FF D9); a truncated download
# passes a header-only probe but emits "premature end of data segment" when drawn.
function Test-JpegComplete {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            if ($fs.Length -lt 2) { return $false }
            $buf = New-Object byte[] 2
            $fs.Seek(-2, [System.IO.SeekOrigin]::End) | Out-Null
            [void]$fs.Read($buf, 0, 2)
            return ($buf[0] -eq 0xFF -and $buf[1] -eq 0xD9)
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $false
    }
}

# Discard anything that is not usable landscape format or is truncated
Get-ChildItem $pool -Filter *.jpg -File | ForEach-Object {
    try {
        $probe = [System.Drawing.Image]::FromFile($_.FullName)
        $ok = ($probe.Width -ge $MinWidth -and $probe.Width -gt $probe.Height)
        $probe.Dispose()
        if ($ok) { $ok = Test-JpegComplete -Path $_.FullName }
        if (-not $ok) { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    } catch {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

$candidates = Get-ChildItem $pool -Filter *.jpg -File
if (-not $candidates) {
    throw "Found no Spotlight images. Enable Spotlight for a day or two first (Settings > Personalization > Background > Windows Spotlight), then the cache will build up."
}

# New image each run
$picture = $candidates | Get-Random

# ---------------------------------------------------------------- draw ----
$img = [System.Drawing.Image]::FromFile($picture.FullName)
$bmp = New-Object System.Drawing.Bitmap($img.Width, $img.Height)
$g   = [System.Drawing.Graphics]::FromImage($bmp)

$g.SmoothingMode      = 'AntiAlias'
$g.InterpolationMode  = 'HighQualityBicubic'
$g.TextRenderingHint  = 'ClearTypeGridFit'
$g.DrawImage($img, 0, 0, $img.Width, $img.Height)
$img.Dispose()

$W = $bmp.Width
$H = $bmp.Height

# Dark gradient at the bottom so text is always readable
$scrimH = [int]($H * 0.42)
$scrimRect = New-Object System.Drawing.Rectangle(0, ($H - $scrimH), $W, $scrimH)
$grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $scrimRect,
    [System.Drawing.Color]::FromArgb(0, 0, 0, 0),
    [System.Drawing.Color]::FromArgb(215, 0, 0, 0),
    90.0)
# Avoid 1-pixel artifact (black line) at gradient edge
$grad.WrapMode = [System.Drawing.Drawing2D.WrapMode]::TileFlipXY
$g.FillRectangle($grad, $scrimRect)
$grad.Dispose()

# Text box
$margin = [int]($W * 0.065)
switch ($Position) {
    'Center'       { $boxY = [int]($H * 0.38); $align = 'Center' }
    'BottomCenter' { $boxY = [int]($H * 0.66); $align = 'Center' }
    default        { $boxY = [int]($H * 0.68); $align = 'Near'   }
}
$boxW = $W - (2 * $margin)
$boxH = $H - $boxY - [int]($H * 0.10)

$fmt = New-Object System.Drawing.StringFormat
$fmt.Alignment     = $align
$fmt.LineAlignment = 'Near'
$fmt.Trimming      = 'Word'

# Auto-scale font down until quote fits
$size = [float]($W * 0.038)
do {
    if ($font) { $font.Dispose() }
    $font = New-Object System.Drawing.Font('Segoe UI Light', $size, [System.Drawing.FontStyle]::Regular)
    $measured = $g.MeasureString($quote, $font, [int]$boxW, $fmt)
    if ($measured.Height -le $boxH -or $size -le 18) { break }
    $size = $size * 0.92
} while ($true)

$rect = New-Object System.Drawing.RectangleF($margin, $boxY, $boxW, $boxH)

# Soft shadow for contrast, then the actual text
$shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
$offset = [math]::Max(2, [int]($W * 0.0016))
$shadowRect = New-Object System.Drawing.RectangleF(($margin + $offset), ($boxY + $offset), $boxW, $boxH)
$g.DrawString($quote, $font, $shadow, $shadowRect, $fmt)
$shadow.Dispose()

$brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 255, 255, 255))
$g.DrawString($quote, $font, $brush, $rect, $fmt)
$brush.Dispose()
$font.Dispose()

# Discreet small line above text
$pen = New-Object System.Drawing.Pen(
    [System.Drawing.Color]::FromArgb(170, 255, 255, 255),
    [math]::Max(2, [int]($W * 0.0018)))
$lineY = $boxY - [int]($H * 0.035)
switch ($align) {
    'Center' { $g.DrawLine($pen, ($W / 2 - $W * 0.03), $lineY, ($W / 2 + $W * 0.03), $lineY) }
    default  { $g.DrawLine($pen, $margin, $lineY, ($margin + $W * 0.06), $lineY) }
}
$pen.Dispose()
$g.Dispose()

# ------------------------------------------------------------ save/set ----
# New filename each time: Windows caches wallpaper per file path.
$out = Join-Path $latest ("wallpaper-{0}.jpg" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
         Where-Object { $_.MimeType -eq 'image/jpeg' }
$params = New-Object System.Drawing.Imaging.EncoderParameters(1)
$params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
    [System.Drawing.Imaging.Encoder]::Quality, [int64]92)
$bmp.Save($out, $codec, $params)
$bmp.Dispose()

# FILO buffer: keep only the $MaxLatest most recent wallpapers
$existing = Get-ChildItem $latest -Filter 'wallpaper-*.jpg' -File | Sort-Object Name -Descending
if ($existing.Count -gt $MaxLatest) {
    $existing | Select-Object -Skip $MaxLatest | Remove-Item -Force -ErrorAction SilentlyContinue
}

# Fill mode
Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'

if (-not ('WallpaperNative' -as [type])) {
    Add-Type @'
using System.Runtime.InteropServices;
public class WallpaperNative {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
}
[WallpaperNative]::SystemParametersInfo(20, 0, $out, 3) | Out-Null

Write-Host "Set wallpaper: $quote"
Write-Host "Image: $($picture.Name)"
