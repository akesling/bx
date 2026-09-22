# Launch runbook

Everything here is one command, and every command refuses to lie: the demo
exits non-zero without a real smolvm, and the benchmark prints `n/a`
rather than a number it did not measure. Run this on a host with
`smolvm` on `PATH` and hardware virtualization available — macOS on Apple
silicon via Hypervisor.framework, or Linux with `/dev/kvm`.

## 0. Sanity (no VM needed)

```sh
sh scripts/check.sh          # shellcheck (if present) + the full test suite
bash scripts/bench.sh --fake # proves the harness runs and emits no numbers
```

## 1. Record the wall (the highest-ROI artifact)

The demo is the post's evidence. It shows the guest failing to read a
home-directory secret and succeeding at the project mount. Record it:

```sh
asciinema rec --cols 80 --rows 24 demo.cast -c 'scripts/demo.sh'
```

Then:
- Commit `demo.cast` (or upload and link it).
- Embed it at the top of the README, above the fold:

  ```sh
  # once asciinema.org is linked
  [![asciicast](https://asciinema.org/a/<id>.svg)](https://asciinema.org/a/<id>)
  ```

If the recording is made on a host where the fence does **not** hold, the
demo prints `UNEXPECTED` and exits non-zero — fix that before recording.

## 2. Measure it (fill the README table)

```sh
bash scripts/bench.sh --real
```

Paste the emitted Markdown table into the README, under a `## Costs` heading,
in place of the current placeholder. Do not hand-edit the numbers; re-run the
script. A cell reading `n/a` means the harness refused to guess.

## 3. Publish the thesis

The post is the essay, not the repo:

- `docs/essays/agent-sandbox-lifecycle.md` — the argument.
- `bx` is the proof; link the repo from the essay, not the reverse.

Title candidates (pick one, make the claim):
- *The container advice doesn't survive contact with your laptop*
- *Your agent's sandbox is lying to you about its mounts*
- *Agent sandboxing is easy; agent sandbox lifecycles are not*

## 4. Pre-stage the comments

Answer these in the post, not the thread:

| Likely comment | Pre-empted by |
| --- | --- |
| "Just use `docker run`" | Essay: shape is bound at create time; lifecycle is unowned |
| "Why not microsandbox / e2b / daytona?" | README "Related work" (name what each does better) |
| "This is an ad for Subconscious" | README "What this doesn't do"; the demo needs no account |
| "Why not just run containers on the Mac?" | README "Containers inside the guest" — you can, and here is the caveat |
| "How slow?" | The benchmark table, with its hardware caveat |

## 5. The checklist

- [ ] `sh scripts/check.sh` green
- [ ] `demo.cast` recorded, committed, embedded above the fold
- [ ] Benchmark table pasted into README under `## Costs`
- [ ] Essay published; repo linked from it
- [ ] "What this doesn't do" and "Related work" present and generous
- [ ] One non-agent recipe shown, to prove generality
- [ ] Title is a claim, not a product name
