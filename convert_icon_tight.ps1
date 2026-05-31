Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile("e:\PROJECTS\Flutter Project\omnidrop\assets\OMNIDROP_icon.png")

# Tightest possible bounding box from previous check
$minX = 240
$minY = 414
$maxX = 1386
$maxY = 1290

$w = $maxX - $minX + 1
$h = $maxY - $minY + 1
$size = [Math]::Max($w, $h)

# Add just a tiny 5% padding
$padding = [int]($size * 0.05)
$cropSize = $size + ($padding * 2)

$cropX = $minX - $padding - ($size - $w)/2
$cropY = $minY - $padding - ($size - $h)/2

$bmp = New-Object System.Drawing.Bitmap($cropSize, $cropSize)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$srcRect = New-Object System.Drawing.Rectangle([int]$cropX, [int]$cropY, $cropSize, $cropSize)
$destRect = New-Object System.Drawing.Rectangle(0, 0, $cropSize, $cropSize)
$g.DrawImage($img, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()

for ($x = 0; $x -lt $bmp.Width; $x++) {
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $c = $bmp.GetPixel($x, $y)
        $brightness = ($c.R * 0.3 + $c.G * 0.59 + $c.B * 0.11) / 255.0
        
        $newAlpha = [Math]::Max(0, [Math]::Min(255, [int]((1.0 - $brightness) * 255.0 * 1.5)))
        if ($brightness -gt 0.8) { $newAlpha = 0 }
        
        $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($newAlpha, 255, 255, 255))
    }
}

$densities = @("drawable", "drawable-mdpi", "drawable-hdpi", "drawable-xhdpi", "drawable-xxhdpi", "drawable-xxxhdpi")
foreach ($d in $densities) {
    $dir = "e:\PROJECTS\Flutter Project\omnidrop\android\app\src\main\res\$d"
    if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $bmp.Save("$dir\ic_bg_service_small.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Save("$dir\ic_qs_omnidrop.png", [System.Drawing.Imaging.ImageFormat]::Png)
}

$bmp.Dispose()
$img.Dispose()
Write-Host "Icons successfully cropped tightly and converted!"
