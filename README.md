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
> cannot) and then edit the project (it can). Record it on a KVM host with
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

Requires `smolvm` on `PATH` and a Linux host with virtualization available.
`bx` itself needs nothing else — no account, no config, no network.

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
  action it would take, and the lock and state paths — and changes nothing.
- **Secrets stay out of argv.** Values cross into the guest via
  `smolvm --secret-env`, resolved by name, never as command-line arguments.

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

- Linux hosts only; it needs KVM and `smolvm` on `PATH`.
- One machine per project directory, not one shared across all of them.
- No Windows or macOS guest/host story yet.
- The generic `bx` core needs no account. The shipped `bx pi` recipe needs a
  Subconscious login or API key, because that's the provider the agent talks
  to. The `sandbox` recipe and anything you write need neither.

`bx` is a ~500-line shell script, deliberately. There's no daemon, no control
plane, and no state you can't read with `ls`.

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
| `BX_SECRET_ENV` | both | — | newline-separated `GUEST=HOSTVAR`, passed by name |
| `BX_WORKDIR` | both | — | guest directory to run in |
| `extends` | recipe | — | inherit from another recipe |
| `resolve` | recipe | — | run a resolver before merging (see `recipes/README.md`) |
| `machine` | recipe | — | the machine recipe this command runs on |
| `profile` | recipe | — | hand off to a host-side executable instead of a guest command |
| `BX_STATE_DIR` | both | XDG state dir | where the lock and recorded shape live |
| `BX_RESET` / `BX_KEEP` | both | `0` | recreate / leave running |
| `BX_DRY_RUN` | both | `0` | print the plan and exit |

## Development

```sh
sh scripts/check.sh      # shellcheck + the test suite
```

The suite runs entirely on the host against a fake `smolvm` on `PATH`, so it
needs no VM, no network, and no account.

`scripts/demo.sh` shows the boundary (and refuses to fake it without a real
`smolvm`); `scripts/bench.sh` produces the Cost table above, and prints no
number it did not measure. `docs/launch.md` is the runbook that ties them
together.

## License

MIT.
