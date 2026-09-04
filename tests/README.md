# Tests

Two sets of suites. The first is safe to run anywhere; the second is not.

```powershell
.\tests\run.ps1                                    # safe suites (~1 min, no admin)
.\tests\run.ps1 -System -IKnowThisIsATestMachine    # everything (~10 min, elevated)
```

Reports, transcripts and scratch folders are written to `%TEMP%\ydk-tests`;
nothing is written inside the repository.

> [!CAUTION]
> **Run the system suites on a virtual machine or a throwaway test machine only.**
> They take real VSS snapshots, register and delete scheduled tasks, write to
> `HKLM\SYSTEM\CurrentControlSet\Services\VSS\Settings`, create and remove
> `C:\Program Files\YDK` and `C:\YDK`, mount and detach a 2 GB VHD with
> `diskpart`, and set the VSS service to Disabled for one test before putting it
> back. Each suite records the state of the machine first, restores it
> afterwards and fails if anything is left behind — but a machine somebody
> depends on is still the wrong place to find that out.
>
> They also delete every shadow copy they created. On a machine that already has
> shadow copies of its own, they leave those alone, and suites that cannot run
> without disturbing them skip themselves instead.

Suites refuse to start unless `run.ps1` has confirmed the machine, so running a
single system suite by hand needs `$env:YDK_TESTS_ALLOW_SYSTEM = '1'` first.

## Safe suites — `tests\safe`

| Suite | What it covers |
|---|---|
| `01-parameters-and-non-admin.ps1` | Parameter sets and `ValidateRange`; what every mode does without administrator rights (exit code 2 and a readable message); log paths that cannot be written or created; `ConvertTo-VolumeRoot` and `Test-IsYdkTask` as unit tests, including the Turkish `i`/`I` trap and a task whose `Actions` is `$null`. |
| `02-task-prefix-and-log-retention.ps1` | Task prefix validation (empty, whitespace, characters a task name cannot contain) and `Remove-OldLogFile` in depth: which names it matches, invalid dates, sub-folders, a directory named like a log file, the file being written to, read-only and locked files, retention `0` and negative, the day-boundary, `-WhatIf`, and 120 files in one pass. |
| `03-install-location.ps1` | `Get-UnsafeWriteAccess` against folders whose permissions the test sets up: `Users:Modify`, `Everyone:Write`, `Delete`, `ChangePermissions`, `TakeOwnership`, read-only rights, a writable file in a safe folder, and real locations (`C:\Program Files`, `System32`, the user profile, `%TEMP%`). |

## System suites — `tests\system`

| Suite | What it covers |
|---|---|
| `01-snapshots-and-tasks.ps1` | The whole snapshot mode (volume formats, missing and non-NTFS volumes, `-WhatIf`, log retention, two runs at once) and install/uninstall/status, including the guard that keeps `-Uninstall` away from tasks it did not create. |
| `02-counts-and-vss-limits.ps1` | Snapshot counting per volume, `-Time` parsing through `-File` versus an array, uninstall safety with decoy tasks, the shadow storage cap (raise, lower, percentage) and `MaxShadowCopies`. |
| `03-fix-regressions.ps1` | The defects found by earlier rounds: trigger-less tasks in `-Status`, comma-separated `-Time`, all-or-nothing time validation, orphan tasks, empty prefix and empty lists, unusable log folder. |
| `04-vss-return-codes.ps1` | Every `Win32_ShadowCopy::Create` return code, through a copy of the script whose `New-ShadowCopy` is replaced by a stub — including the retry on code 9 and an undefined code. |
| `05-environment.ps1` | A second NTFS volume (VHD) and the same volume as FAT32, a `subst` drive, VSS left Disabled, a locked log file, two runs sharing one log file, task prefixes with regex and non-ASCII characters, a script path containing `&` and `[ ]`, and the `-Status` warnings. |
| `06-install-location.ps1` | Installing from `C:\Program Files\YDK` end to end (the SYSTEM task runs and writes its log there), the refusal to install from a folder ordinary users can write to, `-SkipLocationCheck`, and `icacls` hardening making the same install succeed. |
| `07-setup-script.ps1` | `ydk-setup.ps1`: its guards without administrator rights, a full run, options handed through, re-running as an update, running from the destination, and the failure paths. |

## Machines these are written for

The suites detect what they need and skip what they cannot get:

- A volume VSS cannot snapshot (DVD, FAT32) is used when one exists.
- `05-environment.ps1` needs the drive letters `X:` and `Y:` free.
- `01-snapshots-and-tasks.ps1` assumes `C:` is NTFS.

A suite that skips says so in its output, and a skip never counts as a failure.
