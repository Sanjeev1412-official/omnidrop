Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile("e:\PROJECTS\Flutter Project\omnidrop\assets\OMNIDROP_icon.png")
$bmp = New-Object System.Drawing.Bitmap($img)
for ($x = 0; $x -lt $bmp.Width; $x++) {
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $color = $bmp.GetPixel($x, $y)
        if ($color.A -gt 0) {
            $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($color.A, 255, 255, 255))
        }
    }
}
$dir = "e:\PROJECTS\Flutter Project\omnidrop\android\app\src\main\res\drawable"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$bmp.Save("$dir\ic_qs_omnidrop.png", [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
$img.Dispose()
Write-Host "Conversion successful!"
