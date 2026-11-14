# backblaze-throttle

**Backblaze backs up your PC. It shouldn't back up your frame times too.**

One PowerShell script that pins every Backblaze process to the lowest CPU and disk priority Windows has, permanently. Backups keep running. Games stop stuttering. You stop killing the tray icon before every match.

## Why this exists

Backblaze is set-and-forget right up until you launch a game and `bztransmit` decides now is the perfect moment to chew through 40 GB of changed files. Frame times spike, load screens drag, and the usual fix is closing Backblaze before you play and forgetting to turn it back on.

That's not a backup strategy. That's a coin flip.

Windows already knows how to handle this: process priority. The catch is that priority set in Task Manager disappears the moment a process restarts, and Backblaze restarts its workers constantly. This script makes the setting stick.

## What it does

For each Backblaze executable, it writes two values here:

```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\<exe>\PerfOptions
```

| Value | Set to | Means |
|---|---|---|
| `CpuPriorityClass` | `1` | **Idle**, the lowest CPU priority class |
| `IoPriority` | `0` | **Very Low**, the lowest disk priority, same tier Windows uses for its own background work |

Windows reads these every time a matching process starts. Service, tray icon, scheduled backup, auto-update: doesn't matter who launches it, it starts at the back of the line. Anything already running gets dropped on the spot, so no reboot needed.

No background app. No scheduled task. Nothing left running to enforce it.

### So does Backblaze still back up?

Yes. Low priority isn't a speed cap. It's a place in line.

- **CPU:** Backblaze gets every cycle nothing else wants. The moment your game wants one, the game gets it.
- **Disk:** When the disk is quiet, Backblaze reads at full speed. When your game needs the disk, Backblaze's reads wait behind it.

Idle PC: full-speed backups. Gaming: Backblaze waits its turn.

## Install

Windows 10 or 11, admin rights.

1. **Code → Download ZIP**, extract it anywhere.
2. Double-click **`Install.cmd`** and approve the admin prompt.

Done. If Windows warns about a downloaded file, hit **More info → Run anyway**. Or read the script first. It's one file and every block is commented.

Prefer a one-liner? From an **admin** PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Kemerd/backblaze-throttle/main/backblaze-throttle.ps1)))
```

## Check it

Double-click **`Status.cmd`**, or run `.\backblaze-throttle.ps1 -Status`:

```
backblaze-throttle  |  status
  Install folder: C:\Program Files\Backblaze

  Registry (applies on every launch):
    Executable       CPU  Disk
    ----------       ---  ----
    bzbui.exe        Idle VeryLow
    bzbuitray.exe    Idle VeryLow
    bzcli.exe        Idle VeryLow
    bzdoinstall.exe  Idle VeryLow
    bzdownloader.exe Idle VeryLow
    bzfclean.exe     Idle VeryLow
    bzfilelist.exe   Idle VeryLow
    bzrestore.exe    Idle VeryLow
    bzserv.exe       Idle VeryLow
    bztransmit.exe   Idle VeryLow

  Running now:
    Process      PID CPU  Disk
    -------      --- ---  ----
    bzbui      34340 Idle VeryLow
    bzbuitray  34428 Idle VeryLow
    bzfilelist 25956 Idle VeryLow
    bzserv      6164 Idle VeryLow
    bztransmit 38612 Idle VeryLow
```

## Uninstall

Double-click **`Uninstall.cmd`**. It removes only the two values it added, deletes the registry keys if that leaves them empty, and doesn't touch anything else. Running Backblaze processes keep low priority until they restart, so reboot if you want everything back to stock right now.

## Usage

| Command | Does |
|---|---|
| `.\backblaze-throttle.ps1` | Install, or re-apply after a Backblaze update |
| `.\backblaze-throttle.ps1 -Status` | Show registry settings and live priorities. Changes nothing. |
| `.\backblaze-throttle.ps1 -Uninstall` | Remove everything it added |
| `-Path "D:\Apps\Backblaze"` | Point it at a non-standard install folder |

Forgot to run as admin? It elevates itself.

## Good to know

- **Survives Backblaze updates.** Settings are tied to exe names, not files. If an update ships a brand-new exe, run `Install.cmd` again and it picks it up.
- **Network isn't covered.** Priority doesn't touch bandwidth. If uploads spike your ping in online games, use the upload throttle in Backblaze's own settings.
- **The Backblaze control panel gets throttled too.** It can feel sluggish while your PC is busy. That's the trade.
- **CPU pegged 24/7?** Backblaze only gets leftovers. Rendering all night means backups crawl all night. Idle means idle.
- **A process can override this** by changing its own priority after it starts. `Status.cmd` shows what's actually live.

## Why not just...

- **...set priority in Task Manager?** Resets every time the process restarts.
- **...pause Backblaze before gaming?** You'll forget to unpause it. Everyone does.
- **...use a priority manager app?** Sure, if you want one more thing in the tray forever. This runs once and gets out of the way.

## License

[MIT](LICENSE). Not affiliated with or endorsed by Backblaze, Inc. "Backblaze" is a trademark of its owner.
