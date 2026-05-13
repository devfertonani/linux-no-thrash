# linux-no-thrash

Stops Linux desktops from freezing when RAM fills up. Configures swap,
sysctl values and `earlyoom` on Debian/Ubuntu so memory pressure kills a
process before the system locks into thrashing.

## What it does

A single idempotent script that:

1. Resizes `/swapfile` to 32 GB (configurable).
2. Sets `vm.swappiness=10` and `vm.vfs_cache_pressure=50`, persisted via
   `/etc/sysctl.d/`.
3. Installs and configures [`earlyoom`](https://github.com/rfjakob/earlyoom)
   so that runaway memory use kills a process *before* the system enters
   swap thrashing.

The `earlyoom` configuration uses two regexes:

- `AVOID` — process names that must never be killed (system criticals plus
  anything that loses state when killed, e.g. CLI tools without persistent
  sessions).
- `PREFER` — process names to target first under pressure (browsers, chat
  clients, IDEs, language runtimes — all recoverable by reopening).

## Why

A small swap fills instantly and offers no real buffer before the kernel
OOM killer fires. A large swap by itself is not enough either: once the
machine starts paging actively-used memory back and forth, the desktop
can lock up for minutes.

The combination of a generous swap, low swappiness (kernel keeps active
pages in RAM when possible), and an early OOM daemon (kills a process at
~10% free instead of waiting for allocation failure) keeps the machine
responsive even when something misbehaves.

## Usage

```
sudo bash setup.sh                       # default swap size: 32 GB
sudo SWAP_SIZE_GB=16 bash setup.sh       # custom swap size
```

The script is idempotent. Re-running after a fresh install or with a
different `SWAP_SIZE_GB` is safe — already-applied steps are detected
and skipped, and the swapfile is resized when the requested size differs
from the current one.

## Configuration

Edit the variables at the top of `setup.sh`:

| Variable          | Default | Purpose                                              |
| ----------------- | ------- | ---------------------------------------------------- |
| `SWAP_SIZE_GB`    | `32`    | Target swapfile size in GB. Also overridable via env var. |
| `SWAPPINESS`      | `10`    | `vm.swappiness`. Lower = kernel prefers RAM.         |
| `CACHE_PRESSURE`  | `50`    | `vm.vfs_cache_pressure`. Lower = keep more FS cache. |
| `AVOID`           | regex   | Processes `earlyoom` must never kill.                |
| `PREFER`          | regex   | Processes `earlyoom` should kill first.              |

The `AVOID` and `PREFER` regexes are matched against `/proc/PID/comm`,
which is the short process name (max 15 characters), not the full
command line.

## Requirements

- Debian or Ubuntu (uses `apt-get`).
- Free space on `/` for the new swapfile (default needs ~37 GB).
- No swap on a partition. If you have a swap partition, disable it
  manually before running; the script will refuse to touch it.

## Verifying after install

```
swapon --show
sysctl vm.swappiness vm.vfs_cache_pressure
systemctl status earlyoom
journalctl -u earlyoom -n 20
```

The `earlyoom` startup log lines should echo the `AVOID` and `PREFER`
regexes you set.

## License

MIT
