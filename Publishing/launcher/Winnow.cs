// Winnow launcher
//
// winget's portable installer type only accepts a .exe entry point, so this
// small launcher exists solely to start Winnow.ps1 from the folder it ships in.
// It carries no logic of its own: it locates Winnow.ps1 next to the executable
// and hands off to PowerShell with a UAC elevation prompt, the same thing
// Run.bat does. The source lives in the repository and is compiled at release
// time; nothing here is hidden.

using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;

internal static class WinnowLauncher
{
    private static int Main(string[] args)
    {
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(exeDir, "Winnow.ps1");

        if (!File.Exists(script))
        {
            Console.Error.WriteLine("Winnow.ps1 was not found next to the launcher (" + script + ").");
            Console.Error.WriteLine("Keep Winnow.exe in the extracted Winnow folder; it launches the script from there.");
            return 1;
        }

        // Forward any arguments the launcher was given through to the script.
        string forwarded = string.Empty;
        if (args.Length > 0)
        {
            forwarded = " " + string.Join(" ", args);
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"" + forwarded,
            UseShellExecute = true,
            Verb = "runas",
            WorkingDirectory = exeDir
        };

        try
        {
            Process process = Process.Start(psi);
            if (process == null)
            {
                Console.Error.WriteLine("Could not start PowerShell.");
                return 1;
            }
            return 0;
        }
        catch (Win32Exception ex)
        {
            // 1223 is ERROR_CANCELLED: the user declined the UAC prompt.
            if (ex.NativeErrorCode == 1223)
            {
                Console.Error.WriteLine("Elevation was cancelled. Winnow needs administrator rights to run.");
                return 1223;
            }

            Console.Error.WriteLine("Failed to launch Winnow: " + ex.Message);
            return ex.NativeErrorCode;
        }
    }
}
