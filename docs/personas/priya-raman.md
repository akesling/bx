# Priya Raman — "the reluctant sandboxer"

**Role:** Senior backend engineer, ~40-person Series A infra startup
**Age:** 34
**Stack:** Go and Python services, a Kubernetes cluster she can mostly ignore, `just` + `direnv` in every repo. macOS laptop, Linux dev box, occasional `ssh` into staging.
**Tools she already pays for:** Claude Code, a Cursor seat she forgets to cancel, an $18/mo observability tool she set up once and hasn't logged into since.

## The one-line summary

Priya has already let an AI agent run commands on her machine, she half-regrets it, and she is *one bad afternoon* away from doing something about it — but she will not spend a weekend becoming a virtualization expert to get there.

## Backstory

Six weeks ago she was refactoring a payments module and let the agent "clean up the test fixtures." It ran something like `rm -rf` against a path built from a variable that was empty in her shell. It took out a directory of unchecked-in scratch work and, more memorably, she watched it happen in the transcript, too slow to stop it. Nothing catastrophic. She lost a day.

She didn't stop using agents. She's too productive with them. But something lodged: she now `git stash`es reflexively before letting the agent touch anything, keeps her SSH keys in a passphrase-gated agent, and has a vague, guilty sense that she's one incident away from a very bad week. She's read the "run your agent in a container" advice and *agrees with it in principle*.

She has not done it. Why not:

- She configured a devcontainer once, spent ninety minutes on it, and it broke on the next Node version bump. That ninety minutes bought her exactly one reusable container and no confidence.
- She doesn't have a mental model of Firecracker vs. Docker vs. Lima and doesn't especially want one. She wants the *outcome*, not the taxonomy.
- Her projects are heterogeneous — this one's a Go service, that one's a Python script, one is a Jupyter notebook with a GPU dependency. A per-project setup chore is a per-project setup chore, and she has nine projects.

## How she actually behaves

This is the useful part. Priya's behavior is what the docs and first-run
experience are optimized against.

- **She runs the README's first command verbatim**, including any typos in it, before reading the third section. If step one is a login she doesn't have, she closes the tab. She has closed a hundred tabs.
- **She gives a tool about eight minutes.** Not maliciously. She's context-switching between a failing CI run and a PR review. If nothing visibly worked in eight minutes, it's not that the tool is bad — it's that she'll "come back to it later," which is a lie she tells herself.
- **She tests trust by probing for the wall.** Her literal first experiment, unprompted: get the agent to run `cat ~/.ssh/id_*`, or `env | grep -i token`, or `curl` an internal hostname. She is not being adversarial — she's checking whether the boundary is real before she relaxes into using it. **This is the entire conversion moment, and it happens in the first five minutes whether you stage it or not.**
- **She has a low tolerance for "magic" she can't inspect.** She will run `bx --dry-run` before she runs `bx`, not because the README told her to, but because running a VM she can't see the plan for feels like an unforced error. When `--dry-run` prints a real, legible plan, that *builds* trust rather than spending it.
- **She doesn't read the contract section until something breaks.** Then she reads it greedily and precisely. Docs that anticipate her error message feel like the tool respects her time; docs that don't make her feel stupid and she resents it.
- **She keeps things.** If the machine persists and the second `bx pi` is instant, she'll adopt it into muscle memory. If every invocation pays a 40-second setup tax, she'll use it once a week instead of all day, and a once-a-week tool is a tool she forgets.

## Her emotional arc through the funnel

| Moment | What she's actually thinking | Pass/fail |
| --- | --- | --- |
| Sees the README | "MicroVM, agent sandboxing — okay, this is aimed at me." | Hook lands if the fence/agent angle leads |
| First command | "Please don't make me make an account. Please don't." | **Loses most users here if `subc login` is step one** |
| Machine boots | "Is this going to be slow every time?" | Needs expectation-setting or she misreads the first-boot cost |
| She asks the agent to read her home dir | "Show me the wall. Is it *real*?" | **The conversion beat.** `ls ~` must fail, visibly |
| She reasons about it afterward | "So only `/work` is visible. Oh — that's actually the thing I wanted." | Won |
| She changes her mounts a week later | "Why won't it start? ...oh, `--reset`. Fine." | Retained if the error teaches; churned if it doesn't |

## What wins her, concretely

- **Show the wall in the first thirty seconds**, ideally as output she pastes and sees rather than prose she trusts.
- **No account before value.** A free/anonymous first boot beats a perfect provider integration.
- **A legible `--dry-run`.** Ceremony that makes the machine inspectable converts her skepticism into confidence.
- **Persistence that's actually fast.** The "the machine is still there" moment is what turns a novelty into a habit.
- **Errors that name the fix.** `--reset` in the error, not three sections away.

## What loses her instantly

- A login/signup before anything runs.
- A first run that's slow with no warning ("it's just… slow. okay. next.")
- A README that explains the design philosophy before letting her see one command work.
- The feeling that she now owns a new thing to configure per project. The whole reason she hasn't used containers is that containers were another project. If `bx` reads as "another thing I maintain," she's out, however good the invariants are.

## The one thing that makes her a *repeat* user

Not the sandboxing — she already believed in sandboxing. It's the moment she notices she has stopped `git stash`ing before invoking the agent. When the reflex changes, the tool has landed. That's the thing to optimize the first-run experience toward, and everything in `README.md` should be arranged in service of it.

## Why this persona is a skeptic who converts, not a fan

Fans are easy and don't need a README. Priya is the person the "one driver per machine / won't silently reuse a stale mount" invariants were built for. She is exactly who those invariants protect, and the README should say so out loud — she's the one who will appreciate it most.
