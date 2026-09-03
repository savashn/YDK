# YDK

A PowerShell script that sets up scheduled tasks to take shadow copy snapshots of your disks using Windows' Volume Shadow Copy Service (VSS).

> [!DANGER]
> This script might have unnoticed side-effects at its current early stage.
> Do not use it on your clients' computers before you have tested it on a VM.

> [!WARNING]
> It exists to get back files you deleted, corrupted or overwrote by accident.
> **This is NOT a backup!** Shadow copies are stored on the source disk itself.
> If the disk fails, the snapshots go with it.

## Table of Contents

1. [Why this exists?](#why-this-exists)
2. [Requirements](#requirements)
3. [Usage](#usage)
    1. [Installation](#installation)
    2. [Examples](#examples)
3. [Taking a Hnapshot by Hand](#taking-a-snapshot-by-hand)
    1. [Manual Snapshot Parameters](#manual-snapshot-parameters)
    2. [Exit Codes](#exit-codes)
4. [Restoring Files From a Snapshot](#restoring-files-from-a-snaphsot)
    1. [Basic Restoring](#basic-restoring)
    2. [Advanced Restoring](#advances-restoring)

## Why this exists?

The usual way to take shadow copies was a scheduled task running:

```
wmic shadowcopy call create Volume=C:\
```

Since `WMIC` is **no longer supported** on Windows 11 24H2 and later,
I had to find a new way to take snapshots of the computers I'm responsible for. 

---

## Requirements

- Windows 10 / 11.
- The volume being snapshotted must be **NTFS**. VSS cannot create shadow copies
  on ReFS, FAT32, exFAT or UDF (CD/DVD) volumes; the script skips those with a
  warning.
- Administrator rights to install. Once installed, the task runs as SYSTEM and
  **never prompts for UAC consent**.

---

## Usage

YDK has basically 4 main modes:

| Mode                | What it does           | When                                                                                 |
|---------------------|------------------------|--------------------------------------------------------------------------------------|
| *(no parameters)*   | Takes a snapshot       | The scheduled task calls this three times a day; also used for an on-demand snapshot |
| `-Install`          | Registers the tasks    | Once, by hand                                                                        |
| `-Uninstall`        | Removes the tasks      | When needed                                                                          |
| `-Status`           | Prints a health report | To check a machine, or from a monitoring script                                      |

All four modes need an **elevated PowerShell window**.

### Installation

In a PowerShell window opened as administrator:

```powershell
C:\YDK\ydk.ps1 -Install
```

By default this registers three tasks (`YDK0`, `YDK1`, `YDK2`) that run every day
at **10:00**, **13:00** and **16:00** for `C:` and `D:`.

Options for detailed installation are listed below:

| Parameter               | Default             | Description |
|-------------------------|---------------------|-------------|
| `-Time`                 | `10:00,13:00,16:00` | Daily run times (`HH:mm`). |
| `-Volume`               | `C,D`               | Volume list written into the task. |
| `-KeepPerVolume`        | `0`                 | Retention count written into the task. |
| `-TaskPrefix`           | `YDK`               | Task name prefix (`YDK0`, `YDK1`, …). |
| `-LogRetentionDays`     | `90`                | Written into the task, so scheduled runs use the same retention. |
| `-ShadowStorageMaxSize` | *(unset)*           | Overrides the VSS storage cap per volume: `25GB`, `20%`, `UNBOUNDED`. Left alone if not passed. |
| `-MaxShadowCopies`      | *(unset)*           | Overrides how many shadow copies Windows keeps per volume (1–512). Left alone if not passed. |

Written out in full, those defaults are:

```powershell
.\ydk.ps1 -Install -Time 10:00,13:00,16:00 `
          -Volume C,D -KeepPerVolume 0 `
          -TaskPrefix YDK -LogRetentionDays 90
```

That command does exactly what a bare `.\ydk.ps1 -Install` does.
`-ShadowStorageMaxSize` and `-MaxShadowCopies` have no default at all.
When they are absent the script leaves Windows' own VSS settings untouched,
which are limited to 10% of the disk and 64 snapshots maximum. 

`-WhatIf` works in the modes that change things: it shows what would happen without creating
or deleting anything.

The `-Volume` and `-KeepPerVolume` values you pass to `-Install` are written into
the task's command line, so the task runs with those settings every time. To
change them, just run `-Install` again with the new values.

Install overwrites tasks of the same name, so running it again is safe.

> [!NOTE]
> If you copied the file over a network share, by e-mail or through a browser,
> Windows might tag it as MOTW and might refuse to run it.
> If you have such an issue, run the command below for once:

```powershell
powershell -ExecutionPolicy Bypass -File C:\YDK\ydk.ps1 -Install
```

#### Examples

```powershell
# Change the times and the volumes
C:\YDK\ydk.ps1 -Install -Time '08:00','20:00' -Volume C

# Keep the 10 most recent snapshots per volume and delete older ones
C:\YDK\ydk.ps1 -Install -KeepPerVolume 10

# Show what would happen without installing anything
C:\YDK\ydk.ps1 -Install -WhatIf

# Remove the tasks
C:\YDK\ydk.ps1 -Uninstall
```

---

## Taking a snapshot by hand

In a PowerShell window opened as administrator, run the script with no
parameters, which is the same mode the scheduled task uses:

```powershell
cd C:\YDK
.\ydk.ps1                                # default: C and D
.\ydk.ps1 -Volume C                      # C: only
.\ydk.ps1 -Volume C,D -KeepPerVolume 10
.\ydk.ps1 -WhatIf                        # dry run, creates nothing
```

Log lines stream into your window as it works, and are also written to `Logs\`.

If you run it from a non-elevated window it says so and exits with code `2`
rather than failing silently.

> [!Note] 
> Right-clicking the `.ps1` and choosing "Run as administrator"
> technically works too, but you cannot pass parameters and the window closes as
> soon as it finishes, so you never see the result.

### Manual Snapshot Parameters

| Parameter              | Default               | Description |
|------------------------|-----------------------|-------------|
| `-Volume`              | `C,D`                 | Drives to snapshot. Accepts `C`, `C:` or `C:\`. |
| `-KeepPerVolume`       | `0`                   | Snapshots to keep per volume. `0` = never prune. |
| `-LogPath`             | `Logs\ydk-<date>.log` | Log file path. |
| `-LogRetentionDays`    | `90`                  | Days of log files to keep. `0` = keep forever. |
| `-FailOnMissingVolume` | off                   | Treat a missing volume as an error instead of a warning. |

Written out in full, those defaults are:

```powershell
.\ydk.ps1 -Volume C,D -KeepPerVolume 0 `
          -LogPath Logs\ydk-$(Get-Date -Format yyyy-MM-dd).log `
          -LogRetentionDays 90
```

That command does exactly what a bare `.\ydk.ps1` does.
`-FailOnMissingVolume` is a switch: leaving it out is the default, passing it
turns it on.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All volumes succeeded |
| `1` | At least one volume failed (details in the log file) |
| `2` | Not running as administrator, or invalid parameters |

---

## Restoring Files From a Snapshot

### Basic Restoring

The snapshots this tool creates appear in Windows' **Previous Versions** tab.

1. Right-click the folder or file -> **Properties** -> **Previous Versions**
2. Pick the date you want from the list
3. Click **Open**, browse inside it, and copy out what you need

There are three buttons and the difference between them matters:

| Button      | What it does |
|-------------|--------------|
| **Open**    | Opens that point in time read-only in a new window. **This is the safest option** — pick what you need and copy it out. |
| **Copy**    | Writes that point-in-time copy to another location you choose. Leaves the current files alone. |
| **Restore** | **Overwrites the folder's current contents.** You can lose files added or changed since that snapshot. |

> [!TIP]
> **To recover a deleted file or folder**, right-click its **parent folder**, not
> the item itself. something that no longer exists has no Previous Versions tab of
> its own. Open the parent's older version and take the item out of it.

### Advanced Restoring

Needed when you want to browse the whole disk, recover a path that no longer
exists at all, or script the recovery. **In an elevated PowerShell:**

#### 1. List the snapshots:

```powershell
Get-CimInstance Win32_ShadowCopy |
    Sort-Object InstallDate -Descending |
    Select-Object InstallDate, DeviceObject
```

```
InstallDate          DeviceObject
-----------          ------------
2026-09-02 14:27:08  \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy6
2026-09-02 13:54:08  \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy5
```

#### 2. Mount the one you want as a folder

The trailing `\` is required, the
link does not work without it:

```powershell
cmd /c mklink /d C:\old "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy6\"
```

#### 3. Browse `C:\old` as the disk looked at that moment and copy what you need

```powershell
explorer C:\old
Copy-Item 'C:\old\Users\User\Documents\report.docx' -Destination 'C:\Users\User\Desktop\'
```

#### 4. Remove the link when you are done

This does not delete the snapshot, only the link.

```powershell
cmd /c rmdir C:\old
```

---

## Notes

- **This is not a backup.** Shadow copies are stored on the source disk itself.
  If the disk fails, is stolen, or ransomware encrypts it, the snapshots go with
  it. Keep a separate external/offline copy for disaster recovery.
- When the shadow storage limit is reached Windows **deletes the oldest
  snapshots by itself**. They will not pile up without bound even if you never
  set `-KeepPerVolume`.
- Snapshots are volume-level, not file-level; they freeze the whole disk at a
  moment in time rather than an individual file.

## License

Licensed under [GPL-v3.0](#LICENSE).
