# Рисует AiLimitWidget.ico: звёздочка Claude (оранжевая) и искра Gemini (зелёная) на тёмном скруглённом квадрате, PNG-кадры 16…256
Add-Type -AssemblyName System.Drawing
$sizes = 16, 24, 32, 48, 256
$frames = foreach ($s in $sizes) {
  $bmp = New-Object System.Drawing.Bitmap $s, $s
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $r = $s * 0.22; $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc(0, 0, 2*$r, 2*$r, 180, 90); $p.AddArc($s-2*$r-1, 0, 2*$r, 2*$r, 270, 90)
  $p.AddArc($s-2*$r-1, $s-2*$r-1, 2*$r, 2*$r, 0, 90); $p.AddArc(0, $s-2*$r-1, 2*$r, 2*$r, 90, 90); $p.CloseFigure()
  $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 38, 38, 40))), $p)
  # звёздочка Claude — слева сверху
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 217, 119, 87)), ([Math]::Max(1.4, $s * 0.085))
  $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
  $c = $s * 0.38; $len = $s * 0.22
  foreach ($a in 0, 45, 90, 135) {
    $rad = $a * [Math]::PI / 180; $dx = [Math]::Cos($rad) * $len; $dy = [Math]::Sin($rad) * $len
    $g.DrawLine($pen, [float]($c - $dx), [float]($c - $dy), [float]($c + $dx), [float]($c + $dy))
  }
  # искра Gemini — справа снизу (четыре вогнутые дуги)
  $cx = $s * 0.66; $cy = $s * 0.66; $h = $s * 0.25; $k = $h * 0.12
  $star = New-Object System.Drawing.Drawing2D.GraphicsPath
  $star.AddBezier([float]$cx, [float]($cy - $h), [float]($cx + $k), [float]($cy - $k), [float]($cx + $k), [float]($cy - $k), [float]($cx + $h), [float]$cy)
  $star.AddBezier([float]($cx + $h), [float]$cy, [float]($cx + $k), [float]($cy + $k), [float]($cx + $k), [float]($cy + $k), [float]$cx, [float]($cy + $h))
  $star.AddBezier([float]$cx, [float]($cy + $h), [float]($cx - $k), [float]($cy + $k), [float]($cx - $k), [float]($cy + $k), [float]($cx - $h), [float]$cy)
  $star.AddBezier([float]($cx - $h), [float]$cy, [float]($cx - $k), [float]($cy - $k), [float]($cx - $k), [float]($cy - $k), [float]$cx, [float]($cy - $h))
  $star.CloseFigure()
  $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 52, 199, 89))), $star)
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  ,@($s, $ms.ToArray())
}
$out = New-Object System.IO.MemoryStream; $w = New-Object System.IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
  $s = $f[0]; $d = $f[1]; $b = if ($s -ge 256) { 0 } else { $s }
  $w.Write([byte]$b); $w.Write([byte]$b); $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]$d.Length); $w.Write([UInt32]$offset)
  $offset += $d.Length
}
foreach ($f in $frames) { $w.Write([byte[]]$f[1]) }
[System.IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'AiLimitWidget.ico'), $out.ToArray())
