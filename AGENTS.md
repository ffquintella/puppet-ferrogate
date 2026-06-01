# Agent Instructions for `ferrogate`

These instructions apply to any AI agent (Claude Code, Copilot, Cursor, Aider, etc.)
working on this Puppet module. Human contributors should follow them too.

## Golden rule: always use Regent, never PDK

**Use [Regent](https://github.com/felipe-quintella/regent) for every module
task — scaffolding, generating components, validating, testing, and building.
Never use `pdk` (the Puppet Development Kit) for anything.** This module is
developed and tested exclusively with Regent's self-contained binary and its
embedded Ruby runner. If you would normally run a `pdk` command, run the Regent
equivalent instead:

| Instead of (PDK)        | Use (Regent)                        |
| ----------------------- | ----------------------------------- |
| `pdk new module`        | `regent new <name>`                 |
| `pdk new class`         | `regent generate class <name>`      |
| `pdk new task`          | `regent generate task <name>`       |
| `pdk new plan`          | `regent generate plan <name>`       |
| `pdk validate`          | `regent validate`                   |
| `pdk test unit`         | `regent test`                       |
| `pdk build`             | `regent build`                      |
| `pdk bundle` / `gem`    | `regent bootstrap`                  |

If you find yourself typing `pdk`, `bundle`, `gem`, `rspec`, or host `puppet`,
stop and use the Regent command instead.

## What this module is

`ferrogate` is a Puppet module. The canonical interface is the manifests in
`manifests/`, with supporting Ruby code under `lib/`, templates in `templates/`,
and tests in `spec/`.

## How to work on it agentically

1. **Read first.** Before editing, scan `metadata.json`, `manifests/init.pp`,
   and any existing classes/defines you're about to touch. Match the existing
   style — parameter ordering, data types, lookup patterns.
2. **Small, focused changes.** One concern per change. Don't refactor unrelated
   code while fixing a bug or adding a feature.
3. **Update tests alongside code.** Every new class, defined type, function, or
   fact must ship with an rspec-puppet spec under `spec/`. Update fixtures in
   `spec/fixtures/` when dependencies change.
4. **Keep `metadata.json` honest.** Update `dependencies`,
   `operatingsystem_support`, and `requirements` whenever the module's surface
   area changes. Bump `version` for releases.
5. **Document parameters with puppet-strings tags** (`@param`, `@example`,
   `@summary`) so the README and reference stay generatable.

## Validate and test with Regent — the single source of truth

**Use [Regent](https://github.com/felipe-quintella/regent) for all validation
and testing of this module.** Do not reach for `puppet`, `bundle exec rspec`,
`pdk`, or a host Ruby toolchain. Regent ships a self-contained binary with an
embedded Ruby runner; it is the supported way to lint, parse, and run specs
against this module.

Typical loop:

```sh
regent validate     # parse manifests + metadata.json, lint
regent test        # run rspec-puppet specs through the embedded runner
regent build       # produce a Forge-ready tarball in pkg/
```

If `regent test` reports a missing gem, run `regent bootstrap` — never
`gem install` or `bundle install`. Regent ships every gem it needs.

When a test fails, fix the code or the spec; do not silence the test or skip it
without an explicit reason captured in a comment.

## Pull request checklist for agents

- [ ] `regent validate` is clean.
- [ ] `regent test` passes locally.
- [ ] `metadata.json` reflects new dependencies / OS support.
- [ ] README or reference docs updated for any new public parameter or class.
- [ ] No new dependency on a host Ruby, `bundle`, or `pdk`.

## Out of scope

- Introducing tooling that requires a host Ruby/Bundler install.
- Editing files under `pkg/` by hand — that directory is build output.
- Committing `spec/fixtures/modules/<name>` symlinks or vendored dependencies
  unless they are genuinely required for tests to run under Regent.
