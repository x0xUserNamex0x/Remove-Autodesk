# Remove-Autodesk

[Русская версия](README.ru.md)

A PowerShell script that completely removes Autodesk software from a Windows machine so you can reinstall Autodesk products from scratch without version conflicts.

It uninstalls products and licensing components, then wipes the leftovers: services, scheduled tasks, firewall rules, folders in every user profile, registry keys (including offline user hives), environment variables and PATH entries.

## Features

- Silent uninstall of all Autodesk products (MSI and ODIS-based, 2020+)
- Correct order: products first, then Licensing, Single Sign On, Desktop App, Identity Manager, Genuine Service and other shared components (two passes)
- Stops Autodesk processes and removes services, scheduled tasks and firewall rules
- Removes folders in `Program Files`, `Common Files\Autodesk Shared`, `ProgramData`, `Public` and all user profiles (`AppData\Local`, `Roaming`, `LocalLow`, `Identities`)
- Cleans the registry: `HKLM\SOFTWARE\Autodesk`, orphaned Uninstall entries, ProgIDs, App Paths, Run keys, and every user hive (loaded or offline via `NTUSER.DAT`)
- Removes `ADSK_*`, `ADSKFLEX_LICENSE_FILE`, `AUTODESK_*` variables and Autodesk entries from the machine PATH
- Takes ownership of stubborn files and retries before giving up
- `-DryRun` mode that changes nothing
- Full transcript log and a final report of anything left over

## Requirements

- Windows 10 / 11 or Windows Server 2016+
- PowerShell 5.1 or newer
- Local administrator rights

## Usage

1. Close all Autodesk applications and save your work.
2. Open PowerShell as Administrator.
3. Do a dry run first to see what would be removed:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Remove-Autodesk.ps1 -DryRun
   ```

4. Run the real cleanup:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Remove-Autodesk.ps1
   ```

5. Reboot the computer.
6. If the final report lists locked paths or leftovers, run the script once more after the reboot.

The log is saved to `C:\Temp\Autodesk-Cleanup_<COMPUTERNAME>_<date>.log`.

## Parameters

| Parameter | Description |
|---|---|
| `-DryRun` | Show what would be done, change nothing |
| `-SkipUninstall` | Skip the uninstall phase, only clean leftovers |
| `-RemoveUserDocuments` | Also remove `Documents\Autodesk` in every profile (may contain user projects and templates) |
| `-RemoveFlexNet` | Also remove FlexNet Licensing Service and `Macrovision Shared` (shared with other vendors, off by default) |

## Manual steps

Some things are safer or easier to do by hand:

- **Products that failed to uninstall** (listed in the final report): use the official Autodesk Uninstall Tool or the Microsoft Program Install and Uninstall troubleshooter. The script deliberately does not touch orphaned Windows Installer records in `HKLM\SOFTWARE\Classes\Installer\Products`.
- **Network License Manager** on a license server: remove it separately.
- **`LM_LICENSE_FILE`** variable: the script only warns about it, because it may belong to other vendors.
- **Shortcuts** pinned manually to the desktop or taskbar: delete them yourself.
- **Licenses in Autodesk Account**: release user assignments before wiping the machine so they do not stay bound to it.

## Verification

After the reboot, check that:

- Programs and Features has no Autodesk entries
- `services.msc` has no Autodesk services (including `AdskLicensingService`)
- `C:\Program Files\Autodesk`, `C:\ProgramData\Autodesk` and `C:\Program Files (x86)\Common Files\Autodesk Shared` do not exist
- `HKLM\SOFTWARE\Autodesk` and `HKCU\Software\Autodesk` do not exist

## Mass deployment

Put the script on a network share and run it via a GPO computer startup script, `Invoke-Command` or PsExec. Test on a pilot group of 2-3 machines with `-DryRun` first.

## Warning

This script permanently deletes data, including Autodesk settings, caches, license data and, with `-RemoveUserDocuments`, user files. It is intended for clean reinstalls. Use it at your own risk, test on a non-production machine first, and make sure you have backups of anything you need.

## License

MIT
