[![Version](https://img.shields.io/badge/version-1.1.0-blue)](https://github.com/cyansire/webser/releases)
[![Platform](https://img.shields.io/badge/platform-Termux%20%7C%20Linux-lightgrey)]()
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Downloads](https://img.shields.io/github/downloads/cyansire/webser/total)](https://github.com/cyansire/webser/releases)
# webser — Local Web Server Manager for Termux

A production-quality Bash utility for managing multiple local web servers in [Termux](https://termux.dev) (as well as other Linux platforms). One command to start, stop, monitor, and inspect servers — with automatic backend selection, live log streaming, and clean crash recovery.
> Note: This is Termux focused build, compatible with Debian-based systems for [package based Installation](#installation-via-package-manager). 
---

## Features

- **Multiple simultaneous servers** — each on its own port, tracked in a persistent database
- **5 backends** — Python http.server, Flask, BusyBox httpd, PHP, Node http-server; auto-selected by priority
- **Live log streaming** — `webshow` tails logs with an interactive prompt inside
- **Crash recovery** — dead servers are detected, warned about, and logged automatically
- **Zero user-file risk** — `webclear` and `webclearlogs` only touch webser's own runtime files
- **Symlink dispatch** — install once, call as `webstart`, `webstop`, etc. directly

---

### Project structure
```
webser/
├── 📃 LICENSE                   #License
├── 📒 README.md                 # Project description
├── 📑 VERSIONS.txt              # Version history
├── 📩 install.sh                # Quick install
├── 📁 termux/                   # Termux-specific files
│ └── 🔧 build.sh                # Build script
├── 🛠 upcoming-updates.json     # Upcoming features
└── 📦 webser.sh                 # Main script
```
## Installation

### Using Package Manager (recommended)

For users on Debian/Ubuntu-based systems, `webser` can be installed directly from the `.deb` package using the system's package manager. This method ensures seamless integration with the system, automatic dependency management, and easy updates if hosted in a repository.

### Installation via Package Manager

> Download the .deb file from [Releases](https://github.com/cyansire/webser/releases/)

To install the `.deb` package, use the following command:
```bash
sudo apt install ./webser.deb
```

Alternatively, if `gdebi` is installed:
```bash
sudo gdebi webser.deb
```

For termux, use:
```bash
apt install ./webser.deb
```

Alternatively, using dpkg directly:
```bash
dpkg -i ./webser.deb
```

> Note: `dpkg` does not handle dependencies automatically; you may need to install missing dependencies manually.

For other distributions, the `.deb` can be converted to a native package format (e.g., `.rpm`) or built using tools like `alien`. If you want a specific build of [webser](https://github.com/cyansire/webser) for your system, please mention in [Issues](https://github.com/cyansire/webser/issues).

#### Building from Source

To build the `.deb` package locally, use the `build.sh` script included in the repository (`webser/termux/build.sh`)
```bash
cd ~/webser/termux #if the repo is in $HOME$

bash build.sh
#alternatively if file permission is set to `chmod +x`
./build.sh
```

### Quick install (Termux)

```bash
git clone https://github.com/cyansire/webser.git
cd webser
bash install.sh
```

This installs `webser` to `~/.local/bin` and creates a symlink for every command (`webstart`, `webstop`, `weblist`, …).

### Manual install

```bash
# Copy the script
install -m 755 webser.sh ~/.local/bin/webser

# Create command symlinks
for cmd in webstart webstop weblist webstatus webshow webhide \
           weblogs webclearlogs webclear webhelp webver; do
    ln -sf ~/.local/bin/webser ~/.local/bin/$cmd
done

# Make sure ~/.local/bin is in PATH
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Source-based install (optional)

If you prefer functions in your current shell session instead of subshells:

```bash
echo 'source ~/.local/bin/webser' >> ~/.bashrc
source ~/.bashrc
```

## Requirements

**Core (always needed)**

| Package | Install |
|---------|---------|
| bash ≥ 4.0 | `pkg install bash` |
| coreutils | `pkg install coreutils` |

**Backends (at least one required)**

| Backend | Install | Priority |
|---------|---------|----------|
| Python http.server | `pkg install python` | 1 — recommended |
| Flask | `pip install flask` | 2 |
| BusyBox httpd | `pkg install busybox` | 3 |
| PHP built-in | `pkg install php` | 4 |
| Node http-server | `pkg install nodejs` then `npm i -g http-server` | 5 |

---

## Commands

### `webstart`

```
webstart <port>
webstart <port> <directory>
webstart <port> <file>
webstart --backend <name> <port> [<path>]
```

Starts a server. Port must be 1–65535 (≥ 1024 without root access).

Paths may be relative or absolute; `~` is expanded automatically. When a
**file** is given, the output shows the direct URL to open it (e.g.
`http://127.0.0.1:8080/index.html`). When a **directory** is given, it is
served at the root URL (`/`). A clear error and hint are printed if the path
does not exist, cannot be read, or is a non-regular target (symlink, device
node, etc.).

```bash
webstart 8080                          # serve current directory
webstart 8080 ~/Projects/site          # serve specific directory
webstart 8080 /absolute/path/to/site   # absolute path
webstart 9000 index.html               # direct URL to file shown in output (file must be present in current working directory)
webstart --backend flask 5000          # force Flask backend
```

---

### `webmulti`

```
webmulti <port1> <port2> [... portN]
webmulti <port1> <port2> [... portN] <directory>
webmulti --backend <name> <port1> <port2> [... portN] [<path>]
```

Starts **multiple servers at once** with a single command. All numeric
arguments are treated as ports; the first non-numeric argument (if any) is
the path to serve (directory or file) — identical to `webstart`'s second
argument. The `--backend` flag applies to every port.

After all servers have been started, a summary table shows the Local URL and
LAN URL for each successful port, and lists any ports that failed.

```bash
webmulti 8080 8081 8082                  # three servers, current directory
webmulti 8080 9000 ~/site                # two servers, same directory
webmulti --backend flask 5000 5001 5002  # three Flask servers
webmulti 8080 8081 index.html            # two servers pointing at same file
```

---

### `webstop`

```
webstop              # stop ALL servers
webstop <port>       # stop one server
```

Sends SIGTERM, waits up to 3 s, then SIGKILL. Only stops servers started by webser.

---

### `weblist`

Lists all running servers in a table:

```
PORT    BACKEND   PID      UPTIME        STATUS      DIRECTORY
8080    python    14231    2h 15m 30s    running     ~/Projects/site
9000    php       14892    45m 10s       running     ~/Downloads
```

---

### `webstatus <port>`

Detailed view of one server:

```
  Status             ● running
  Responding         yes — accepting connections
  Port               8080
  Backend            python
  PID                14231
  Directory          /home/user/Projects/site
  Started            2026-08-27 10:00:15
  Running Time       2h 15m 30s
  Local URL          http://127.0.0.1:8080
  LAN URL            http://192.168.1.5:8080
  Log File           ~/.local/share/webserver/logs/webser_8080.log
```

---

### `webshow <port>`

Streams live logs with an interactive prompt at the bottom:

```
→ _
```

Commands inside `webshow`:

| Command | Action |
|---------|--------|
| `webhide` | Exit log view; server keeps running |
| `webstop` | Stop this server and exit |
| `weblist` | Print server table inline |
| `webstatus` | Print status inline |
| `q` / `quit` / `exit` | Same as webhide |

Press **Ctrl+D** or **Ctrl+C** to exit (server keeps running).

---

### `weblogs`

```
weblogs              # list all log files with size and date
weblogs <port>       # print full log for that port
```

---

### `webclearlogs`

Deletes log files for stopped servers. Skips logs of actively running servers. Also clears `crashes.log`.

---

### `webclear`

Clears temporary runtime files:
- Stale Flask helper scripts (`flask_<port>.py`)
- Stale DB lock
- Dead DB entries
- Leftover `mktemp` work files

Never touches user files.

---

### `webver`

Shows version, config paths, and backend availability:

```
  Script version     0.9
  Config version     0.9
  Config dir         ~/.config/webserver
  ...

  Backends:
  ✓  python     Python 3.12.3
  ✗  flask      not installed
  ✓  busybox    BusyBox v1.36.1
  ✗  php        not installed
  ✗  node       http-server not installed
```

---

### `webhelp`

Full command reference with syntax, examples, tips, and common errors.

---

## File Layout

```
~/.config/webserver/
    PORT | PID | BACKEND | DIRECTORY | LOGFILE | EPOCH | SERVE_FILE
├── version             # Last loaded script version (for migration)
├── flask_<port>.py     # Auto-generated Flask server scripts (cleaned by webclear)
└── .db.lock/           # Atomic mkdir lock (auto-released)

~/.local/share/webserver/logs/
├── webser_<port>.log              # Active server log
├── webser_<port>_YYYYMMDD_HHmmss.log  # Rotated log from previous run
└── crashes.log                    # Crash events log
```

---

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Port 8080 is already in use` | Another process owns that port | `webstop 8080` or pick another port |
| `Missing dependency: python3` | No backend installed | `pkg install python` |
| `Port N is privileged (< 1024)` | Android blocks low ports without root | Use a port ≥ 1024 |
| `Server process died immediately` | Backend crashed at startup | Check logs with `weblogs <port>` |
| `No webser-managed server on port N` | Port not in DB | Run `weblist` to see tracked servers |
| `Path does not exist: /some/path` | Typo or wrong directory | Use `ls` to verify; prefer absolute paths |
| `Directory is not readable: …` | Insufficient permissions | `ls -la` on the parent to check perms |
| `Path is neither a file nor a directory` | Symlink, device node, or pipe given | Provide a regular file or directory |

---

## Safety Guarantees

- **Never kills unrelated processes** — only PIDs registered in its own DB
- **Never deletes user files** — `webclear` and `webclearlogs` only remove files inside `~/.config/webserver/` and `~/.local/share/webserver/logs/`
- **Never overwrites existing files** — log files are rotated with a timestamp suffix
- **Never serves system directories** — `/`, `/etc`, `/bin`, `/usr`, etc. are blocked

---

## Packaging for Termux

See [`termux/build.sh`](termux/build.sh) for the Termux package build script.

To build and test locally:

```bash
cd termux
# Follow the Termux packages build guide:
# https://github.com/termux/termux-packages/blob/master/README.md
```

---
