# Cloud termination hooks

Two standalone executables for Linux/systemd and Windows Server. They do not
change the daemon CLI, import its service-management package, or require changes
to application code. They use the repository's existing Go module and
`golang.org/x/sys/windows` dependency to build, with no cloud SDK or AWS CLI
dependency.

- `aws_hook`: watches AWS Auto Scaling target lifecycle state using IMDSv2.
- `azure_hook`: watches Azure VM Scale Set Scheduled Events for `Terminate`.

Install only the hook matching the server's provider. Each hook discovers
services installed by the current daemon, requests their stop, and waits for
completion. Linux uses one systemd stop transaction. Windows uses the Service
Control Manager (SCM), requesting all stops before waiting for cleanup.

On Linux, applications normally receive `SIGTERM`. On Windows, the existing
daemon wrapper sends `CTRL_BREAK_EVENT`, which Go's `os/signal` package reports
as `os.Interrupt`. Applications must keep their processes alive until cleanup
finishes.

## Quick setup

The setup scripts below use the full repository: they build daemon with the
root `build.sh` and hooks with `cloud_hook/build.sh`, using the root Go module.
This folder contains the cloud-specific setup, code, tests, and documentation;
it is not a separate checkout or Go module.

### AWS Linux quick start

For an EC2 Auto Scaling instance using systemd, install Go and Git first, then
clone this repository into a trusted working directory:

```sh
git clone https://github.com/LazyEasyDev/Daemon.git
cd Daemon
sh ./cloud_hook/aws_start.sh
```

Both cloud setup scripts automatically detect Linux or Windows and select AMD64
or ARM64 binaries. Linux requires a running, accessible systemd service manager.
Windows requires 64-bit Git Bash opened as Administrator; see
[Windows cloud setup](#windows-cloud-setup). Unsupported environments exit with
an error before building binaries or installing services.

The script:

1. Runs `sh ./build.sh`.
2. Runs `sh ./cloud_hook/build.sh`.
3. Selects the Linux AMD64 or ARM64 binaries for this server.
4. Leaves daemon under `build/` and the AWS hook under `cloud_hook/build/`.
5. Creates `/usr/bin/daemon` as a persistent symlink to the local daemon binary
   and verifies it is found on the privileged command path.
6. Installs and starts the AWS hook using the existing daemon commands:
   `daemon install awsHook <hook-executable>` and `daemon start awsHook`.

Builds run as the invoking user; privileged installation commands use `sudo`
when necessary. The script does not replace an unrelated `daemon` command at
that location or reinstall existing services. It is intended for initial setup,
not in-place upgrades. No separate binary installation directory is created.
The checkout is the permanent deployment location: do not move or delete it.
Keep the checkout, binaries, and parent directories writable only by trusted
administrators, since these executables run with root privileges.

The script uses `umask 022` and explicitly sets both build directories and the
two deployed Linux binaries to `755`, clearing special permission bits. It does
not recursively change the checkout's permissions or ownership, or validate
the ownership and permissions of parent directories. Use a trusted deployment
location as described above.

For example, on AMD64:

```text
/usr/bin/daemon -> /path/to/Daemon/build/daemon-linux-amd64
/path/to/Daemon/cloud_hook/build/aws_hook-linux-amd64
```

The AWS hook service points directly to the second executable. Rebuilding
`build/` temporarily removes the daemon shortcut's target, and rebuilding
`cloud_hook/build/` replaces the hook executable. Stop affected services before
rebuilding, then restart them after a successful build.

Next, install your application from a trusted location:

```sh
sudo daemon install myservice /opt/myservice/myapp --config config.toml
sudo daemon start myservice
```

The setup script only installs daemon and the AWS hook; it does not accept
application arguments or install your applications. Keep the application and
its parent directories writable only by trusted administrators.

The `daemon` shortcut is installed on disk in `/usr/bin`, not defined as a shell
alias or temporary `PATH` export. It remains available from any directory, in
new sessions, and after reboot. The installed services also start automatically.
Run the setup on your image-building instance before creating the AMI so
scaled-out instances inherit the command and enabled services.

**AWS prerequisite:** configure an ASG termination lifecycle hook with transition
`autoscaling:EC2_INSTANCE_TERMINATING`, default result `CONTINUE`, and enough time
for detection plus cleanup. Enable instance metadata (IMDS). This setup script
does not create the lifecycle hook or verify it through the AWS API. The watcher
polls every 10 seconds, stops daemon-managed applications except itself, and
lets the lifecycle hook expire. A 300-second hook does not guarantee the
daemon's default 600-second application stop window. See
[AWS prerequisites](#aws-prerequisite-termination-lifecycle-hook).

After detecting termination, the watcher makes one stop attempt, logs the
result, and waits for server shutdown without retrying stops or polling metadata
again. On Linux, one `systemctl stop` command requests all managed applications
to stop, excluding the watcher; systemd handles concurrency and dependency
ordering. Failed stops are logged and left to normal OS shutdown.

Check watcher logs and test scale-in on a disposable instance:

```sh
sudo journalctl -u lz_lz_awsHook.service -n 50 --no-pager
```

Both cloud hooks also write `<hook-executable>.1.log` and
`<hook-executable>.2.log` beside their executable on Linux and Windows. Each
file is capped at 5 MiB (10 MiB total). Linux journal output remains available.
See [Logging](#logging) for rotation and retention details.

### Azure Linux quick start

For an Azure VM Scale Set instance using systemd, install Go and Git, then:

```sh
git clone https://github.com/LazyEasyDev/Daemon.git
cd Daemon
sh ./cloud_hook/azure_start.sh
```

This follows the same local build layout, persistent `/usr/bin/daemon`
shortcut, and `755` permissions as the AWS setup above, but installs and starts
`azureHook` using `cloud_hook/build/azure_hook-linux-amd64` (or `arm64`).
Keep the checkout in its original trusted location. Install your applications
separately using `sudo daemon install` and `sudo daemon start`.

This is initial setup only. If `azureHook` is already installed, the script
exits before rebuilding or changing services. Install only the hook matching
your cloud provider; do not run both setup scripts on the same server.

**Azure prerequisite:** enable VMSS termination notifications with enough delay
for detection and application cleanup, and apply the updated model to existing
instances as required by the upgrade policy. See
[Enable Azure termination notifications](#enable-azure-termination-notifications)
for Portal and CLI instructions. The script does not configure or verify these
Azure settings. The watcher polls Scheduled Events every 10 seconds and handles
local `Terminate` events, not Spot `Preempt` events. It does not acknowledge events
early or extend the termination deadline.

Like the AWS watcher, it makes one stop attempt after a valid notice, logs the
result, and remains alive until shutdown without further metadata polling or
stop retries.

Include the installed hook in your VM image so new scale-set instances inherit
the command and enabled service. Check logs and test scale-in on a disposable
instance:

```sh
sudo journalctl -u lz_lz_azureHook.service -n 50 --no-pager
```

### Windows cloud setup

The same `cloud_hook/aws_start.sh` and `cloud_hook/azure_start.sh` scripts also
handle Windows; no separate PowerShell setup script is needed. Install Go and
Git for Windows, then open **64-bit Git Bash as Administrator**:

```sh
git clone https://github.com/LazyEasyDev/Daemon.git
cd Daemon
sh ./cloud_hook/aws_start.sh
# On Azure, use sh ./cloud_hook/azure_start.sh instead.
```

The script detects the native AMD64 or ARM64 architecture, including when Git
Bash is running under emulation. It uses Windows services rather than systemd
and invokes the built-in Windows PowerShell internally for administrator,
service, and shortcut checks. A `.sh` file still requires Bash; do not run it
directly in Command Prompt or PowerShell.

The repository keeps `.sh` files LF-only through the root
[`.gitattributes`](../.gitattributes), even when Windows Git uses
`core.autocrlf=true`. The rule also protects the root `build.sh` called by setup;
moving it into `cloud_hook/` would no longer cover that script. If an existing
checkout already has CRLF scripts, save those files with **LF** line endings in
VS Code before running them; the Git rule prevents conversion in future checkouts.

Windows setup:

1. Checks administrator access and exits before building if the matching hook
   is already installed.
2. Builds daemon and the hooks, selecting `daemon-windows-<arch>.exe` and
   `<provider>_hook-windows-<arch>.exe`.
3. Keeps those binaries under `build/` and `cloud_hook/build/` in this checkout.
4. Creates a native symbolic link at `%WINDIR%\System32\daemon.exe` and verifies
   Windows resolves `daemon` to it. An unrelated existing command is not replaced.
5. Installs and starts `awsHook` or `azureHook` through the existing daemon CLI.

The shortcut is persistent and available in new terminals and after reboot
through Windows' system PATH. Keep this checkout in place, with its binaries
and directories writable only by trusted administrators. Windows permissions
use ACLs; the Linux `chmod 755` step is not applied on Windows.

Install your applications separately from an administrator terminal:

```powershell
daemon install myservice "C:\apps\myservice\myapp.exe"
daemon start myservice
```

The [AWS lifecycle-hook](#aws-prerequisite-termination-lifecycle-hook) and
[Azure termination-notification](#azure-prerequisite-vmss-termination-notifications)
prerequisites still apply. Logs are beside the selected hook as `.exe.1.log` and
`.exe.2.log`, capped at 5 MiB each.

Use setup for initial installation, not live upgrades. On Windows, running
services use the daemon wrapper executable and Windows locks running binaries:
stop affected services before rebuilding or replacing them.

From inside `cloud_hook/`, either setup script can also be run as
`sh ./aws_start.sh` or `sh ./azure_start.sh`. The scripts find the repository root
automatically.

## Build

From this directory:

```sh
sh ./build.sh
```

This creates Linux and Windows AMD64/ARM64 binaries under `build/`. Windows
binaries have an `.exe` suffix. Alternatively, build just one target from this
directory:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o aws_hook-linux-amd64 ./aws_hook
```

## Install on Linux

For automated initial setup, see the [AWS](#aws-linux-quick-start) or
[Azure](#azure-linux-quick-start) quick start above. For manual hook installation,
use the commands below.

Put the executable in a trusted, root-owned directory, such as
`/opt/cloud-hooks`. The binary and its parent directories must not be writable
by untrusted users. Use the current daemon CLI, which requires both a service
name and executable path.

AWS:

```sh
sudo "$daemon_bin" install awsHook /opt/cloud-hooks/aws_hook-linux-amd64
sudo "$daemon_bin" start awsHook
```

Azure:

```sh
sudo "$daemon_bin" install azureHook /opt/cloud-hooks/azure_hook-linux-amd64
sudo "$daemon_bin" start azureHook
```

Use the ARM64 binary on ARM64 servers. No arguments, ASG name, credentials,
or region configuration are needed. The hook must run as a root,
daemon-managed systemd service, not directly in a terminal or container.
Include the installed and enabled hook in the instance image so new instances
start it automatically.

Logs, using the service name from the examples:

```sh
sudo journalctl -u lz_lz_awsHook.service -f
sudo journalctl -u lz_lz_azureHook.service -f
```

Both hooks also write two rotating log files beside their executable on Linux and
Windows. See [Logging](#logging) for the size limit and retention behavior.

Removal uses the existing daemon command:

```sh
sudo "$daemon_bin" remove awsHook
# Or, on Azure:
sudo "$daemon_bin" remove azureHook
```

## Install on Windows Server

For automated initial setup, see [Windows cloud setup](#windows-cloud-setup).
For manual installation, follow the steps below.

Use the current daemon's Windows binary, which hosts ordinary executables through
its Windows service wrapper. Open PowerShell **as Administrator**. Put the hook
in an administrator-controlled directory such as `C:\ProgramData\CloudHooks`;
the executable, log file, and directory must not be writable by untrusted users.
The existing daemon installs services as LocalSystem by default.

AWS:

```powershell
& $daemon_bin install awsHook "C:\ProgramData\CloudHooks\aws_hook-windows-amd64.exe"
& $daemon_bin start awsHook
```

Azure:

```powershell
& $daemon_bin install azureHook "C:\ProgramData\CloudHooks\azure_hook-windows-amd64.exe"
& $daemon_bin start azureHook
```

Use the ARM64 binaries only on ARM64 Windows systems. No new daemon commands,
cloud credentials, ASG name, or region arguments are needed.

The hook identifies its own hosting service by matching the parent daemon
wrapper's process ID to SCM service status. It must run through the current
daemon wrapper, not directly from PowerShell or through another service host.
It fails closed if it cannot establish a unique managed hosting service.

On Windows, read both logs beside the hook executable because the existing
wrapper does not capture the child's standard output/error:

```powershell
Get-Content "C:\ProgramData\CloudHooks\aws_hook-windows-amd64.exe.[12].log" -Wait
# Or, on Azure:
Get-Content "C:\ProgramData\CloudHooks\azure_hook-windows-amd64.exe.[12].log" -Wait
```

The service account needs write access to that trusted directory and query/stop
access to the managed services.

Remove the hook using the existing command:

```powershell
& $daemon_bin remove awsHook
# Or, on Azure:
& $daemon_bin remove azureHook
```

## Logging

AWS and Azure hooks use the same logging behavior on Linux and Windows:

- The files are `<hook-executable>.1.log` and `<hook-executable>.2.log`, beside
  the executable.
- Each file is capped at **5 MiB (5,242,880 bytes)**, for **10 MiB total**.
- New installations start in file 1. Before an entry would exceed the limit,
  the other file is cleared and becomes the active file. When file 2 fills,
  file 1 is cleared and reused. The previous file is retained until the next
  switch; no files are deleted or renamed.
- On restart, the most recently modified nonempty file is selected for
  appending. Empty files are ignored. Existing oversized files are cleared
  during startup to restore the size limit.
- A single entry larger than the limit is rejected rather than growing the
  file beyond the cap. File-write errors are reported to stderr.
- Startup, termination notices, shutdown results, and metadata errors are
  logged. Successful routine metadata polls remain silent.

The service account must be able to create and write both logs in the executable's
trusted directory. Failure to open either log prevents hook startup. New log files
use mode `0600` on Linux; Windows access is controlled by the directory/file ACLs.
Log output is also sent to stderr, so Linux systemd journal commands still work.
The file cap does not control journald's separate retention policy.
Older single-file `<hook-executable>.log` files are no longer used; archive or
remove those manually after upgrading if they exist.

For example, after Linux AMD64 quick-start setup, from the repository root:

```sh
sudo tail -f ./cloud_hook/build/aws_hook-linux-amd64.[12].log
# Or, on Azure:
sudo tail -f ./cloud_hook/build/azure_hook-linux-amd64.[12].log
```

## AWS prerequisite: termination lifecycle hook

Configure an ASG lifecycle hook:

| Setting | Value |
| --- | --- |
| Transition | `autoscaling:EC2_INSTANCE_TERMINATING` |
| Default result | `CONTINUE` |
| Heartbeat timeout | Longer than detection time plus application stop time |

IMDS must be enabled and reachable. The watcher obtains and refreshes IMDSv2
tokens, bypasses HTTP proxies, and checks the target lifecycle state every ten
seconds. A target of `Terminated` triggers application stopping while the
lifecycle hook keeps the VM running.

This intentionally uses **timeout-only completion**: it does not acknowledge,
extend, or configure the lifecycle hook. AWS proceeds when the hook expires.
No AWS API permissions are needed, but AWS waits for the full hook deadline even
if cleanup finishes early. Do not configure another handler to complete the
hook before these applications finish.

For a 300-second hook, budget less than 300 seconds for detection, stop ordering,
and cleanup combined. Neither Linux's default `TimeoutStopSec=600s` nor the
Windows wrapper's application stop allowance extends the AWS deadline.
Increase the hook timeout or reduce application stop time as appropriate.
Without a termination hook, metadata detection alone provides no protected
cleanup window.

This handles normal ASG termination notices, not every EC2 stop/delete action,
warm-pool transition, Spot interruption, or host failure.

## Azure prerequisite: VMSS termination notifications

Enable termination notifications on the VM Scale Set and configure a delay long
enough for application cleanup. Apply the updated model to existing instances
as required by the scale set's upgrade policy.

The watcher reads this instance's metadata identity, then polls Scheduled Events
every ten seconds. It acts only on `Terminate` events whose `Resources` include the
exact local VM name or full resource ID. Events for other instances, maintenance
events such as `Freeze`/`Reboot`, and Spot `Preempt` events do not stop services.

This hook does not acknowledge the event early or extend its deadline. Azure
continues according to its configured notification window. Metadata errors,
including Scheduled Events initialization delays, are logged and retried.

This is not a promise of advance notice for every standalone VM deletion or
forced shutdown.

### Enable Azure termination notifications

In the **Azure Portal**, open **Virtual machine scale sets**, select your scale
set, then:

1. Open **Configuration**.
2. Set **Enable instance termination notification** to **On**.
3. Set **Termination delay (minutes)** to **15** and select **Save**.
   Azure supports 5-15 minutes; allow time for detection as well as cleanup.
   Fifteen minutes leaves room for the daemon's default 600-second stop timeout.
4. Ensure existing instances receive the updated scale-set model according to
   your upgrade policy. For a Uniform scale set using Manual upgrades, open
   **Instances**, select a test instance, and choose **Upgrade** before rolling
   out to the remaining instances. Review pending model changes first: applying
   the model can also apply other changes and may disrupt workloads.

Alternatively, use **Azure CLI** from Cloud Shell or an administrator's machine
signed into the correct subscription with permission to update the scale set:

```sh
RESOURCE_GROUP="your-resource-group"
SCALE_SET="your-scale-set"

az vmss update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SCALE_SET" \
  --set \
    virtualMachineProfile.scheduledEventsProfile.terminateNotificationProfile.enable=true \
    virtualMachineProfile.scheduledEventsProfile.terminateNotificationProfile.notBeforeTimeout=PT15M

az vmss show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SCALE_SET" \
  --query virtualMachineProfile.scheduledEventsProfile.terminateNotificationProfile
```

The query should show `enable: true` and `notBeforeTimeout: "PT15M"`. This checks
the scale-set model, not whether every existing instance has received it.
For a Uniform scale set with Manual upgrades, apply the model to one test
instance using its actual instance ID:

```sh
INSTANCE_ID="your-test-instance-id"
az vmss update-instances \
  --resource-group "$RESOURCE_GROUP" \
  --name "$SCALE_SET" \
  --instance-ids "$INSTANCE_ID"
```

Azure CLI and Azure management credentials are needed only for these cloud
configuration commands, not by `azureHook`. These steps do not enable Spot
termination handling or guarantee a cleanup window for every VM deletion.
See Microsoft's [VMSS termination notification documentation](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-terminate-notification).

## Service discovery and failure behavior

- The ownership convention is `lz_lz_<name>.service` on Linux and `lz_lz_<name>`
  on Windows, with current daemon service-name rules. Legacy daemon installations
  without the prefix are not discovered.
- The watcher's own service is identified from its systemd cgroup on Linux or
  parent wrapper PID on Windows and excluded, even under a different valid
  service name. Discovery fails closed if that identity cannot be established
  or found among the installed services.
- All other matching installed services are stopped, including disabled services
  that might currently be running. Only one cloud watcher should be installed
  per VM.
- Systemd honors unit dependency ordering; one stop transaction does not imply
  that every application's cleanup starts simultaneously.
- Windows requests stops for running services and waits for stopped status,
  skipping services already stopped or stopping. Stop failures (including
  dependencies not yet stopped) are reported but not retried.
  Pending stops are polled without resending the control.
- Metadata errors are logged and polling retries until a valid termination
  notice arrives. After that notice, the watcher makes one stop attempt,
  logs success or failure, and stops polling metadata. Failed stop commands or
  unsuccessful service results are not retried; remaining applications may
  only stop during normal OS shutdown.
- Errors are never treated as a termination notice or successful cleanup.
  Successful native service status still cannot prove that
  business-level cleanup was implemented correctly. In particular, Windows SCM
  success does not distinguish graceful application exit from the existing
  wrapper's forced job termination after its application stop timeout.
- After either stop success or failure, the watcher remains alive until OS
  shutdown so service recovery does not repeat the stop attempt. It does not
  restart applications if the cloud operation is later cancelled.
- The cloud deadline can expire even if cleanup fails or is still in progress.
  Neither hook prevents forced power-off, an abrupt failure, or Spot reclamation.
- Stopping applications here does not coordinate load-balancer draining. Configure
  traffic draining separately so cleanup does not interrupt active requests.

## Validation

From the repository root:

```sh
go test -race ./cloud_hook/...
go vet ./cloud_hook/...
```

Tests simulate metadata responses, systemd commands, and Windows service
controllers; they do not contact cloud metadata or stop real services. The
Windows service-control algorithm is tested on any host; native SCM integration
requires Windows. On a Windows test host, run:

```powershell
go test ./cloud_hook/...
go vet ./cloud_hook/...
```

Before production deployment, test actual ASG/VMSS scale-in on disposable Linux
and Windows instances. Verify that the hook receives the notice, excludes its
own hosting service, and that every application's cleanup finishes before the
cloud deadline. Confirm that the hook stays alive until instance shutdown and
that the instance is subsequently terminated.

## Provider documentation

- [AWS target lifecycle state through IMDS](https://docs.aws.amazon.com/autoscaling/ec2/userguide/retrieving-target-lifecycle-state-through-imds.html)
- [Azure VMSS termination notifications](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-terminate-notification)
- [Azure Scheduled Events](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/scheduled-events)
