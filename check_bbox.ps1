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
        
        # If it's a dark pixel (part of the logo)
        if ($brightness -lt 0.8) {
            if ($x -lt $minX) { $minX = $x }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($y -gt $maxY) { $maxY = $y }
        }
    }
}

Write-Host "Original Size: $($bmp.Width) x $($bmp.Height)"
Write-Host "Bounding Box: MinX=$minX, MinY=$minY, MaxX=$maxX, MaxY=$maxY"
Write-Host "Logo Size: $($maxX - $minX + 1) x $($maxY - $minY + 1)"

$bmp.Dispose()
$img.Dispose()
