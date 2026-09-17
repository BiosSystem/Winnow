<#
.SYNOPSIS
    Launches the Winnow GUI, captures its window to a PNG, and closes it.

.DESCRIPTION
    A maintainer helper for producing the README screenshot without doing it by hand. It starts
    Winnow.ps1 with no arguments (which opens the WPF GUI), waits for the window titled "Winnow" to
    appear and finish rendering, captures it, saves a PNG, and closes the window.

    The capture uses PrintWindow with PW_RENDERFULLCONTENT (flag 2), which is the mode DWM-composited
    WPF windows need; the plain flag often yields an all-black image. If a capture still comes out
    black on your hardware, re-run with -ScreenCapture to copy the pixels from the screen instead
    (that path needs the window fully on-screen and unobscured).

    Run this from an ELEVATED PowerShell. Winnow's GUI requires administrator rights, and a
    medium-integrity process cannot reliably capture an elevated window (UIPI), so the capturer has to
    be elevated too.

    This script is a tool, not part of the shipped product: it is not embedded in the standalone build
    and is not exercised by the test suite, so it has not been run in CI. Run it once and check the PNG.

.PARAMETER OutputPath
    Where to write the PNG. Defaults to docs\images\winnow-gui.png under the repository root.

.PARAMETER RenderWaitSeconds
    How long to wait after the window appears before capturing, so the feature list and tiles finish
    populating. Default 6.

.PARAMETER TimeoutSeconds
    How long to wait for the window to appear before giving up. Default 60.

.PARAMETER WindowTitle
    The window title to match (prefix). Default "Winnow". Override if the GUI runs in a language that
    localizes the title.

.PARAMETER ScreenCapture
    Copy the pixels from the screen instead of using PrintWindow. Use only if PrintWindow yields black.

.PARAMETER KeepOpen
    Leave the GUI open after capturing instead of closing it.

.EXAMPLE
    # From an elevated PowerShell, at the repository root:
    .\Tools\Capture-GuiScreenshot.ps1

.EXAMPLE
    .\Tools\Capture-GuiScreenshot.ps1 -OutputPath 'C:\temp\winnow.png' -RenderWaitSeconds 8
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [int]$RenderWaitSeconds = 6,
    [int]$TimeoutSeconds = 60,
    [string]$WindowTitle = 'Winnow',
    [switch]$ScreenCapture,
    [switch]$KeepOpen
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$entryScript = Join-Path $repoRoot 'Winnow.ps1'
if (-not (Test-Path -LiteralPath $entryScript)) {
    throw "Cannot find Winnow.ps1 at $entryScript. Run this from the repository's Tools folder."
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot 'docs\images\winnow-gui.png'
}

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Run this from an elevated PowerShell. The GUI needs administrator rights, and capturing an elevated window needs the capturer to be elevated too.'
}

Add-Type -AssemblyName System.Drawing

if (-not ('WinnowCapture.Native' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace WinnowCapture {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
        [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        private const uint PW_RENDERFULLCONTENT = 2;
        private const uint WM_CLOSE = 0x0010;
        private const int SW_RESTORE = 9;

        public static IntPtr FindTopWindowByTitle(string prefix) {
            IntPtr found = IntPtr.Zero;
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
                if (!IsWindowVisible(hWnd)) { return true; }
                int len = GetWindowTextLength(hWnd);
                if (len <= 0) { return true; }
                StringBuilder sb = new StringBuilder(len + 1);
                GetWindowText(hWnd, sb, sb.Capacity);
                string title = sb.ToString();
                if (title.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) {
                    found = hWnd;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        public static void BringToFront(IntPtr hWnd) {
            ShowWindow(hWnd, SW_RESTORE);
            SetForegroundWindow(hWnd);
        }

        public static void CloseWindow(IntPtr hWnd) {
            PostMessage(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
        }

        public static Bitmap CaptureWindow(IntPtr hWnd, bool fromScreen) {
            RECT r;
            GetWindowRect(hWnd, out r);
            int width = r.Right - r.Left;
            int height = r.Bottom - r.Top;
            if (width <= 0 || height <= 0) { throw new Exception("The window has no drawable area."); }

            Bitmap bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bmp)) {
                if (fromScreen) {
                    g.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(width, height), CopyPixelOperation.SourceCopy);
                }
                else {
                    IntPtr hdc = g.GetHdc();
                    try { PrintWindow(hWnd, hdc, PW_RENDERFULLCONTENT); }
                    finally { g.ReleaseHdc(hdc); }
                }
            }
            return bmp;
        }
    }
}
'@
}

$process = $null
try {
    Write-Host "Launching the Winnow GUI..." -ForegroundColor Cyan
    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $entryScript)) `
        -PassThru

    Write-Host "Waiting for the '$WindowTitle' window (up to $TimeoutSeconds s)..."
    $hwnd = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $hwnd = [WinnowCapture.Native]::FindTopWindowByTitle($WindowTitle)
        if ($hwnd -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($hwnd -eq [IntPtr]::Zero) {
        throw "The GUI window titled '$WindowTitle' did not appear within $TimeoutSeconds seconds. If the title is localized, pass -WindowTitle."
    }

    Write-Host "Window found. Letting it render for $RenderWaitSeconds s..."
    Start-Sleep -Seconds $RenderWaitSeconds
    [WinnowCapture.Native]::BringToFront($hwnd)
    Start-Sleep -Milliseconds 700

    $bitmap = [WinnowCapture.Native]::CaptureWindow($hwnd, [bool]$ScreenCapture)
    try {
        $outputDir = Split-Path -Parent $OutputPath
        if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
        $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Host ("Saved {0}x{1} screenshot to {2}" -f $bitmap.Width, $bitmap.Height, $OutputPath) -ForegroundColor Green
        Write-Host "Check the PNG. If it is black, re-run with -ScreenCapture." -ForegroundColor Yellow
    }
    finally {
        $bitmap.Dispose()
    }

    if (-not $KeepOpen) {
        [WinnowCapture.Native]::CloseWindow($hwnd)
    }
}
finally {
    if (-not $KeepOpen -and $process -and -not $process.HasExited) {
        Start-Sleep -Seconds 2
        if (-not $process.HasExited) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}
