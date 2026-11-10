# Saves a picture of the main screen as a PNG, at most 1600 pixels on its longer side.
# The Buddy mod runs this when you ask the Buddy panel to look at your screen on Windows.
param([Parameter(Mandatory = $true)][string]$Path)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class BuddyScreen {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[void][BuddyScreen]::SetProcessDPIAware() # real pixels, not scaled ones
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$full = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$small = $null
try {
    $graphics = [System.Drawing.Graphics]::FromImage($full)
    try { $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size) } finally { $graphics.Dispose() }

    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }

    $longest = [Math]::Max($bounds.Width, $bounds.Height)
    if ($longest -le 1600) {
        $full.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } else {
        $scale = 1600.0 / $longest
        $width = [Math]::Max(1, [int][Math]::Round($bounds.Width * $scale))
        $height = [Math]::Max(1, [int][Math]::Round($bounds.Height * $scale))
        $small = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics = [System.Drawing.Graphics]::FromImage($small)
        try {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($full, 0, 0, $width, $height)
        } finally { $graphics.Dispose() }
        $small.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
} finally {
    $full.Dispose()
    if ($small) { $small.Dispose() }
}
