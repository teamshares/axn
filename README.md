# Axn -- [AHK-sin] (a.k.a. "Action")

Just spinning this up -- not yet released (i.e. doc updates in flight).

## Installation & Usage

See our [User Guide](https://teamshares.github.io/axn/) for details.

## [!!] Inheritance Support

Out of the box Axn only supports a direct style (every action must `include Action`).

If you want to support inheritance, you'll need to add this line to your `Gemfile` (we're layered over Interactor, and their released version doesn't yet support inheritance):

    gem "interactor", github: "kaspermeyer/interactor", branch: "fix-hook-inheritance"


## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

## Contributions

Axn is open source and contributions from the community are encouraged! No contribution is too small.

See our [contribution guidelines](CONTRIBUTING.md) for more information.

## Thank You

A very special thank you to [Collective Idea](https://collectiveidea.com/)'s fantastic [Interactor](https://github.com/collectiveidea/interactor?tab=readme-ov-file#interactor) library, which [we](https://www.teamshares.com/) used successfully for a number of years and which still forms the basis of this library today.
