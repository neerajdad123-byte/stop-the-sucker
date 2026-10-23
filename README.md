# stop the sucker

Windows Update keeps updating itself. This stops it.

Two scripts. One freezes Windows Update and gives you back a normal **Shut down** button. The other puts everything back the way Windows had it.

That's it. That's the repo.

## How you use it

Double-click **`stop-the-sucker.bat`**.

Windows will ask for admin. Say yes. It does the rest and prints what it did.

Your power menu stops saying "Update and shut down". It just says **Shut down** and **Restart** again, like a computer should.

Changed your mind, or you want patches again? Double-click **`start-updates.bat`**. Everything goes back.

## What it actually does

Ok so here's the plain version, no marketing.

**It parks the three update services.** `wuauserv` does the downloading, `UsoSvc` is the scheduler that tells it to, and `WaaSMedicSvc` is the healer that quietly turns the other two back on behind your back. All three get set to *disabled* in the registry, so they stay dead after a reboot. Killing just the first one is why most "guides" fail a week later — the medic puts it back.

**It writes the update policies and pauses updates until 2099.** The policies matter on Windows Pro. On Home they're mostly ignored, which is fine, they're harmless. The 2099 pause is the bit Home actually listens to.

**It turns off the scheduled tasks that fire updates.** Four folders worth. Most of them surrender immediately.

**It fixes the power menu.** See below, because this is the actual thing you came here for.

**It cancels an update that's already downloaded and waiting.** Because if it doesn't, none of the above matters — more on that in a second.

## The two things nobody tells you

These are the reason this repo exists and not just a one-line registry tweak.

**One. Turning off the services does not stop an update that's already staged.**

If Windows already downloaded a cumulative and wrote it into `C:\Windows\WinSxS\pending.xml`, that thing is going to finish installing at your next boot. It's handled by TrustedInstaller during shutdown, not by the update service. So you disable `wuauserv`, feel clever, shut down — and it installs anyway.

The script checks for that file and runs `dism /Online /Cleanup-Image /RevertPendingActions` to cancel the transaction. Windows documents that command for offline images, but it works on a running system, and it's cleaner than deleting files.

**Two. The power menu is not drawn by Windows Update.**

This is the one that wasted an afternoon. You clear every reboot flag, delete `pending.xml`, purge the download cache, and the power menu *still* says "Update and shut down". Because that menu is painted by the **Update Orchestrator**, from one registry value:

```
HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator
  ShutdownFlyoutOptions    REG_DWORD    0xA
```

`0xA` means "show both update entries". Set it to `0` and they're gone. The script does that, then restarts the Start menu component so the menu redraws right away.

If you only take one thing from this repo, take that one.

## What you're giving up

Be an adult about it, because this is a real trade.

You stop getting **security patches**. Not "delayed" — you just don't get them. The bugs they fixed stay unfixed.

**Defender definition updates** ride on the same service, so those likely stop too. Real-time protection keeps running, just with whatever definitions it last had.

**Driver and Store app updates** through Windows Update stop as well.

A feature upgrade from an ISO or USB stick still works fine. This blocks the automatic path, not a manual image install.

If that's not a trade you want, don't run it.

## Requirements

Windows 10 or 11, any edition. Administrator rights. Nothing to install, no dependencies, no internet needed.

Tested on **Windows 11 25H2 Home Single Language, build 26200.9457**.

## Files

`stop-the-sucker.bat` — double-click this to freeze updates.

`stop-the-sucker.ps1` — what the bat actually runs. Pass `-KeepStagedUpdate` if you want to leave an already-downloaded update alone.

`start-updates.bat` — double-click this to undo it.

`start-updates.ps1` — the undo logic. Reads the original settings that the stop script saved to `%ProgramData%\stop-the-sucker\originals.json`, so it puts back *your* values, not guessed ones.

Everything each script does gets logged to `%ProgramData%\stop-the-sucker\`.

## If something goes wrong

Both scripts are reversible and both leave logs behind (`%ProgramData%\stop-the-sucker\`).

`start-updates.ps1` re-enables everything and hands the machine back to Windows Update. After that, Settings > Windows Update > Check for updates re-downloads anything you cancelled.

## License

MIT. Do what you want.
