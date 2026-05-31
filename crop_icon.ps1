Add-Type -AssemblyName System.Drawing

$filePath = "e:\PROJECTS\Flutter Project\omnidrop\android\app\src\main\res\drawable\ic_qs_omnidrop.png"
$img = [System.Drawing.Image]::FromFile($filePath)
$bmp = New-Object System.Drawing.Bitmap($img)

$minX = $bmp.Width
$minY = $bmp.Height
$maxX = 0
$maxY = 0

for ($x = 0; $x -lt $bmp.Width; $x++) {
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $color = $bmp.GetPixel($x, $y)
        if ($color.A -gt 0) {
            if ($x -lt $minX) { $minX = $x }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($y -gt $maxY) { $maxY = $y }
        }
    }
}

if ($minX -le $maxX -and $minY -le $maxY) {
    $width = $maxX - $minX + 1
    $height = $maxY - $minY + 1
    
    # We will make it square based on the larger dimension to prevent aspect ratio distortion when Android scales it
    $maxDim = [math]::Max($width, $height)
    
    # Add a 5% padding so it doesn't touch the absolute edge
    $padding = [int]($maxDim * 0.05)
    $newSize = $maxDim + ($padding * 2)

    $newBmp = New-Object System.Drawing.Bitmap($newSize, $newSize)
    $g = [System.Drawing.Graphics]::FromImage($newBmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    
    $srcRect = New-Object System.Drawing.Rectangle($minX, $minY, $width, $height)
    
    # Center it in the new square bounds
    $destX = [int](($newSize - $width) / 2)
    $destY = [int](($newSize - $height) / 2)
    $destRect = New-Object System.Drawing.Rectangle($destX, $destY, $width, $height)
    
    $g.DrawImage($bmp, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    
    $g.Dispose()
    $bmp.Dispose()
    $img.Dispose()
    
    $tempPath = $filePath + ".tmp.png"
    $newBmp.Save($tempPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $newBmp.Dispose()
    
    Remove-Item -Path $filePath -Force
    Rename-Item -Path $tempPath -NewName "ic_qs_omnidrop.png"
    Write-Host "Image successfully cropped and enlarged!"
} else {
    $bmp.Dispose()
    $img.Dispose()
    Write-Host "Image is completely transparent or couldn't be cropped."
}
