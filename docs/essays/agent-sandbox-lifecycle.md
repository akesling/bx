# The container advice doesn't survive contact with your laptop

Everyone agrees your coding agent should run in a sandbox. Almost nobody does
it. The advice is universally endorsed and almost universally ignored, and the
reason isn't laziness — it's that the obvious implementations don't survive
the second week.

## The advice

"It can read your `.ssh` keys, so run it in a container." You've read this.
You agreed with it. You may even have set one up.

Then one of these happened:

- The devcontainer worked until Node bumped, and fixing it cost more than it
  saved.
- You built a fresh container per run and paid the setup tax every time, until
  you stopped using it for anything quick.
- You kept one long-lived container, changed its mounts, and got a confusing
  failure that you fixed by deleting it and starting over. It happened again
  the next month.
- You wired in your environment, and by the time you were done the container
  could see more of your host than you'd planned.

Containers aren't the problem. **Long-lived sandboxes have a lifecycle, and
the advice never mentions it.** "Run it in a container" is a statement about
isolation. The thing that actually determines whether you still use it next
month is what happens to that container as it ages.

## The property nobody designs for

Here's the part that's genuinely interesting, and it's true of microVMs and
containers alike.

A sandbox's shape — which host directories are mounted, how many CPUs, how
much memory — is typically bound **at creation time**. It can't be changed in
place. `docker run` takes `-v`, `--cpus`, `--memory` and bakes them in. The
same is true of the microVM layer `bx` sits on: mounts and resources are fixed
when the machine is created.

So a long-lived sandbox has a state problem. It was created under one
configuration. Later, you edited the configuration. Now there are two truths:
what the sandbox *is*, and what your config *says*. Nothing reconciles them,
because the tool that manages the config and the tool that owns the lifecycle
are usually different tools that don't talk.

This is how you get the failure everyone has hit and nobody's named:

> You add a mount to your config. You run your command. It succeeds — and the
> mount isn't there. The agent writes to the old path. Or it panics at boot
> because a directory it was told about doesn't exist. You conclude the tool
> is flaky and go back to running the agent on your laptop.

The sandbox didn't fail. The sandbox *lied about itself*, and there was no
mechanism to notice.

## The fix, and why it's small

Once you name the problem, the fix is a few dozen lines: **record the shape,
compare it to the requested shape, refuse to proceed on a mismatch, and tell
the user exactly how to resolve it.**

`bx` records the mounts, CPUs, and memory a machine was created with, in a
file beside the machine. On every start it reconstructs the requested shape
from the (possibly edited) config and diffs the two:

- Equal → proceed.
- Different → stop, print what changed, and point at `--reset`.

```
bx: machine 'pi-myproject' was created with a different shape
    mounts: /home/me/proj:/work
         -> /home/me/proj:/work, /home/me/data:/data
    pass --reset to recreate it
```

That's it. The engineering isn't in the diff — it's in the refusal. The
useful, unglamorous part is that `bx` **will not silently reuse a machine it
can't fully describe.** A stale mount set is how boot panics start, and a tool
that reuses one is a tool that's about to waste your afternoon.

## The other half: one driver per machine

Long-lived sandboxes have a second lifecycle problem. Two invocations, five
seconds apart (you hit enter twice, or your editor spawns a second agent while
the first is running), and now you have two processes driving one machine —
both mutating it, both racing to stop it, both reporting half the picture.

`bx` takes a lock — a directory containing the holder's PID — and a second
launch fails fast, naming the holder, instead of sharing the VM. If the
holder is gone, the lock is reclaimed rather than deadlock. Neither of these
is clever. Both are the difference between a sandbox you trust and one you're
afraid of.

## The point

The reason people don't sandbox their agents isn't that the isolation is hard.
It's that the isolation is easy and the *lifecycle* is unowned, so the first
month is friction and people quit.

If you're building an agent sandbox — or evaluating one — the questions that
actually predict whether you'll still use it in a month aren't "is it a
container or a VM." They're:

1. What happens when the shape changes?
2. What happens when two runs overlap?
3. What happens when the machine is left behind?
4. Can I see the plan before I run it?

Get those four right and the isolation story takes care of itself. Get them
wrong and no amount of `--privileged=false` will keep you using it.

`bx` is my attempt to get those four right, in roughly 500 lines of shell with
no daemon and no state you can't read with `ls`. It's one opinion, and a
narrow one. But I'd argue the four questions above are the real specification
for this category, and almost nobody writes them down.
