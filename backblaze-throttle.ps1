<#
.SYNOPSIS
    Pins Backblaze to the lowest CPU and disk priority Windows allows, permanently.

.DESCRIPTION
    Backblaze is great at backing up your PC and occasionally great at
    wrecking your frame times while it does it. This fixes that without
    turning Backblaze off.

    For every Backblaze executable it writes a PerfOptions entry under
    Image File Execution Options (IFEO):

        CpuPriorityClass = 1   (Idle)
        IoPriority       = 0   (Very Low)

    Windows applies these every time one of those processes starts - from
    the service, the tray icon, a scheduled backup or an auto-update - so
    nothing has to keep running in the background to enforce it. Processes
    that are already running get dropped immediately as well.

    Backblaze still gets every spare CPU cycle and every quiet moment on the
    disk. It just goes to the back of the line when anything else wants them.

.PARAMETER Uninstall
    Removes the two values this script adds. Anything else stored under the
    same registry keys is left alone.

.PARAMETER Status
    Shows the registry settings and the live priority of every running
    Backblaze process. Changes nothing.

.PARAMETER Path
    Backblaze install folder. Defaults to "Program Files\Backblaze" (and the
    x86 variant if it exists).

.PARAMETER Pause
    Waits for Enter before exiting. Used by the .cmd launchers so the window
    doesn't vanish before you can read it.

.EXAMPLE
    .\backblaze-throttle.ps1

.EXAMPLE
    .\backblaze-throttle.ps1 -Status

.EXAMPLE
    .\backblaze-throttle.ps1 -Uninstall

.LINK
    https://github.com/Kemerd/backblaze-throttle
#>

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Uninstall', Mandatory = $true)]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = 'Status', Mandatory = $true)]
    [switch]$Status,

    [string]$Path,

    [switch]$Pause
)

# -----------------------------------------------------------------------------
#  Captured before strict mode kicks in. Empty when the script arrives as a
#  scriptblock (irm | iex style) instead of a file on disk, which changes how
#  elevation and exiting have to work.
# -----------------------------------------------------------------------------
$ScriptPath = ''
if (Test-Path -Path 'variable:PSCommandPath') { $ScriptPath = [string]$PSCommandPath }

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# =============================================================================
#  Constants
# =============================================================================

# Windows reads PerfOptions under this key whenever a process with a matching
# image *file name* starts. Path doesn't matter, only the exe name.
$IfeoSubKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

# -----------------------------------------------------------------------------
#  IFEO PerfOptions values.
#    CpuPriorityClass uses PROCESS_PRIORITY_CLASS_* numbering -> 1 = Idle
#    IoPriority       uses IO_PRIORITY_HINT numbering         -> 0 = Very Low
# -----------------------------------------------------------------------------
$CpuPriorityIdle   = 1
$IoPriorityVeryLow = 0

# -----------------------------------------------------------------------------
#  Every executable the Backblaze Windows client ships with at time of
#  writing. The folder scan below picks up anything newer; this list covers
#  installs that live somewhere unexpected.
# -----------------------------------------------------------------------------
$KnownExes = @(
    'bzbui.exe',
    'bzbuitray.exe',
    'bzcli.exe',
    'bzdoinstall.exe',
    'bzdownloader.exe',
    'bzfclean.exe',
    'bzfilelist.exe',
    'bzrestore.exe',
    'bzserv.exe',
    'bztransmit.exe'
)

# Human-readable names for the raw numbers above.
$CpuClassNames   = @{ 1 = 'Idle'; 2 = 'Normal'; 3 = 'High'; 4 = 'Realtime'; 5 = 'BelowNormal'; 6 = 'AboveNormal' }
$IoPriorityNames = @{ 0 = 'VeryLow'; 1 = 'Low'; 2 = 'Normal'; 3 = 'High'; 4 = 'Critical' }

# =============================================================================
#  Native helper
# =============================================================================

<#
    .NET exposes CPU priority class but not I/O priority, so this wraps the
    ProcessIoPriority information class (the same call Process Explorer uses)
    to read and set it on processes that are already running.
#>
function Initialize-NativeIo {
    # Already compiled in this session (script run twice) - nothing to do.
    if ('BackblazeThrottle.NativeIo' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace BackblazeThrottle
{
    /// <summary>
    /// Reads and writes a process's I/O priority hint via ntdll.
    /// </summary>
    public static class NativeIo
    {
        // PROCESSINFOCLASS.ProcessIoPriority
        private const int ProcessIoPriority = 33;

        // Minimal access rights for each direction.
        private const uint PROCESS_SET_INFORMATION   = 0x0200;
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("ntdll.dll")]
        private static extern int NtSetInformationProcess(IntPtr processHandle, int infoClass, ref int info, int infoLength);

        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationProcess(IntPtr processHandle, int infoClass, ref int info, int infoLength, out int returnLength);

        [DllImport("ntdll.dll")]
        private static extern int RtlNtStatusToDosError(int status);

        /// <summary>Opens a process handle or throws with the Win32 error.</summary>
        private static IntPtr Open(int pid, uint access)
        {
            IntPtr handle = OpenProcess(access, false, pid);
            if (handle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return handle;
        }

        /// <summary>Throws if an NTSTATUS is an error or warning.</summary>
        private static void Check(int status)
        {
            if (status < 0)
            {
                throw new Win32Exception(RtlNtStatusToDosError(status));
            }
        }

        /// <summary>Sets the I/O priority hint (0 = Very Low ... 2 = Normal).</summary>
        public static void SetIoPriority(int pid, int priority)
        {
            IntPtr handle = Open(pid, PROCESS_SET_INFORMATION);
            try
            {
                Check(NtSetInformationProcess(handle, ProcessIoPriority, ref priority, sizeof(int)));
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        /// <summary>Returns the current I/O priority hint of a process.</summary>
        public static int GetIoPriority(int pid)
        {
            IntPtr handle = Open(pid, PROCESS_QUERY_INFORMATION);
            try
            {
                int priority = -1;
                int returned;
                Check(NtQueryInformationProcess(handle, ProcessIoPriority, ref priority, sizeof(int), out returned));
                return priority;
            }
            finally
            {
                CloseHandle(handle);
            }
        }
    }
}
'@
}

# =============================================================================
#  Small helpers
# =============================================================================

# True when running elevated.
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity) { return $false }
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
    Opens HKLM through the 64-bit registry view explicitly. A 32-bit
    PowerShell would otherwise get silently redirected to WOW6432Node and
    write settings the 64-bit Backblaze processes never read. On 32-bit
    Windows this simply falls back to the only view there is.
#>
function Open-Hklm64 {
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
}

# Registry paths (relative to HKLM) for one exe.
function Get-ExeKeyPath      { param([string]$Name) return "$IfeoSubKey\$Name" }
function Get-PerfOptionsPath { param([string]$Name) return "$IfeoSubKey\$Name\PerfOptions" }

# Raw registry/API value -> readable label. '-' means "not set".
function Format-CpuClass {
    param($Value)
    if ($null -eq $Value) { return '-' }
    try { $n = [int]$Value } catch { return "Unknown ($Value)" }
    if ($CpuClassNames.ContainsKey($n)) { return $CpuClassNames[$n] }
    return "Unknown ($n)"
}

function Format-IoPriority {
    param($Value)
    if ($null -eq $Value) { return '-' }
    try { $n = [int]$Value } catch { return "Unknown ($Value)" }
    if ($IoPriorityNames.ContainsKey($n)) { return $IoPriorityNames[$n] }
    return "Unknown ($n)"
}

# Prints a table indented under the current section heading.
function Write-Table {
    param($Rows)
    if ($null -eq $Rows) { return }
    $text = ($Rows | Format-Table -AutoSize | Out-String)
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim()) { Write-Host ('    ' + $line) }
    }
}

# =============================================================================
#  Elevation
# =============================================================================

<#
    Relaunches this script elevated with the same arguments. Returns $true
    when the elevated copy was started (this one should then just exit), or
    $false when elevation isn't possible or was declined.
#>
function Request-Elevation {
    # Running from a scriptblock: there's no file to relaunch.
    if ([string]::IsNullOrEmpty($ScriptPath)) {
        Write-Host '  Needs admin rights. Open PowerShell with "Run as administrator" and try again.' -ForegroundColor Red
        return $false
    }

    # -------------------------------------------------------------------------
    #  Rebuild the command line. -Pause is always added: the elevated window
    #  is brand new and would otherwise close before anyone can read it.
    # -------------------------------------------------------------------------
    $argList = New-Object System.Collections.Generic.List[string]
    $argList.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"')))
    if ($Status)    { $argList.Add('-Status') }
    if ($Uninstall) { $argList.Add('-Uninstall') }
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        # A trailing backslash would escape the closing quote. "\." keeps
        # the path identical and the quoting intact.
        $safePath = $Path
        if ($safePath.EndsWith('\')) { $safePath += '.' }
        $argList.Add('-Path')
        $argList.Add('"' + $safePath + '"')
    }
    $argList.Add('-Pause')

    # Relaunch with whichever PowerShell is running this (powershell or pwsh).
    $hostExe = $null
    try { $hostExe = (Get-Process -Id $PID).Path } catch { $hostExe = $null }
    if ([string]::IsNullOrEmpty($hostExe)) { $hostExe = 'powershell.exe' }

    try {
        Start-Process -FilePath $hostExe -ArgumentList ($argList -join ' ') -Verb RunAs | Out-Null
        Write-Host '  Needs admin rights - continuing in an elevated window.' -ForegroundColor Cyan
        return $true
    }
    catch {
        Write-Host '  Admin prompt was declined. Nothing changed.' -ForegroundColor Yellow
        return $false
    }
}

# =============================================================================
#  Discovery
# =============================================================================

<#
    Returns the Backblaze install folder(s) to scan. Returns $null only when
    the user passed -Path and it doesn't exist - that's an error, not a
    "use defaults" situation.
#>
function Get-InstallDirs {
    $dirs = New-Object System.Collections.Generic.List[string]

    # Explicit folder: must exist.
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Host "  Folder not found: $Path" -ForegroundColor Red
            return $null
        }
        $dirs.Add((Resolve-Path -LiteralPath $Path).ProviderPath)
        Write-Host "  Install folder: $($dirs[0])"
        return ,$dirs
    }

    # -------------------------------------------------------------------------
    #  Default locations. ProgramW6432 always points at the 64-bit Program
    #  Files, even from a 32-bit PowerShell where ProgramFiles gets redirected.
    # -------------------------------------------------------------------------
    $roots = @(
        [Environment]::GetEnvironmentVariable('ProgramW6432'),
        [Environment]::GetEnvironmentVariable('ProgramFiles'),
        [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    )
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $candidate = Join-Path $root 'Backblaze'
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }

        # Skip duplicates (ProgramW6432 == ProgramFiles in 64-bit PowerShell).
        $already = $false
        foreach ($d in $dirs) { if ($d -ieq $candidate) { $already = $true } }
        if (-not $already) { $dirs.Add($candidate) }
    }

    if ($dirs.Count -eq 0) {
        Write-Host '  Backblaze folder not found - using the known exe list. Use -Path if it lives somewhere else.' -ForegroundColor Yellow
    }
    else {
        foreach ($d in $dirs) { Write-Host "  Install folder: $d" }
    }
    return ,$dirs
}

<#
    Known exe names plus every *.exe found in the install folder(s),
    de-duplicated case-insensitively and sorted.
#>
function Get-ExeNames {
    param($Dirs)

    $set = New-Object 'System.Collections.Generic.SortedSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $KnownExes) { [void]$set.Add($name) }

    foreach ($dir in @($Dirs)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Filter '*.exe' -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { [void]$set.Add($_.Name) }
    }

    return ,([string[]]@($set))
}

# Running processes whose image name matches one of the exes.
function Get-BackblazeProcesses {
    param([string[]]$ExeNames)

    $baseNames = @($ExeNames | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
    if ($baseNames.Count -eq 0) { return }

    Get-Process -Name $baseNames -ErrorAction SilentlyContinue | Sort-Object ProcessName, Id
}

# One row per running Backblaze process with its live CPU and disk priority.
function Get-LiveRows {
    param([string[]]$ExeNames)

    foreach ($p in @(Get-BackblazeProcesses -ExeNames $ExeNames)) {
        $cpu = 'n/a'
        $io  = 'n/a'

        # Either call can fail if the process exits mid-read; show n/a then.
        try { $p.Refresh(); $cpu = [string]$p.PriorityClass } catch { $cpu = 'n/a' }
        try { $io = Format-IoPriority ([BackblazeThrottle.NativeIo]::GetIoPriority($p.Id)) } catch { $io = 'n/a' }

        [pscustomobject]@{
            Process = $p.ProcessName
            PID     = $p.Id
            CPU     = $cpu
            Disk    = $io
        }
    }
}

# =============================================================================
#  Actions
# =============================================================================

<#
    IFEO only kicks in at process start, so anything already running gets
    lowered by hand. Prints the result; returns nothing.
#>
function Set-LivePriority {
    param([string[]]$ExeNames)

    Write-Host ''
    Write-Host '  Running now:'

    $procs = @(Get-BackblazeProcesses -ExeNames $ExeNames)
    if ($procs.Count -eq 0) {
        Write-Host '    None. They will start throttled.' -ForegroundColor DarkGray
        return
    }

    foreach ($p in $procs) {
        # Process may exit between listing and setting; skip it quietly.
        try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle } catch { }
        try { [BackblazeThrottle.NativeIo]::SetIoPriority($p.Id, $IoPriorityVeryLow) } catch { }
    }

    # Read back what actually stuck rather than trusting the setters.
    Write-Table @(Get-LiveRows -ExeNames $ExeNames)
}

# Writes CpuPriorityClass + IoPriority for every exe. Returns $true on success.
function Install-Throttle {
    param([string[]]$ExeNames)

    Write-Host ''
    Write-Host '  Registry (applies on every launch):'

    $failed = 0
    $hklm = Open-Hklm64
    try {
        foreach ($name in $ExeNames) {
            $key = $null
            try {
                # CreateSubKey opens the key if it exists and never wipes
                # other values already stored there.
                $key = $hklm.CreateSubKey((Get-PerfOptionsPath $name))
                if ($null -eq $key) { throw 'Could not open the registry key.' }

                $key.SetValue('CpuPriorityClass', $CpuPriorityIdle,   [Microsoft.Win32.RegistryValueKind]::DWord)
                $key.SetValue('IoPriority',       $IoPriorityVeryLow, [Microsoft.Win32.RegistryValueKind]::DWord)

                Write-Host ('    {0,-20} CPU Idle    Disk VeryLow' -f $name) -ForegroundColor Green
            }
            catch {
                $failed++
                Write-Host ('    {0,-20} FAILED: {1}' -f $name, $_.Exception.Message) -ForegroundColor Red
            }
            finally {
                if ($null -ne $key) { $key.Dispose() }
            }
        }
    }
    finally {
        $hklm.Dispose()
    }

    # Drop whatever is already running so no restart is needed.
    Set-LivePriority -ExeNames $ExeNames

    Write-Host ''
    if ($failed -gt 0) {
        Write-Host "  $failed exe(s) failed. Everything else is throttled." -ForegroundColor Yellow
        return $false
    }
    Write-Host '  Done. Backblaze now runs at the back of the line - and stays there through restarts and updates.' -ForegroundColor Green
    return $true
}

<#
    Removes only the two values this script writes, then deletes the
    PerfOptions / exe keys if (and only if) that left them empty.
#>
function Uninstall-Throttle {
    param([string[]]$ExeNames)

    Write-Host ''
    Write-Host '  Registry:'

    $failed  = 0
    $removed = 0
    $hklm = Open-Hklm64
    try {
        foreach ($name in $ExeNames) {
            try {
                $perfPath = Get-PerfOptionsPath $name
                $exePath  = Get-ExeKeyPath $name

                # Nothing of ours here.
                $perf = $hklm.OpenSubKey($perfPath, $true)
                if ($null -eq $perf) { continue }

                # -------------------------------------------------------------
                #  Delete our two values; remember whether the key is now
                #  empty so it can be cleaned up after the handle closes.
                # -------------------------------------------------------------
                $perfEmpty = $false
                try {
                    $perf.DeleteValue('CpuPriorityClass', $false)
                    $perf.DeleteValue('IoPriority', $false)
                    $perfEmpty = ($perf.ValueCount -eq 0 -and $perf.SubKeyCount -eq 0)
                }
                finally {
                    $perf.Dispose()
                }
                if ($perfEmpty) { $hklm.DeleteSubKey($perfPath, $false) }

                # Same for the parent <exe> key - but only if it's now empty.
                $exeKey = $hklm.OpenSubKey($exePath, $false)
                if ($null -ne $exeKey) {
                    $exeEmpty = $false
                    try { $exeEmpty = ($exeKey.ValueCount -eq 0 -and $exeKey.SubKeyCount -eq 0) }
                    finally { $exeKey.Dispose() }
                    if ($exeEmpty) { $hklm.DeleteSubKey($exePath, $false) }
                }

                $removed++
                Write-Host ('    {0,-20} removed' -f $name) -ForegroundColor Green
            }
            catch {
                $failed++
                Write-Host ('    {0,-20} FAILED: {1}' -f $name, $_.Exception.Message) -ForegroundColor Red
            }
        }
    }
    finally {
        $hklm.Dispose()
    }

    if ($removed -eq 0 -and $failed -eq 0) {
        Write-Host '    Nothing to remove.' -ForegroundColor DarkGray
    }

    Write-Host ''
    if ($failed -gt 0) {
        Write-Host "  $failed exe(s) failed to clean up." -ForegroundColor Yellow
        return $false
    }
    Write-Host '  Done. Running Backblaze processes keep low priority until they restart. Reboot for a clean slate.' -ForegroundColor Green
    return $true
}

# Read-only report of registry settings and live priorities.
function Show-Status {
    param([string[]]$ExeNames)

    # -------------------------------------------------------------------------
    #  What Windows will apply on the next launch of each exe.
    # -------------------------------------------------------------------------
    $rows = New-Object System.Collections.Generic.List[object]
    $hklm = Open-Hklm64
    try {
        foreach ($name in $ExeNames) {
            $cpu = $null
            $io  = $null
            $key = $hklm.OpenSubKey((Get-PerfOptionsPath $name), $false)
            if ($null -ne $key) {
                try {
                    $cpu = $key.GetValue('CpuPriorityClass', $null)
                    $io  = $key.GetValue('IoPriority', $null)
                }
                finally {
                    $key.Dispose()
                }
            }
            $rows.Add([pscustomobject]@{
                Executable = $name
                CPU        = (Format-CpuClass $cpu)
                Disk       = (Format-IoPriority $io)
            })
        }
    }
    finally {
        $hklm.Dispose()
    }

    Write-Host ''
    Write-Host '  Registry (applies on every launch):'
    Write-Table $rows

    # -------------------------------------------------------------------------
    #  What's actually live right now.
    # -------------------------------------------------------------------------
    Write-Host ''
    Write-Host '  Running now:'
    $live = @(Get-LiveRows -ExeNames $ExeNames)
    if ($live.Count -eq 0) {
        Write-Host '    None.' -ForegroundColor DarkGray
    }
    else {
        Write-Table $live
    }
}

# =============================================================================
#  Main
# =============================================================================

$mode = 'install'
if ($Status)    { $mode = 'status' }
if ($Uninstall) { $mode = 'uninstall' }

Write-Host ''
Write-Host "backblaze-throttle  |  $mode" -ForegroundColor Cyan

$ExitCode = 0

if (-not (Test-IsAdmin)) {
    # Hand off to an elevated copy; if that worked, this window is done.
    if (Request-Elevation) { return }
    $ExitCode = 1
}
else {
    Initialize-NativeIo

    $dirs = Get-InstallDirs
    if ($null -eq $dirs) {
        $ExitCode = 1
    }
    else {
        $exeNames = Get-ExeNames -Dirs $dirs

        if ($Status) {
            Show-Status -ExeNames $exeNames
        }
        elseif ($Uninstall) {
            if (-not (Uninstall-Throttle -ExeNames $exeNames)) { $ExitCode = 1 }
        }
        else {
            if (-not (Install-Throttle -ExeNames $exeNames)) { $ExitCode = 1 }
        }
    }
}

# -----------------------------------------------------------------------------
#  Keep the window open for double-click users, then exit. When running as a
#  scriptblock, 'exit' would close the user's whole PowerShell session, so
#  only exit with a code when running from a file.
# -----------------------------------------------------------------------------
if ($Pause) {
    Write-Host ''
    [void](Read-Host 'Press Enter to close')
}
if ($ScriptPath) { exit $ExitCode }
