# Axn -- [AHK-sin] (a.k.a. "Action")

Just spinning this up -- not yet publicly released, changes coming frequently.

## Installation & Usage

See our [User Guide](https://teamshares.github.io/axn/) for details.

## Using Axn with an AI agent

Axn ships a dense, agent-facing usage guide at the gem root (`AGENTS-consuming.md`) — the contract surface, the canonical idioms, and the subtle gotchas, distilled for an LLM writing code that *uses* Axn. (It's the consuming-audience sibling of this repo's own [`AGENTS.md`](AGENTS.md), which guides agents working *on* Axn.) It's version-accurate and readable offline from the installed gem.

To point your project's coding agent at it, drop a snippet like this into your `AGENTS.md` / `CLAUDE.md`:

```markdown
## Axn (service objects)

When writing or modifying Axn actions (`include Axn`), first read the in-gem agent guide:
run `bundle show axn` and read `AGENTS-consuming.md` at that path. It covers the
`expects`/`exposes`/`call` contract, how results and failures surface, and the gotchas.
```

The guide links out to the [full docs](https://teamshares.github.io/axn/) and to the source entry points for anything it doesn't cover.

If you're instead writing a gem that exposes Axns over a tool/agent transport (like `axn-mcp` or `axn-ruby_llm`), there's a companion guide for *adapter* authors: `AGENTS-tool-adapters.md` at the gem root, with a matching [Authoring a Tool-Adapter Gem](https://teamshares.github.io/axn/recipes/authoring-tool-adapters) docs page.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

## Contributions

Axn is open source and contributions from the community are encouraged! No contribution is too small.

See our [contribution guidelines](CONTRIBUTING.md) for more information.

## Thank You

A very special thank you to [Collective Idea](https://collectiveidea.com/)'s fantastic [Interactor](https://github.com/collectiveidea/interactor?tab=readme-ov-file#interactor) library, which [we](https://www.teamshares.com/) used successfully for a number of years and which we used to scaffold early versions of this library.
