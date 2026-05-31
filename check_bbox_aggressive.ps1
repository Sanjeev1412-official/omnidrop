Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile("e:\PROJECTS\Flutter Project\omnidrop\assets\OMNIDROP_icon.png")
$bmp = New-Object System.Drawing.Bitmap($img)

$minX = $bmp.Width
$minY = $bmp.Height
$maxX = 0
$maxY = 0

for ($x = 0; $x -lt $bmp.Width; $x++) {
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $c = $bmp.GetPixel($x, $y)
        $brightness = ($c.R * 0.3 + $c.G * 0.59 + $c.B * 0.11) / 255.0
        
        # Only VERY dark pixels count towards the bounding box
        if ($brightness -lt 0.3) {
            if ($x -lt $minX) { $minX = $x }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($y -gt $maxY) { $maxY = $y }
        }
    }
}

Write-Host "Aggressive Bounding Box: MinX=$minX, MinY=$minY, MaxX=$maxX, MaxY=$maxY"
Write-Host "Aggressive Logo Size: $($maxX - $minX + 1) x $($maxY - $minY + 1)"

$bmp.Dispose()
$img.Dispose()
