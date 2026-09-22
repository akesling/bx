# bx

Run commands inside a [`smolvm`](https://smolvm.dev) microVM, with host
directories mounted and the machine's lifecycle handled for you.

`bx` is the generic core: create, start, feed, and stop a machine. A caller —
a script, a Makefile, or the bundled `bx-pi` profile — supplies the image, the
mounts, a one-time bootstrap, and the command. It is deliberately small, but it
takes the unglamorous parts seriously: reconciling the machine's shape,
refusing to run two drivers at once, and telling you what it will do before it
does it.

## Install

```sh
git clone <this repo> ~/src/bx
cd ~/src/bx
./install.sh                 # installs into ~/.local/bin
```

`PREFIX` chooses another prefix, `DESTDIR` stages a package root, and
`./install.sh --uninstall` removes exactly what a previous install wrote.

Dependencies: `smolvm` on `PATH`. `bx-pi` additionally needs a Subconscious
login (`subc login`) or `SUBCONSCIOUS_API_KEY`.

## Use

The command comes from the environment, so a project wires `bx` in without
forking it:

```sh
export BX_MOUNTS="$PWD:/work"
export BX_WORKDIR=/work
export BX_COMMAND="make test"
bx
```

Or from a terminal:

```sh
bx --dry-run            # print the plan and touch nothing
bx --reset              # recreate a machine whose shape drifted
bx --keep               # leave the machine running afterwards
```

## bx-pi

`bx-pi` runs the [pi](https://github.com/earendil-works/pi-coding-agent) agent
inside the guest, with the Subconscious provider configured and bun + pi
installed on first use:

```sh
cd ~/src/some-project
bx-pi -p "run the tests and summarize the failures"
```

Each working directory gets its own machine (named `pi-<dirname>`), mounted at
`/work`. Extra arguments are forwarded to pi; `--model`, `--dir`, `--profile`,
`--reset`, and `--keep` are handled by the wrapper.

## The contract

These are the behaviors the test suite pins, because each one has a failure
mode that is expensive to debug:

- **One driver per machine.** A lock (a directory holding the holder's PID)
  makes a second launch fail fast, naming the holder, rather than sharing a VM
  and racing its lifecycle. A lock whose holder is gone is reclaimed.
- **Reconciled shape.** `smolvm` binds mounts, CPUs, and memory at *create*
  time. `bx` records that shape and refuses to reuse a machine whose shape
  changed, printing the diff and pointing at `--reset`. Silently reusing a
  stale mount set is how boot panics start.
- **Honest exit status.** The command's exit status becomes `bx`'s, and the
  cleanup trap still stops the machine and releases the lock on failure.
- **Dry run.** `--dry-run` prints the machine, image, resources, mounts, the
  action it would take, and the lock and state paths — and changes nothing.
- **Secrets stay out of argv.** Values cross into the guest via
  `smolvm --secret-env`, resolved by name, never as command-line arguments.

## Configuration

Every variable is optional except the command.

| Variable | Default | Meaning |
| --- | --- | --- |
| `BX_COMMAND` | — | shell to run in the guest (required) |
| `BX_IMAGE` | `debian:bookworm-slim` | guest image |
| `BX_NAME` | `bx` | machine name |
| `BX_CPUS` / `BX_MEM` | `4` / `4096` | vCPUs / MiB |
| `BX_NET` | `1` | enable networking |
| `BX_MOUNTS` | — | newline-separated `HOST:GUEST` pairs |
| `BX_BOOTSTRAP` | — | shell run once in the guest before the command |
| `BX_PRE_COMMAND` | — | host shell run after start, before the bootstrap |
| `BX_BOOTSTRAP_ENV` | — | newline-separated `KEY=VALUE` for the bootstrap |
| `BX_SECRET_ENV` | — | newline-separated `GUEST=HOSTVAR`, passed by name |
| `BX_WORKDIR` | — | guest directory to run in |
| `BX_STATE_DIR` | XDG state dir | where the lock and recorded shape live |
| `BX_RESET` / `BX_KEEP` | `0` | recreate / leave running |
| `BX_DRY_RUN` | `0` | print the plan and exit |

## Development

```sh
sh scripts/check.sh      # shellcheck + the test suite
```

The suite runs entirely on the host against a fake `smolvm` on `PATH`, so it
needs no VM, no network, and no account.

## License

MIT.
