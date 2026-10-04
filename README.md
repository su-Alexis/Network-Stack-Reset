# Network Stack Reset

A Windows batch script that resets the TCP/IP, IPv6, Winsock and WinHTTP proxy
stacks, flushes every name and address cache, and logs exactly what it did.

**A reboot is required.** Three of the commands it runs only take effect once
Windows reloads the network stack. The script says so, and offers to restart for
you. If you want a fix that works without rebooting, see
[Network Refresh](#if-you-dont-want-to-reboot) instead.

---

## Usage

Double-click it and you get a menu:

```
    [1]  RUN THE RESET        (default - just press Enter)
    [2]  DRY RUN              (safe - changes nothing)
    [3]  VERIFY               (safe - changes nothing)
```

Or drive it from a command line:

```bat
net-reset-reboot.bat /dryrun     print every command, change nothing
net-reset-reboot.bat             run it (asks before it starts)
net-reset-reboot.bat /verify     after the reboot: did it actually help?
net-reset-reboot.bat /?          list every option
```

Passing any flag skips the menu, so existing command lines keep working.

| Flag | Effect |
|---|---|
| `/dryrun` | Print every command without running anything. Needs no admin. |
| `/verify` | Re-run only the connectivity checks and append them to the last log. Changes nothing, needs no admin. |
| `/y` | Skip the confirmation prompt. |
| `/force` | Run even from a remote session (see below). |
| `/firewall` | Also reset Windows Firewall to defaults. **Deletes custom rules.** Off by default. |
| `/restart` | Restart when finished. Recommended. |
| `/shutdown` | Shut down when finished. |
| `/none` | Leave the machine running. A reboot is still required. |

It needs administrator rights and elevates itself. Declining the UAC prompt stops
it cleanly without changing anything.

## What it does

Fourteen steps, in this order:

1. Record the current adapter configuration in the log
2. Release IPv4 DHCP leases
3. Release IPv6 DHCP leases
4. Flush the DNS resolver cache
5. Purge the NetBIOS name cache
6. Release and refresh NetBIOS names
7. Clear the ARP cache
8. Reset the TCP/IPv4 stack &nbsp;&nbsp;*(reboot required)*
9. Reset the TCP/IPv6 stack &nbsp;&nbsp;*(reboot required)*
10. Reset the Winsock catalog &nbsp;&nbsp;*(reboot required)*
11. Clear the system-wide WinHTTP proxy
12. Restore statically configured DNS servers
13. Request a fresh IPv4 lease
14. Re-register this machine in DNS

With `/firewall` the firewall reset slots in as step 12 and the rest shift down.

A routing-table flush (`route -f`) is deliberately **not** included: it drops the
default gateway immediately, and a reboot rebuilds the routes anyway.

## Custom DNS servers survive

`netsh int ip reset` reverts every adapter to DHCP-supplied DNS. If you have set
resolvers by hand, they are silently lost.

This script reads them from the registry before the reset and writes them back at
step 12. It reads the registry rather than querying adapters because a
disconnected or disabled adapter still has its setting stored but will not report
it to a live query.

Each adapter is restored independently. An adapter that cannot be written — one
that is no longer present but still has a setting in the registry, for instance —
is named in the log and does not stop the others from being restored.

## It refuses to run over Remote Desktop

Step 2 releases the IP address, which severs a remote session with no way back in
to finish the job or reboot the machine. The script detects a remote session and
stops, unless you pass `/force`.

## What it writes

Everything lands in `netreset-logs\` beside the script. If that folder is not
writable it falls back to `%TEMP%`.

| File | Contents |
|---|---|
| `netreset_<stamp>.log` | Readable step-by-step record, with ok/FAIL per step |
| `netsh-config_<stamp>.txt` | Full `netsh` configuration backup |
| `winsock-catalog_<stamp>.txt` | Winsock providers as they were before the reset |
| `ipreset_<stamp>.log` | `netsh`'s own reset logs |
| `dns-static_<stamp>.txt` | Your hand-set DNS servers. Deleted once restored; **kept only if the restore failed** |

To restore the configuration backup:

```bat
netsh -f "netsh-config_<stamp>.txt"
```

A surviving `dns-static_<stamp>.txt` is a signal: open the log and look at the
"Restore statically configured DNS servers" step.

## Before and after

Before touching anything it pings the default gateway, pings a public resolver and
resolves a hostname, recording the results as a baseline. After you reboot:

```bat
net-reset-reboot.bat /verify
```

re-runs those same three checks and appends them beneath the baseline in the same
log, so you can see whether the reset changed anything rather than guessing.

A failed check is recorded as information, not an error — no connectivity is
usually the reason you are running this in the first place.

## Design notes

- Nothing destructive happens before the backups exist. The configuration dump,
  the Winsock catalog and your DNS servers are all captured first.
- It asks twice: once before starting, once before rebooting. The reboot
  countdown can be cancelled with `shutdown /a`.
- The firewall reset is opt-in, because it deletes custom rules.
- Every command is a standard, documented Microsoft tool: `ipconfig`, `netsh`,
  `nbtstat`, `arp`, `shutdown`. Nothing is downloaded. The only registry access
  is *reading* DNS settings.
- Prompts re-ask quietly on a mistyped key rather than beeping, and give up after
  ten unusable answers so the script cannot hang when another script drives it.

## Caveats

- **The network is down until you reboot.** That is the design, not a fault.
- `netsh winsock reset` removes third-party Winsock providers. VPN clients and
  some security software register these and may need repairing afterwards. The
  catalog is saved first so you have a record of what was there.
- `/firewall` deletes every custom firewall rule. Only pass it if you mean it.

## If you don't want to reboot

**Network Refresh** is the smaller sibling: it flushes the caches and renews the
DHCP leases, and deliberately excludes the three commands that need a restart.
Try that first — if it does not fix the problem, this script is the next step up.

## Requirements

Windows 10 or 11. Administrator rights (it elevates itself). No dependencies.

## License

MIT - see [LICENSE](LICENSE).
