# The recipe book

A **recipe** is a named, declarative description of a machine or of a command
to run on one. A **recipe book** is a directory of them. `bx` is the
interpreter; the book is the product.

This document is the format. If a recipe needs you to read `bx`'s source to
understand it, the format has failed.

## Where books live

Machines and commands live in separate directories, because the common case is
many commands and few machines. They share one grammar; only the directory
differs. Read in increasing precedence, so a later source overrides an earlier
one:

1. `share/bx/machines/`, `share/bx/recipes/` in the install prefix — the
   shipped book.
2. `~/.bx.conf`, `./.bx.conf` — flat files that may hold **both** kinds.
3. `~/.bx/machines/`, `./.bx/machines/` — machine recipes.
4. `~/.bx/recipes/`, `./.bx/recipes/` — command recipes.

A recipe with the same name in a later source overrides the earlier one whole
(see **Composition** for the part that still merges).

## Machines and commands

A section with a `command` is a **command recipe**: what to run. A section
without one is a **machine recipe**: the image, resources, mounts, and the
one-time bootstrap that must match them. The kind is inferred from the keys,
so a flat `.bx.conf` can hold both:

```ini
# a machine recipe: shape only
[libc_dev]
image   = debian:bookworm-slim
cpus    = 8
mem     = 8192
mounts  = $PWD:/work
workdir = /work

# a command recipe: what to run, and on which machine
[go_test]
machine = libc_dev
command = go test ./...
```

A command recipe may **override** any of its machine's shape keys, which wins
for that recipe only:

```ini
[go_test]
machine = libc_dev
cpus    = 4      # this recipe gets 4 vCPUs, not the machine's 8
command = go test ./...
```

Shape keys are the machine's identity, image, resources, mounts, and setup:
`name`, `image`, `cpus`, `mem`, `net`, `mounts`, `workdir`, `bootstrap`,
`bootstrap_env`, `secret_env`, `pre_command`, `state_dir`.

## A command recipe

```ini
[pi]
extends  = agent_base
machine  = pi_agent
command  = pi
```

A command recipe is a `[name]` section of `key = value` lines. `#` starts a
comment. Values run to the end of the line after trimming.

Only `command` is required. It may also set `machine`, any shape key (an
override), the lifecycle flags, and the meta keys `extends`/`resolve`.

## Keys

Every `bx` setting is a recipe key:

| Key | Meaning |
| --- | --- |
| `command` | shell to run in the guest (what makes a command recipe) |
| `machine` | the machine recipe this command runs on |
| `image` | guest image |
| `name` | machine name |
| `cpus` / `mem` | vCPUs / MiB |
| `net` | enable networking |
| `mounts` | `HOST:GUEST` pairs (repeatable) |
| `workdir` | guest directory to run in |
| `keep` / `reset` | lifecycle flags |
| `bootstrap` | shell run once in the guest before the command |
| `bootstrap_env` | `KEY=VALUE` for the bootstrap (repeatable) |
| `secret_env` | `GUEST=HOSTVAR[:LIFETIME]`, passed by name (repeatable) |
| `pre_command` | host shell run after start, before the bootstrap |
| `state_dir` | where the lock and recorded shape live |
| `extends` | inherit from another recipe (see **Composition**) |
| `resolve` | run a resolver before merging this recipe (see **Resolvers**) |

`mounts`, `bootstrap_env`, and `secret_env` may repeat; the lines are kept in
order.

A `secret_env` line may declare a **lifetime** after the host variable:
`GUEST=HOSTVAR:ephemeral` (the default), `:session`, or `:persisted`. The
lifetime is bx's declaration of how far the value may travel, it is recorded
in the machine's state and shown by `--dry-run` and `--status`, and it is a
hard error to misspell one. See the main README's "Secrets and their
lifetimes" for what bx can and cannot guarantee.

A recipe name must be a shell identifier — letters, digits, and `_`, not
starting with a digit. This is a limitation of the loader, and it is reported
clearly rather than failing later.

## Values are data, not shell

A value is taken literally. `$(...)`, backticks, and `${...}` are **never
evaluated**, so a recipe cannot run code by putting it in a value. Exactly four
references are expanded, because a mount is written with them:

- `$PWD` — the directory `bx` was invoked from
- `$HOME` — your home directory
- `~` / `~/...` — your home directory
- `$<name>` — a declared parameter or a value produced by a resolver (see below)

Everything else is literal. This is a deliberate guarantee: cloning a
repository and running `bx <recipe>` cannot execute the repository's code
through a recipe value.

## Composition

`extends = base` merges the named recipe underneath this one:

- **Scalars** (`image`, `cpus`, `command`, …): this recipe wins if it sets the
  key; otherwise the base's value is used.
- **Lists** (`mounts`, `bootstrap_env`, `secret_env`): the base's lines come
  first, then this recipe's, in order.
- Chains are allowed (`a extends b extends c`); a cycle is an error.

A recipe and its base are resolved before any resolver runs, so a resolver
sees the fully-composed settings.

## Resolvers

Some settings cannot be written as literals — an API key read from a
credential store, a gateway URL looked up from a config file, a set of
`secret_env` names that depends on which provider is configured. A recipe may
name a **resolver**: a program in the same book (or on `PATH`), referenced by
`resolve` and invoked by `bx` before the recipe is merged.

```ini
[pi]
resolve = pi.resolve
command = pi
mounts  = $PWD:/work
```

`resolve = pi` runs `<book>/pi.resolve` (or `pi.resolve` on `PATH`). A resolver
is a normal executable, auditable on its own, and **is the only way a recipe
can run host code.** The `values-are-data` guarantee applies to recipe values;
a resolver is explicitly a program, referenced by name, in a file you can
read.

### The resolver contract

A resolver is run with no arguments, once per recipe, and writes lines to
stdout:

```
KEY=VALUE
```

- `KEY=VALUE` — a recipe key. The value is merged exactly as if the recipe
  had written it, using the same scalar/list rules: a scalar sets the key, a
  list appends.
- `@param NAME=VALUE` — declares a parameter and makes `$NAME` available in
  this recipe's values, including in `mounts`.
- `@secret NAME=VALUE` — hands a value to `bx` out of band, exported as the
  host variable `NAME` for `secret_env` to pass by name. `@secret` values do
  not appear in the resolved recipe, in `--show` output, or in argv; that is
  the point of the `@` form. (The runtime still writes the value into the
  machine's bundle config; see the main README's "Secrets and their
  lifetimes".) A secret declared in `secret_env` must still be listed by the
  recipe.
- A line that is blank or begins with `#` is ignored.
- Any other output makes the resolver fail, and `bx` stops.

A resolver that exits non-zero stops the run with its message. A resolver is
run for `--show` and `--dry-run` too, so the resolved recipe is always the
thing you inspect.

### Example

`pi.resolve`:

```sh
#!/bin/sh
# Emit the settings that depend on this host's Subconscious config.
key="$(read_key_from_somewhere)"
printf '@param AGENT_HOME=%s\n' "$HOME"
printf '@secret SUBCONSCIOUS_API_KEY=%s\n' "$key"
printf 'secret_env=SUBCONSCIOUS_API_KEY=SUBCONSCIOUS_API_KEY\n'
printf 'bootstrap_env=SUBCONSCIOUS_API_KEY\n'
```

The recipe then uses those values as ordinary recipe values:

```ini
[pi]
resolve = pi.resolve
mounts  = $AGENT_HOME/.pi:/root/.pi
```

## Provenance

`bx --show <recipe>` prints the resolved recipe **and where each value came
from**: the shipped default, a base recipe, this recipe, a resolver, or an
environment override. Resolution is explainable, or it is not trustworthy.

## The command line

Two flags override the recipe, and both mean "the command line wins":

- `--machine=<name>` replaces the whole shape. The named machine is used
  verbatim and the command recipe's `machine` and shape keys are **ignored**,
  while its `command` and lifecycle flags survive. Use it to rerun a recipe on
  a bigger or smaller machine without editing the file.
- `--name=<name>` overrides the machine's identity, so a second run gets its
  own machine instead of reusing or colliding with the first.

`bx --show <recipe>` reports what was ignored and why, under `sources=`.

## Writing your first recipe

```sh
bx --new mine        # scaffold ~/.bx/recipes/mine.conf and print its path
bx --show mine       # inspect it, with provenance
bx mine              # run it
```

## The shipped book

`share/bx/machines/`:

- `default.conf` — the generic sandbox shape, shared by `bash` and `sandbox`.
- `pi_agent.conf` — the shape and bootstrap the `pi` recipe runs on.

`share/bx/recipes/`:

- `pi.conf` — the `pi` coding agent. It exists to prove the format can
  describe a real agent setup entirely as data plus one resolver.
- `bash.conf` — run a bash command in a machine with only `$PWD` mounted.
- `sandbox.conf` — a bare interactive Debian shell in a machine. It exists to
  prove `pi` is not special: two recipes make a book, and both share one
  machine.

None is compiled into `bx`. Delete them all and `bx` is unchanged.
