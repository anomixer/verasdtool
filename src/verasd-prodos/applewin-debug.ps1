param([string]$Command='',[string]$Shot='',[switch]$NoEnter)
if ([string]::IsNullOrWhiteSpace($Shot)) { $Shot = Join-Path $PSScriptRoot 'debug-screen.png' }
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class AWDebug {
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc fn,IntPtr p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,System.Text.StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint f);
}
"@
$script:awHandle=[IntPtr]::Zero
[AWDebug]::EnumWindows({param($h,$p) $title=New-Object System.Text.StringBuilder(512); [AWDebug]::GetWindowText($h,$title,512)|Out-Null; if($title.ToString().StartsWith('Apple //e')){$script:awHandle=$h}; return $true},[IntPtr]::Zero)|Out-Null
if($awHandle -eq [IntPtr]::Zero){throw 'AppleWin window not found'}
[AWDebug]::ShowWindow($awHandle,5)|Out-Null
foreach($ch in $Command.ToCharArray()) { [AWDebug]::PostMessage($awHandle,0x102,[IntPtr][int]$ch,[IntPtr]::Zero)|Out-Null; Start-Sleep -Milliseconds 40 }
if($Command -and -not $NoEnter){[AWDebug]::PostMessage($awHandle,0x102,[IntPtr]13,[IntPtr]::Zero)|Out-Null; Start-Sleep -Seconds 2}
Add-Type -AssemblyName System.Drawing
$bitmap=New-Object System.Drawing.Bitmap(700,540)
$graphics=[System.Drawing.Graphics]::FromImage($bitmap)
$dc=$graphics.GetHdc()
[AWDebug]::PrintWindow($awHandle,$dc,0)|Out-Null
$graphics.ReleaseHdc($dc)
$bitmap.Save($Shot)
$graphics.Dispose();$bitmap.Dispose()
