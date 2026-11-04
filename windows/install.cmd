@echo off
rem AiLimitWidget installer: downloads the source from GitHub and builds the exe right on this PC.
rem A locally built exe is not a downloaded file, so Defender does not flag it (Wacatac.B!ml is a false positive
rem of its cloud ML on the downloaded release\AiLimitWidget.exe).
rem Result: %LOCALAPPDATA%\AiLimitWidget\AiLimitWidget.exe + shortcut on the Desktop, then the widget starts.
setlocal
set "RAW=https://raw.githubusercontent.com/umarovdesdev/AiLimitWidget/main/windows"
set "DST=%LOCALAPPDATA%\AiLimitWidget"
set "SRC=%DST%\src"
set "FW=%WINDIR%\Microsoft.NET\Framework\v4.0.30319"
if not exist "%FW%\csc.exe" (
  echo .NET Framework 4 not found. Install .NET Framework 4.8: https://dotnet.microsoft.com/download/dotnet-framework
  pause & exit /b 1
)
if not exist "%SRC%" mkdir "%SRC%"
echo Downloading source...
for %%F in (AiLimitWidget.cs AiLimitWidget.ico AiLimitWidget.manifest) do (
  curl.exe -fsSL "%RAW%/%%F" -o "%SRC%\%%F" || (echo Download failed: %%F & pause & exit /b 1)
)
taskkill /im AiLimitWidget.exe /f >nul 2>&1
echo Building...
"%FW%\csc.exe" /nologo /target:winexe /optimize+ /codepage:65001 /warn:0 ^
  /out:"%DST%\AiLimitWidget.exe" /win32icon:"%SRC%\AiLimitWidget.ico" /win32manifest:"%SRC%\AiLimitWidget.manifest" ^
  /r:"%FW%\WPF\PresentationFramework.dll" /r:"%FW%\WPF\PresentationCore.dll" /r:"%FW%\WPF\WindowsBase.dll" ^
  /r:System.Xaml.dll /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Core.dll /r:System.Xml.dll ^
  "%SRC%\AiLimitWidget.cs" || (echo Build failed & pause & exit /b 1)
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\AiLimitWidget.lnk'); $s.TargetPath='%DST%\AiLimitWidget.exe'; $s.WorkingDirectory='%DST%'; $s.Save()"
start "" "%DST%\AiLimitWidget.exe"
echo Done: %DST%\AiLimitWidget.exe (shortcut on the Desktop)
