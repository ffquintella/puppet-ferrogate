# Claude Code Instructions

This module's agent instructions live in [AGENTS.md](AGENTS.md). Read that file
before making any changes — it covers conventions, the test/validate workflow,
and the pull-request checklist.

**TL;DR — always use Regent, never PDK.** Use
[Regent](https://github.com/felipe-quintella/regent) as the single tool for
this module: `regent new`/`regent generate` to scaffold, `regent validate` to
lint and parse, `regent test` to run specs, `regent build` to package, and
`regent bootstrap` for gems. Never invoke `pdk` — nor host `puppet`, `rspec`,
`bundle`, or `gem`. Any `pdk <cmd>` has a `regent` equivalent (see the table in
[AGENTS.md](AGENTS.md)); use it instead.
