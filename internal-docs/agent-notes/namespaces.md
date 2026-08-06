# Namespaces: case studies and mechanism

This file holds mechanism and case studies only. The rule each section backs is stated in
`AGENTS.md`; if you find yourself wanting to add a new rule here instead of there, put it in
`AGENTS.md` and link back.

## `Internal::Reflection::X` membership footholds

Building and validating a schema, and rendering a result, mostly run off the execution path, but
that's not a blanket guarantee of membership: `Schema` and `PropertyNames` each keep a narrow
foothold ON it (a memoized model-field default check; a small set of runtime callers naming a field
only when reporting a failure), while `Values` has none. See `Internal::Reflection`'s own header for
exactly which callers and when.

## Why `Axn::Error` is a module, not a base class

Tagging a class with `include Axn::Error` costs it no ancestry, which is what lets an adapter gem
keep a base its own ecosystem requires — `Faraday::Error`, `Timeout::Error` — while still being
catchable as an axn error. A sibling gem roots its own hierarchy there:
`class Axn::Webhooks::Error < StandardError; include Axn::Error; end`.

`Axn::Failure` is excluded because it's a control-flow signal from `call!`, not a fault: tagging it
would make `rescue Axn::Error` catch the intended outcome while still missing an unintended
`NoMethodError` from the action body.

No public exception class inherits out of `Axn::Internal`. Where six once did, the internal base
was an ancestor and nothing else, and `rescue Axn::Error` is how "any registry lookup miss" is
expressed now.
