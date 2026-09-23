# bx

**Your coding agent runs on your machine. That means it can read your home
directory, your SSH keys, your cloud credentials, and your browser session —
because it's your machine.**

`bx` runs the agent somewhere that isn't your machine. It's a microVM with
your project directory mounted and nothing else. The agent is just as capable
inside it, and the blast radius when it does something stupid is whatever git
can restore.

The isolation itself is the easy part. The work — and the reason a sandbox you
set up often doesn't survive the second week — is the *lifecycle*: mounts and
resources are bound at create time, machines are long-lived, and nothing
reconciles what a machine *is* against what your config now *says*. `bx` takes
that seriously. See [Why this instead of Docker](#why-this-instead-of-docker-or-a-devcontainer).

<!-- Record with: asciinema rec --cols 80 --rows 24 demo.cast -c 'scripts/demo.sh'.
     Replace this block once the cast exists; see docs/launch.md. -->
> **See it work:** `scripts/demo.sh` drives the guest to read a host secret (it
> cannot) and then edit the project (it can). Record it on any host with `smolvm`
> on `PATH` — macOS via Hypervisor.framework, or Linux with `/dev/kvm` — with
> `asciinema rec --cols 80 --rows 24 demo.cast -c 'scripts/demo.sh'`, then embed
> the cast here.

## What actually happens

`bx pi` boots a small Linux VM, mounts the directory you ran it from, installs
the agent on first use, and runs it. Only that one directory crosses the
boundary. **Your home directory is not mounted.** The guest cannot read your
`~/.ssh`, your cloud credentials, or your browser profile, because none of it
exists inside the machine.

```sh
cd ~/src/some-project
bx pi
```

In the guest, the project is at `/work`, and so is the agent's config
(`/work/.pi/agent`) — it lives on your disk, survives VM restarts, and shows
up in git status so you can ignore it. The guest's own home is wiped with the
machine.

The machine persists between runs, so the second `bx pi` is fast. Run it from
a different directory and you get a different machine, with a different mount
set. Two projects never share a VM.

## Install

```sh
git clone <this repo> ~/src/bx
cd ~/src/bx
./install.sh                 # bx into ~/.local/bin, the book into ~/.local/share/bx
```

`PREFIX` chooses another prefix, `DESTDIR` stages a package root, and
`./install.sh --uninstall` removes exactly what a previous install wrote.

Requires `smolvm` on `PATH` on a host with hardware virtualization — macOS on
Apple silicon (Hypervisor.framework) or Linux with `/dev/kvm`. `bx` itself needs
nothing else — no account, no config, no network.

### If you want the bundled agent

`bx pi` runs [pi](https://github.com/earendil-works/pi-coding-agent) in the
guest. That profile talks to Subconscious, so it needs either a login or an
API key. **Set it up the first time you actually run the agent, not before:**

```sh
subc login                   # or: export SUBCONSCIOUS_API_KEY=...
bx pi -p "run the tests"
```

The first run installs bun and pi into the guest (takes a moment). After that
the machine is warm.

## What you get, concretely

`bx` is a generic core: create, start, feed, and stop a microVM. A recipe
supplies the image, mounts, bootstrap, and command. Because the machine is
long-lived and `smolvm` binds mounts and resources at *create* time, the
interesting work is keeping the machine honest over time. These behaviors are
pinned by the test suite because each one is expensive to debug when it's
wrong:

- **One driver per machine.** A lock makes a second launch fail fast, naming
  the holder, instead of sharing a VM and racing its lifecycle.
- **Reconciled shape.** `bx` records what the machine was created with and
  refuses to reuse one whose shape changed — printing the diff and pointing
  at `--reset`. Silently reusing a stale mount set is how boot panics start.
- **Dirty exits are cleaned up.** The command's exit status becomes `bx`'s,
  and the machine is still stopped and the lock still released on failure.
- **Dry run.** `--dry-run` prints the machine, image, resources, mounts, the
  action it would take, the lock and state paths, the image and toolchain
  cache state, and a cost estimate — and changes nothing. It needs no `smolvm`
  on `PATH`.
- **Secrets stay out of argv.** Values cross into the guest via
  `smolvm --secret-env`, passed by name, never as command-line arguments. bx
  also keeps them out of its own state files and `--show` output. See
  [Secrets and their lifetimes](#secrets-and-their-lifetimes) for what the
  runtime does with them on disk — the one place bx cannot reach.
- **A machine is reclaimable.** `--status` lists every machine with the
  directory it came from, whether that directory still exists, and how big its
  private state is. `--gc` reclaims machines whose directory is gone, after
  showing you the list.

## When it breaks

The machine records the mounts, CPUs, and memory it was created with. If you
change any of those, `bx` refuses to start and tells you so, because `smolvm`
can't change them in place:

```
bx: machine 'pi-myproject' was created with a different shape:
  want: cpus=4
        mem=4096
        mounts=/home/me/proj:/work /home/me/data:/data
  have:
        cpus=4
        mem=4096
        mounts=/home/me/proj:/work
smolvm binds mounts and resources at create time, so this cannot be fixed by
starting again. Pass --reset to recreate it.
```

That's expected, not a bug. `--reset` destroys the machine and builds a new
one; your mounted directory is untouched. `--keep` leaves the machine running
after the command exits.

## Why this instead of Docker or a devcontainer

If you have a container setup that's working, keep it — there's no reason to
move. `bx` is for the case where you want the boundary to be a real VM, the
mount set to be exactly one directory, and the whole thing to work without
writing per-repo infra.

The longer argument is that the container advice handles *isolation* — which is
the easy part — and leaves the *lifecycle* unowned, which is why a lot of
people who agree with agent sandboxing never actually keep one. That argument
is written out in full, with no `bx` in it, in
[`docs/essays/agent-sandbox-lifecycle.md`](docs/essays/agent-sandbox-lifecycle.md).
Four questions
predict whether you'll still be using a sandbox next month:

1. What happens when the shape changes? (`bx` records it and refuses to reuse
   a machine that no longer matches — see **When it breaks** above.)
2. What happens when two runs overlap? (`bx` fails fast on a held lock.)
3. What happens to a machine left behind? (`--keep` / `--reset` are explicit.)
4. Can you see the plan before it runs? (`--dry-run`.)

### Related work

`lima`, `colima`, devcontainers, `firecracker`, `microsandbox`, and the
various hosted agent sandboxes all do isolation well — several do more than
`bx`. The gap `bx` was built to fill is the lifecycle handling above, not the
isolation itself.

### What this doesn't do

- One machine per project directory, not one shared across all of them.
- No Windows host story yet.
- The generic `bx` core needs no account. The shipped `bx pi` recipe needs a
  Subconscious login or API key, because that's the provider the agent talks
  to. The `sandbox` recipe and anything you write need neither.

`bx` is a ~500-line shell script, deliberately. There's no daemon, no control
plane, and no state you can't read with `ls`.

## Hosts

`bx` runs wherever `smolvm` does. As of today that is:

- **macOS** on Apple silicon, via Hypervisor.framework. This is the primary
target — the shipped `pi` recipe is developed on a Mac.
- **Linux**, via KVM (`/dev/kvm` must exist).

The VMM is smolvm's business, not `bx`'s. `bx` only needs `smolvm` on `PATH` and
a host where it can boot a machine. The capability probe used by the test and
benchmark harnesses is therefore "`smolvm` is on `PATH`, and this is either
macOS or a Linux host with `/dev/kvm`" — not a `/dev/kvm` check, which would
wrongly skip the Mac.

### Containers inside the guest

You can run ordinary Linux containers *inside* a bx machine. The guest is a
full Linux environment with a container-capable kernel (namespaces, cgroup v2,
overlayfs, fuse), and the agent can install and use a runtime exactly as it
would on a server:

```sh
bx bash
# in the guest
apt-get install -y podman
podman run -d --name pg -e POSTGRES_PASSWORD=secret -p 5432:5432 \
  docker.io/library/postgres:16
podman exec pg psql -U postgres -c 'SELECT version()'
```

One caveat, because the guest rootfs is itself an overlayfs: podman's default
`overlay` storage driver refuses to start over overlayfs. Use `vfs` (full-copy,
no copy-on-write — slower and disk-hungry but correct), or install
`fuse-overlayfs` for copy-on-write. Either way, set it in
`/etc/containers/storage.conf`:

```toml
[storage]
driver = "vfs"
```

**This is a capability, and it is worth understanding before leaning on it.**
Running containers inside the guest widens what code inside the fence can do:
the nested containers run as root with the guest's capability set.
`SMOLVM_DOCKER_SOCKET` can publish `/var/run/docker.sock` across the boundary,
which is a host-reaching bridge by design. And a nested container is a second
long-lived, mutable thing inside the machine — with its own shape, its own
locks, and its own reclamation problem. `bx` does **not** manage that lifecycle
today; it manages the *machine's*. Treat containers-in-guest as something the
agent does inside the sandbox, not as a second thing `bx` reconciles.


## Costs

What this side of the boundary actually costs, measured on real hardware with
`scripts/bench.sh --real`. **These are orders of magnitude, not absolutes —
re-run the script on your own machine.**

<!-- Paste the table emitted by `scripts/bench.sh --real` here.
     Until then, the slots below are deliberately empty. -->

| Metric | Value |
| --- | --- |
| Cold boot (fresh machine, command runs) | _not yet measured_ |
| Warm run (machine already exists) | _not yet measured_ |
| Idle footprint (state dir on disk) | _not yet measured_ |

The first `bx pi` is slower than the later ones: it installs bun and pi into
the guest once. After that the machine is warm and a run is quick.

## Use

A **recipe** describes a machine or a command to run on one. A section with a
`command` is a command recipe; one without is a machine recipe, defining a
shape others run on. The shipped book has a few of each; yours can have as
many as you want.

```sh
bx pi            # the shipped pi recipe
bx sandbox       # a bare shell in a machine, to poke at
bx --list        # what is available
bx --new mine    # scaffold your own, then `bx --show mine`
```

Many commands, few machines is the common shape, so they live in separate
directories and the command recipes point at one:

```ini
# ~/.bx/machines/libc_dev.conf — a shape
[libc_dev]
image   = debian:bookworm-slim
cpus    = 8
mem     = 8192
mounts  = $PWD:/work
workdir = /work
```

```ini
# ~/.bx/recipes/go_test.conf — a command, on that shape
[go_test]
machine = libc_dev
command = go test ./...
```

A command recipe may override any of its machine's shape keys, and the
override wins for that recipe alone:

```ini
[go_test]
machine = libc_dev
cpus    = 4          # this recipe gets 4, not the machine's 8
command = go test ./...
```

Both kinds can also live in one flat file, which is what a `.bx.conf` is for:

```ini
# ~/.bx.conf — a machine section and a command section together
[test_machine]
image = debian:bookworm-slim

[test]
machine = test_machine
command = make test
cpus    = 8
```

Sources are read in increasing precedence — the shipped `machines/` and
`recipes/`, `~/.bx.conf`, `./.bx.conf`, then `~/.bx/machines/`,
`./.bx/machines/`, `~/.bx/recipes/`, and `./.bx/recipes/`. A recipe with the
same name in a later source overrides the earlier one. `extends` composes
recipes, and `resolve` names a program that computes values this host must
supply. The format is documented in full in
[`recipes/README.md`](recipes/README.md).

### Overriding the machine from the command line

Two flags override the recipe, and both mean "the command line wins":

```sh
bx --machine=bigtest go_test    # run go_test on bigtest's shape, exactly
bx --name=go_test_2 go_test     # give this run its own machine
```

`--machine` replaces the shape wholesale: the named machine is used verbatim
and the recipe's own `machine` and shape keys (including their overrides) are
ignored, while its `command` and lifecycle flags survive. `--show` reports
what was ignored and why, under `sources=`.

Inspect before running anything:

```sh
bx --show sandbox                 # the resolved recipe, with where each value came from
bx --dry-run sandbox              # the machine plan it would produce
bx --machine=default --show pi    # what --machine would change
```

Values are data, not shell: `$(...)` stays literal and is never evaluated.
`~`, `$HOME`, `$PWD`, and resolver parameters are expanded. A misspelled key
is an error, not a silently ignored line. A recipe name must be a shell
identifier — letters, digits, and `_`.

Extra arguments after the recipe name are appended to its command, so
`bx pi -p "run the tests"` forwards `-p "run the tests"` to pi in the guest.

### No recipe needed

Any setting can still come from the environment for an ad-hoc run, and the
environment beats a recipe:

```sh
export BX_MOUNTS="$PWD:/work" BX_WORKDIR=/work BX_COMMAND="make test"
bx
```

## The shipped recipes

In `share/bx/machines/`: `default` (the generic sandbox shape, shared by `bash`
and `sandbox`) and `pi_agent` (the shape and first-boot setup `pi` runs on).

In `share/bx/recipes/`:

- **`pi`** runs the [pi](https://github.com/earendil-works/pi-coding-agent)
  agent in the guest, with the provider configured and bun + pi installed on
  first use. It is a command recipe on the `pi_agent` machine, plus one
  resolver (`recipes/pi.resolve`), not a special case in `bx`: delete it and
  `bx` is unchanged.

  ```sh
  cd ~/src/some-project
  bx pi -p "run the tests and summarize the failures"
  ```

  Each working directory gets its own machine (named `pi-<dirname>`), mounted
  at `/work`. The resolver reads your Subconscious config for the gateway, key,
  and model, and passes the secret into the guest by name.

- **`bash`** runs a bash command in a machine with only `$PWD` mounted. The
  command is whatever you pass after the recipe name; extra arguments are
  appended to `command`, so nothing is interpreted on the host.

  ```sh
  bx bash -c 'uname -a'          # one command, in a throwaway machine
  bx bash -c 'go test ./...'     # a build, isolated from your machine
  bx bash                        # an interactive bash
  ```

- **`sandbox`** is a bare interactive Debian shell in a machine with one mount.
  It exists to prove `pi` is not special, and to give the fence a place to be
  demonstrated without an account. It shares the `default` machine with
  `bash`.

## Configuration

Every variable is optional except the command. The "Where" column says whether
a key is read from the environment, as a recipe key, or both; `profile`,
`extends`, and `resolve` are recipe-only.

| Variable | Where | Default | Meaning |
| --- | --- | --- | --- |
| `BX_COMMAND` | both | — | shell to run in the guest (required) |
| `BX_MACHINE` | both | — | machine recipe to run on, replacing the recipe's shape |
| `BX_IMAGE` | both | `debian:bookworm-slim` | guest image |
| `BX_NAME` | both | `bx` | machine name |
| `BX_CPUS` / `BX_MEM` | both | `4` / `4096` | vCPUs / MiB |
| `BX_NET` | both | `1` | enable networking |
| `BX_MOUNTS` | both | — | newline-separated `HOST:GUEST` pairs |
| `BX_BOOTSTRAP` | both | — | shell run once in the guest before the command |
| `BX_PRE_COMMAND` | both | — | host shell run after start, before the bootstrap |
| `BX_BOOTSTRAP_ENV` | both | — | newline-separated `KEY=VALUE` for the bootstrap |
| `BX_SECRET_ENV` | both | — | newline-separated `GUEST=HOSTVAR[:LIFETIME]`, passed by name |
| `BX_WORKDIR` | both | — | guest directory to run in |
| `extends` | recipe | — | inherit from another recipe |
| `resolve` | recipe | — | run a resolver before merging (see `recipes/README.md`) |
| `machine` | recipe | — | the machine recipe this command runs on |
| `profile` | recipe | — | hand off to a host-side executable instead of a guest command |
| `BX_STATE_DIR` | both | XDG state dir | where the lock and recorded shape live |
| `BX_RESET` / `BX_KEEP` | both | `0` | recreate / leave running |
| `BX_DRY_RUN` | both | `0` | print the plan and exit |
| `SMOLVM_STORAGE` | env | guest storage root | where `--status`/`--gc` look for machine sizes (inside the machine: `/storage`) |

## Running commands, faithfully

`bx pi` should be hard to tell apart from running `pi` in the ways the user
controls — and deliberately different in the ways isolation requires. The
fidelity guarantees:

- **Exit status is the guest command's.** bx exits with exactly the status the
guest returned; it does not flatten it.
- **Signals reach the guest.** `bx` runs the exec in the foreground, so a
  terminal's `Ctrl-C`, `TERM`, and resize (`WINCH`) go to the whole foreground
  job — `smolvm` and, through it, the guest — exactly as they would to `pi` run
  directly. `bx` still runs its cleanup (stop the machine, release the lock) on
  the way out.
- **A piped run is silent.** bx's narration about the machine (creating it,
  starting it, the persisted-secret warning) is suppressed when stderr is not
  a terminal, so `bx pi | grep x` carries only the command's own output.
  Setting `BX_VERBOSE` (or `-v`) is an explicit request and always wins.
- **A curated environment is forwarded.** `TERM`, `LANG`/`LC_*`, `COLORTERM`,
  and `TZ` cross into the guest so programs render and sort as they do
  locally. Nothing else does — no `EDITOR`, no `SSH_AUTH_SOCK`, no credentials.

What stays different, on purpose: the environment is not your machine. There
is no `~/.ssh`, no host cache, and a fresh home. Chasing literal identity here
would mean leaking the host, which is the opposite of the point.

## Secrets and their lifetimes

A `secret_env` value is written `GUEST=HOSTVAR[:LIFETIME]`, where `LIFETIME`
is one of:

| Lifetime | Meaning |
| --- | --- |
| `ephemeral` (default) | injected into the guest process environment only |
| `session` | may live in the machine's own writable layer until the machine is deleted |
| `persisted` | may reach a durable path — the project mount, a file in your repo |

bx uses the lifetime to decide what to warn about. It records the declared
lifetime in the machine's state, prints it in `--dry-run` and `--status`, and
prints a warning on any run that declares a `persisted` secret. A typo in the
lifetime is a hard error, not a silent downgrade.

### What bx does not control

bx keeps secret values out of argv, out of its own state files, and out of
`--show`. But the runtime writes the environment it launches the guest with
into the machine's **OCI bundle config**, which is a file on disk under the
runtime's per-machine overlay directory (inside the guest, visible at
`/storage/overlays/persistent-<machine>/bundle/config.json`; on the host it is
under smolvm's own storage root, wherever smolvm keeps it — `/storage` is the
path *inside* the machine, not a host path). That file contains the secret
value, and it persists until the machine is deleted. bx cannot see or scrub
inside it.

The practical consequences:

- Treat smolvm's storage root as secret-bearing, on the host as well as in the
  guest.
- Deleting the machine (`bx --reset`, or `bx --gc` after its directory is
  gone) is what removes it. Stopping the machine does not.
- Declaring a secret `ephemeral` does not stop the runtime from writing it to
  that bundle; it is a promise from bx's side, not an enforced boundary on the
  runtime's. That is why the claim above is scoped to what bx writes.

If the agent config lives under the project mount (as `pi`'s does, at
`/work/.pi/agent`), the credential is on your disk and in your repo's view.
Keep that path in `.gitignore`.

## Development

```sh
sh scripts/check.sh      # shellcheck + the test suite
```

The suite runs entirely on the host against a fake `smolvm` on `PATH`, so it
needs no VM, no network, and no account.

`tests/invariants.sh` is the second suite: it turns each `never`/`only` claim
in these docs into an assertion, and greps everything bx writes for a sentinel
secret. It runs on the host by default; `BX_REAL=1` adds a real isolation suite that
boots a machine and checks the isolation fence directly.

`scripts/demo.sh` shows the boundary (and refuses to fake it without a real
`smolvm`); `scripts/bench.sh` produces the Cost table above, and prints no
number it did not measure. `docs/launch.md` is the runbook that ties them
together.

## License

MIT.
