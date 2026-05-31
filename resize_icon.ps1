Add-Type -AssemblyName System.Drawing

$sourcePath = "e:\PROJECTS\Flutter Project\omnidrop\android\app\src\main\res\drawable\ic_qs_omnidrop.png"
if (-not (Test-Path $sourcePath)) {
    Write-Host "Source file not found!"
    exit
}

$img = [System.Drawing.Image]::FromFile($sourcePath)
$bmp = New-Object System.Drawing.Bitmap($img)
$img.Dispose()

$baseDir = "e:\PROJECTS\Flutter Project\omnidrop\android\app\src\main\res"

$sizes = @{
    "drawable-mdpi" = 24
    "drawable-hdpi" = 36
    "drawable-xhdpi" = 48
    "drawable-xxhdpi" = 72
    "drawable-xxxhdpi" = 96
}

foreach ($folder in $sizes.Keys) {
    $size = $sizes[$folder]
    $dir = Join-Path $baseDir $folder
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    
    $newBmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($newBmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)
    
    # We want it to be as large as possible within the 24x24dp area.
    # We can use the full size without padding because the previous crop left 5% padding.
    $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
    $g.DrawImage($bmp, $rect)
    $g.Dispose()
    
    $targetPath = Join-Path $dir "ic_qs_omnidrop.png"
    $newBmp.Save($targetPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $newBmp.Dispose()
    Write-Host "Created $folder size: $size"
}

$bmp.Dispose()
Remove-Item -Path $sourcePath -Force
Write-Host "Done!"
