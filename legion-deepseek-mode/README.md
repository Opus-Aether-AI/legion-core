# legion-deepseek-mode

The DeepSeek Harness primary-mode guide for Legion. When DeepSeek Harness is
the active primary, this guide explains what stays inline and how to make a
bounded, policy-driven Legion handoff.

DeepSeek Harness is a registered `primary coding` executor, but its adapter has
important limits:

- Headless execution is `dsh --profile <name> <task>`; `dsh` has no `run`
  subcommand.
- DeepSeek Harness ships no headless preset. Author a profile that loads the
  headless application and set `LEGION_DSH_PROFILE` to its name before use.
- The executor has `review = "none"`; it cannot produce a structured review
  verdict and is excluded from the review fallback order.
- Its headless path publishes no usage contract. Reported cost and tokens are
  zero to mean **not reported**, not zero consumption.

Use `legion-delegate run --archetype <name>` to let the installed routing policy
choose a role. See [SKILL.md](./SKILL.md) for the full operating guidance.
