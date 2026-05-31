Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile("e:\PROJECTS\Flutter Project\omnidrop\assets\OMNIDROP_icon.png")
$bmp = New-Object System.Drawing.Bitmap($img)

for ($x = 0; $x -lt $bmp.Width; $x++) {
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $c = $bmp.GetPixel($x, $y)
        # Calculate brightness (0 to 1)
        $brightness = ($c.R * 0.3 + $c.G * 0.59 + $c.B * 0.11) / 255.0
        
        # We want dark pixels to become white and opaque, light pixels to become transparent
        $newAlpha = [Math]::Max(0, [Math]::Min(255, [int]((1.0 - $brightness) * 255.0 * 1.5)))
        
        # If it was very light, just make it completely transparent to remove noise
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
Write-Host "Icons successfully converted to transparent silhouettes!"
