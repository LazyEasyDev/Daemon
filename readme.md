# daemon-util

Install an ordinary executable as a native service on Linux, macOS, FreeBSD,
or Windows. Each application is registered as an independent service and is
managed with the operating system's service manager.

## Cloud termination hooks

For AWS Auto Scaling and Azure VM Scale Set termination handling on Linux or
Windows, see the [cloud hook setup and deployment guide](./cloud_hook/README.md).

## Quick start

### 1. Build daemon-util

```sh
./build.sh
```

Choose the binary in `build/` that matches the target system:

| System | Architectures | Binary pattern |
| --- | --- | --- |
| Linux | AMD64, ARM64, ARM32, MIPS, MIPSLE | `daemon-linux-*` |
| macOS | Intel, Apple Silicon | `daemon-darwin-*` |
| FreeBSD | AMD64, ARM64 | `daemon-freebsd-*` |
| Windows | AMD64, ARM64 | `daemon-windows-*.exe` |

You can rename the selected binary to `daemon` or `daemon.exe`.

### 2. Put the files in a trusted location

A simple layout is:

```text
/opt/myservice/
├── daemon
├── myapp
└── config.toml
```

Linux and FreeBSD services run as `root`; Windows services run as
`LocalSystem`. Keep the daemon binary, application, scripts, and their parent
directories writable only by trusted administrators. Otherwise, another user
could replace code that the service manager executes with elevated privileges.

### 3. Install the service

Linux or FreeBSD:

```sh
cd /opt/myservice
sudo ./daemon install myservice myapp --config config.toml
```

macOS installs a service for the current user. Do not use `sudo`:

```sh
cd /Applications/MyService
./daemon install myservice myapp --config config.toml
```

Windows requires PowerShell or Command Prompt opened with **Run as
administrator**:

```powershell
cd C:\ProgramData\MyService
.\daemon.exe install myservice .\myapp.exe --config config.toml
```

`myservice` is the service name. Everything after the application path is
passed unchanged to the application.

### 4. Manage the service

Use `sudo` for these commands on Linux and FreeBSD. Do not use `sudo` on
macOS. Continue using an administrator terminal on Windows.

```sh
./daemon start myservice
./daemon status myservice
./daemon restart myservice
./daemon stop myservice
./daemon remove myservice
```

List every service installed by this tool:

```sh
./daemon list
# Short form:
./daemon ls
```

Show the application arguments recorded during installation:

```sh
./daemon list -l
# Short form:
./daemon ls -l
```

For display, metadata stores the arguments as one space-joined string. The
native service definition preserves the actual argument boundaries, but
`list -l` does not reconstruct shell quoting or make empty arguments visible.

Example output:

```text
NAME       STATUS   APP
api        stopped  /opt/api/api
myservice  running  /opt/myservice/myapp
```

## Command reference

| Command | Purpose |
| --- | --- |
| `install <name> <application> [arguments...]` | Register an application as a service |
| `list` or `ls` (`-l`, `--long`) | List services; long output includes application arguments |
| `start <name>` | Start a service |
| `stop <name>` | Stop a service |
| `restart <name>` | Stop and start a service |
| `status <name>` | Show a service's current state |
| `remove <name>` or `delete <name>` | Stop and unregister a service |

Service names must:

- start with an ASCII letter;
- contain only ASCII letters and digits;
- be no longer than 241 characters.

New systemd installations are limited to **240 characters**. A longer managed
name produces a 255-byte unit name that the native journald stream protocol
cannot handle reliably. This install-only restriction does not prevent
management or removal of an existing service with a longer name.

## Install options

### Warning confirmation

When daemon-util detects a potentially unsafe installation, it displays the
warning and asks for confirmation in an interactive terminal. Noninteractive
installation stops instead of waiting for input. To skip installation warnings
and their confirmation prompts, place `--ignore-warnings` before the service
name:

```sh
./daemon install --ignore-warnings myservice myapp
```

On Linux, the current warning detects common risky paths and SELinux file
contexts while SELinux is enforcing. This is an advisory heuristic; custom
SELinux policy can permit or deny executable types differently.
The integration suite exercises this behavior on Rocky Linux with SELinux
Enforcing.

### Stop timeout

Set the maximum graceful shutdown time during installation:

```sh
./daemon install --stop-timeout 45s myservice myapp
```

The default is `600s`. The value must be a positive, whole-second Go duration,
such as `45s`, `5m`, or `1h30m`. Place the option before the service name and
application because everything after the application is treated as an
application argument.

When the timeout expires, supported service managers force termination. On
Windows, the value also configures the SCM preshutdown allowance.

When `stop`, `restart`, or `remove` waits longer than one second in an
interactive terminal, daemon-util displays the elapsed stop time and the
configured timeout as an approximate wait, for example:

```text
Stopping myservice... 15s elapsed (within time limit: 45s)
```

The transient progress line is not written when output is redirected. If the
optional metadata is missing, unreadable, or malformed, the command displays
only the elapsed time.

### Application arguments

Arguments are preserved, including spaces and shell characters:

```sh
./daemon install myservice myapp \
  --port 8080 \
  --config "configs/production config.toml"
```

The application must remain in the foreground for its entire lifetime. It
must not fork into the background or daemonize itself.

## Executable paths

A relative application path is resolved beside the daemon-util binary, not
from the shell's current directory. Use an absolute path when the application
is stored elsewhere:

```sh
sudo ./daemon install myservice "/opt/My Service/myapp"
```

During installation, daemon-util:

1. converts the application path to an absolute path;
2. resolves symbolic links;
3. verifies that the target is a native executable;
4. registers the resolved path with the service manager.

Changing the original symbolic link later does not change the installed
service. Reinstall the service to use a different executable path.

The application's initial working directory is the directory containing its
resolved executable. Relative application arguments, such as configuration
paths, are resolved from there unless the application changes directories.

On Linux systems using systemd, executable paths containing dollar signs,
single quotes, double quotes, backslashes, control characters, or a parent
directory ending with a space are rejected during installation. Move the
executable to a conventional path before installing it. This restriction does
not apply to application arguments.

### Running scripts

Install the native interpreter and pass the script as its first argument:

```sh
sudo ./daemon install myservice /bin/sh /opt/myservice/service.sh
```

On macOS, use the same command without `sudo`.
Passing a shell, Python, PowerShell, or other script directly as the application
is intentionally rejected because the application path must identify a native
ELF, Mach-O, or PE executable for the target operating system.

daemon-util resolves interpreter symlinks before registration. On a minimal
system where `/bin/sh` resolves to a BusyBox or Toybox multicall executable,
pass the applet name explicitly:

```sh
sudo ./daemon install myservice /bin/busybox sh /opt/myservice/service.sh
```

Use `/bin/toybox sh` in the same way when Toybox provides the shell. Likewise,
an argv0-dependent Python dispatcher is not a reliable installed target. On
Linux, obtain the native executable used by the running Python interpreter and
pass the script after it:

```sh
python_native=$(python3 -c 'import os; print(os.readlink("/proc/self/exe"))')
sudo ./daemon install myservice "$python_native" /opt/myservice/service.py
```

On Windows, pass a PowerShell script to the native PowerShell executable:

```powershell
.\daemon.exe install myservice "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\MyService\service.ps1
```

In every case, the interpreter is the managed native executable and the script
is an application argument.

## Platform behavior

| Platform | Service manager | Installation scope |
| --- | --- | --- |
| Linux | systemd, OpenRC, OpenWrt procd, runit, Upstart, System V, or Buildroot init | System-wide |
| macOS | launchd | Current user |
| FreeBSD | rc.d with `/usr/sbin/daemon` | System-wide |
| Windows | Service Control Manager | System-wide, LocalSystem |

Restart policy and shutdown behavior follow the selected native service
manager, so small behavioral differences between platforms are expected.

### Process cleanup

| Backend | Descendant handling when stopped |
| --- | --- |
| Windows | Sends `CTRL_BREAK_EVENT`, then terminates the Job Object after the timeout |
| systemd | Stops processes remaining in the service control group |
| OpenRC | Requests native `supervise-daemon` cleanup with `stopgroup=true` and `rc_cgroup_cleanup=yes`; escaped or outliving descendants are not guaranteed |
| System V | Validates and signals the recorded main PID; descendant cleanup is not guaranteed |
| Buildroot | Uses `start-stop-daemon` for the validated main PID; descendant cleanup is not guaranteed |
| runit | Starts a dedicated process group and signals it through runit control hooks |
| macOS launchd | Uses launchd's default process-group cleanup |
| Upstart | Uses Upstart's tracked job process and native stop timeout; arbitrary descendant cleanup is not guaranteed |
| OpenWrt | Uses native procd instance supervision and `term_timeout`; daemon-util adds no separate process-tree walk |
| FreeBSD | Stops the `/usr/sbin/daemon` supervisor and its recorded application PID; arbitrary descendant cleanup is not guaranteed |

These guarantees depend on the selected service backend, not merely on kernel
features. Kernel cgroup support, or even a mounted cgroup v1 or v2 filesystem,
does not by itself place an application and its descendants in a dedicated
service cgroup. daemon-util does not probe cgroup availability to upgrade a raw
System V or Buildroot service into a cgroup-managed service.

For systemd, the service manager owns the unit cgroup. For OpenRC, daemon-util
requests OpenRC's native process-group and optional cgroup cleanup through the
generated service settings. daemon-util does not directly create or manipulate
raw Linux cgroups for either backend.
System V and Buildroot guarantee termination only for the validated main
process, and applications are responsible for stopping their own descendants.
On other platforms, applications must not deliberately escape native
supervision by creating a separate session, process group, console, cgroup, or
job.

### Windows applications

Applications do not need to implement the Windows SCM protocol. daemon-util
runs a separate wrapper process for each service and hosts the application as
a console program.

For graceful shutdown, the application must handle `CTRL_BREAK_EVENT`. Go
applications receive it as `os.Interrupt` through `os/signal`. GUI applications
and descendants that create a separate console or process group are not
supported. A nonzero application exit activates the configured SCM recovery
actions.

### Service list metadata

The `APP` column shown by `list` and the additional `ARGS` column shown by
`list -l` are informational.
daemon-util stores the resolved application path and the application arguments
in the platform's application-data directory, but this metadata does not
control the service. Installation and listing still work if metadata cannot be
written or read; the values will be blank. Removal deletes metadata on a
best-effort basis.

## Testing

Run the unit tests:

```sh
go test ./...
```

Build the configurable HTTP test application:

```sh
./test_app/build.sh
```

The binaries are written to `test_app/build/`. For example:

```sh
sudo ./daemon install apptest /absolute/path/to/test_app/build/test-app-linux-amd64 \
  --port 18080
sudo ./daemon start apptest
curl http://127.0.0.1:18080/healthz
```

See [test_app/README.md](test_app/README.md) for argument, restart, and graceful
shutdown test scenarios.

Run the disposable QEMU/libvirt server, embedded, vendor-image, FreeBSD, and
Windows application-level suites documented in
[integration_tests/README.md](integration_tests/README.md). They verify
installation, boot persistence, restart behavior, stop-timeout escalation,
process cleanup, and removal on real server and embedded operating systems.

## Architecture

### Runtime model

daemon-util is a management CLI, not a permanently running shared supervisor.
An install operation follows this flow:

```text
User command
  │
  ▼
daemon-util
  ├── validates the service name and executable
  ├── resolves the executable to an absolute path
  ├── selects the platform backend
  ├── writes or registers the native service definition
  └── stores informational list metadata
       │
       ▼
  Native service manager or per-service wrapper/watchdog
       │
       ▼
    Application process
```

After registration, daemon-util exits. The native service manager owns boot
startup, status, and shutdown. Restart monitoring is provided either directly
by that manager or, for the raw System V and Buildroot backends, by a watchdog
inside the generated per-service script. Later `start`, `stop`, `restart`,
`status`, and `remove` commands communicate with that service definition rather
than a shared long-running daemon-util process.

Windows is the only platform that needs an additional runtime component. Each
installed service starts its own daemon-util wrapper because ordinary console
applications do not implement the Windows SCM protocol. The wrapper belongs
to that service only; it is not shared with other installed applications.

### Backend selection

Platform-specific Go files are selected at build time. Linux then detects the
available init system at runtime in this order:

1. systemd;
2. OpenRC;
3. Upstart;
4. OpenWrt procd;
5. runit;
6. Buildroot-style init;
7. System V as the fallback when `/etc/init.d` and a normal start-runlevel directory exist.

Installation creates the native definition expected by the selected backend:

| Backend | Registered definition |
| --- | --- |
| systemd | `/etc/systemd/system/<registration-name>.service` |
| OpenRC, OpenWrt, System V | `/etc/init.d/<registration-name>` |
| Upstart | `/etc/init/<registration-name>.conf` |
| runit | `/etc/sv/<registration-name>/run`, enabled through `/var/service/<registration-name>` |
| Buildroot | `/etc/init.d/S90<registration-name>` |
| FreeBSD rc.d | `/usr/local/etc/rc.d/<registration-name>` |
| macOS launchd | `~/Library/LaunchAgents/<registration-name>.plist` |
| Windows SCM | Service Control Manager database entry |

Internally, daemon-util prefixes registration names so `list` can distinguish
services created by this tool from unrelated system services. Commands and
output continue to use the original user-facing name.

### Service isolation

Each installed application has its own native service definition and process
supervision. One failing application therefore does not take daemon-util or
other managed applications down with it.

A single shared supervisor was intentionally avoided because it would:

- create one failure point for every managed application;
- require safely adopting surviving processes after a supervisor restart;
- duplicate native restart, shutdown, boot, dependency, and permission logic;
- keep an additional privileged control process running permanently.

This design favors native reliability and failure isolation over identical
behavior on every platform. Exact restart and shutdown semantics follow the
capabilities of the selected service manager.

### Configuration and metadata

The native service definition is authoritative. Where supported by the
backend, it contains the resolved executable path, application arguments,
working directory, restart behavior, and stop timeout.

daemon-util also keeps a small metadata file containing the application path
shown by `list` and the stop timeout used for the terminal's approximate wait.
Metadata writes are best-effort and deliberately non-authoritative: failure,
deletion, or damage does not affect installation or service operation. Native
service-manager tools can continue to manage the service without daemon-util.
