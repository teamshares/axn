---
outline: deep
---

# Inheritance & Method Conflicts

Everything on this page applies only when you `include Axn` into a class that already has a hierarchy — one that subclasses an `ApplicationService` of your own, or a transport base class from an adapter gem, or one that includes a concern before it includes Axn.

If you write the usual thing, none of it is observable:

```ruby
class ChargeCard
  include Axn
end
```

That class owns nothing axn defines, so axn defines everything, and no rule below ever fires.

## The rule

`include Axn` gives your class a handful of convenience helpers — `log`, `fail!`, `expose` and friends. Ruby places a module included into your class *above* its superclass in the method lookup order, so left alone axn's `#log` would outrank an `ApplicationService#log` you already had, and your method would quietly become unreachable.

Axn steps aside instead. **A helper name your own hierarchy already declares stays yours**: calls inside the action reach the inherited implementation, at its original visibility, and axn warns once the first time such an action runs.

"Your own hierarchy" stops at `Object`. A name Ruby declares is not yours — `Kernel` owns `warn`, `inspect`, `hash`, `then` and `tap`, and every class in Ruby inherits them, so counting those as a conflict would mean `warn("declined")` inside an action went to stderr instead of your logger. Everything from `Object` outward is Ruby's and axn keeps it; everything nearer — your superclasses, and any module they or you included *before* `include Axn` — is yours.

A `def` in the action's own class body is not a conflict either. Your method wins on its own terms, whichever side of `include Axn` you write it, and `super` from it reaches whatever stands behind it: the inherited implementation if your hierarchy has one, axn's if it does not. A module you include *after* `include Axn` behaves the same way. Neither is announced, either: the warning below is about a name whose calls actually land on an inherited implementation, and yours do not.

## Which names

These are axn's convenience helpers — the public instance methods it puts on your class for you to call from `call`:

- Flow control: `fail!`, `done!`, `forward!`
- Contract: `result`, `inputs`, `expose`, `default_error`, `default_success`, `execution_context`, `set_execution_context`, `clear_execution_context`, `ambient_context`
- Logging: `log`, `debug`, `info`, `warn`, `error`, `fatal`

Axn's private internals are not on this list — they are not a surface your base class could plausibly be standing in for — and `call`, `_run` and `initialize` are a separate case entirely; see [Names axn cannot hand over](#names-axn-cannot-hand-over).

`ambient_context` defers exactly like the rest of this list, but it is not a name a **field declaration** can ever take: `expects :ambient_context` raises naming `Axn::Core::AmbientContext` as the owner, because that name is a sentinel the subfield resolver compares against, not a convenience. Those are different questions — deferring an inherited *method* costs axn nothing, since internals reach the ambient reader by binding it rather than by dispatching its name, while a *field* of that name would be answered by the ambient branch instead of the declared value. So don't declare a field called `ambient_context`, but a method of that name on your own hierarchy is deferred to, warned about, and confirmable/overridable with `prefer_inherited`/`prefer_axn` like any other helper here.

## A worked example

Say you already have a service base that tags its log lines with a request id:

```ruby
class ApplicationService
  def log(msg) = Rails.logger.info("[#{Current.request_id}] #{msg}")
end

class ChargeCard < ApplicationService
  include Axn

  expects :amount

  def call
    log("charging #{amount}")
    charge!
  end
end
```

`log("charging 100")` reaches `ApplicationService#log`, not axn's logger. The first time any action under that base runs, axn says so once:

```
[ChargeCard] axn left #log to ApplicationService: it already defines the name, so calls reach
ApplicationService's version. Declare `prefer_inherited :log` to confirm that, or
`prefer_axn :log` to use axn's instead.
```

Two things about that line are worth knowing. It fires the first time an action **runs**, not when the class is loaded — an action nobody ever calls never announces anything. And it is keyed to the method it deferred to, so one `ApplicationService#log` inherited by fifty actions produces one line rather than fifty.

## Confirming the deferral: `prefer_inherited`

Add `prefer_inherited :log` to say the deferral is what you wanted. On a class where axn stepped aside it changes no behavior — the inherited implementation was already the one running — and it silences the warning for that name on that class:

```ruby
class ChargeCard < ApplicationService
  include Axn

  prefer_inherited :log

  def call = log("charging")
end
```

Because the warning waits for the first run rather than firing during `include Axn`, a declaration written anywhere in the class body is in time to silence it. The one thing you cannot do is silence it retroactively: reopening a class to add `prefer_inherited` after it has already executed changes nothing, since the line is already written.

`prefer_inherited` raises rather than passing silently when the deferral it names did not happen — a base class that no longer defines the method, say:

```
`prefer_inherited :log` has nothing to prefer: axn surrendered no #log on ChargeCard, because
nothing above it declared the name when `include Axn` ran. …
```

A misspelled name is a different error: `prefer_inherited :logg` raises `UnpreferableName` (`#logg is not part of axn's public instance surface`), because `logg` is not one of the names axn hands over in the first place.

It is not a pure annotation in every position, either. Declared on a subclass of a class that said `prefer_axn :log`, it takes the name back for the subclass — the inherited implementation runs there while the parent and its other subclasses keep axn's.

## Taking the name back: `prefer_axn`

If your hierarchy owns a name but this action wants axn's version of it, declare `prefer_axn`:

```ruby
class ApplicationService
  def fail!(msg) = raise(ServiceError, msg)
end

class ChargeCard < ApplicationService
  include Axn

  prefer_axn :fail!

  def call = fail!("declined")
end
```

Without the declaration, `fail!("declined")` reaches `ApplicationService#fail!` and the action settles as an **exception** with a generic error message. With it, `fail!` is axn's again and the action settles as a **failure** with `result.error == "declined"`.

This is the only route back to axn's implementation once a parent owns the name. Writing `def fail!(msg) = super` in the class body does not get you there — `super` reaches the inherited implementation, which is the thing you were trying to get past.

Both declarations refuse a name axn does not hand to anyone, rather than accepting it and doing nothing: `prefer_axn :call`, or either declaration naming an axn internal or a method of Ruby's, raises where it is written.

Both declarations are scoped to the class that writes them. `prefer_axn` on a subclass leaves the base class that recorded the deferral, and every sibling under it, running the inherited implementation.

One consequence to know about, since you would otherwise meet it by accident: a `def` of the same name in the class body still wins over `prefer_axn`. The declaration does not become a no-op, though — it redirects that method's `super`:

```ruby
class ChargeCard < ApplicationService
  include Axn

  def fail!(msg) = super("wrapped: #{msg}")
  prefer_axn :fail!

  def call = fail!("declined")
end
# => outcome: failure, error: "wrapped: declined"
```

Your `def` is what answers `fail!`, and `super` from it now reaches **axn's** implementation rather than `ApplicationService`'s. Drop the `prefer_axn` line and the same class settles as an exception instead.

## Names axn cannot hand over

`call`, `_run` and `initialize` are not helpers. Axn dispatches those names on the action itself to run it, so it cannot step aside for an inherited one — the inherited method would simply never be called, and the action would report success for code that did not execute.

Rather than let that happen silently, axn refuses. The check runs at `.call` rather than at load, because only the finished class can answer it, and it raises `Axn::ContractViolation::UnsurrenderableInheritedMethod`. It runs on every call, not just the first: reopen a superclass to add one of those three names and the actions beneath it start refusing from that point on, which is the same answer they would have given had the method been there all along. Unlike an exception raised inside an action, which axn settles into a result, this one propagates out to the caller — there is no action for it to settle into yet — and it does so from `.call` and `.call!` alike:

```ruby
class ServiceBase
  def call = do_the_work
end

class ChargeCard < ServiceBase
  include Axn
end

ChargeCard.call
```

```
ServiceBase defines #call, which ChargeCard cannot inherit: axn must own that name to run the
action, so the inherited definition would never be called. Either move that behaviour into
ChargeCard's own #call (`super` from there reaches axn's default, not ServiceBase's), or, to
keep ServiceBase's #call running, compose ServiceBase in rather than inheriting from it.
```

The two fixes are genuinely different, so pick deliberately:

- **Define the name on the action.** `def call` in `ChargeCard` is the action's body, and axn is satisfied — but note that a bare `super` from there reaches axn's own default, *not* `ServiceBase#call`. This branch replaces the inherited behavior.
- **Compose instead of inherit.** Drop the superclass and call the old object from inside `call` (`ServiceBase.new(...).call`). This branch keeps the inherited behavior running.

The same applies to an inherited `initialize`: axn constructs the action itself, so a parent initializer would never run and its state would never be set. `Axn::Factory.build(..., superclass: SomeBase)` is bound by the identical rule — the factory defines `call` on the class it builds, so a superclass owning `call` is fine, but one owning `initialize` raises.

Actions axn builds for [mounting](/advanced/mountable) are the exception. `mount_axn` and `mount_axn_method` choose the superclass themselves — that is what `inherit:` selects, so the mounted action carries the target's hooks, callbacks and async config — and neither fix above is available on a class you did not write. So a target that defines `initialize` is not refused there. A mount that passes its own `superclass:` is refused like any other, since that inheritance is yours.

## The class-method side

The same principle applies one receiver over, for the class-method DSL `include Axn` extends onto your class — `description`, `input_schema` and `output_schema`.

Those are generic names, and a base class from a tool-adapter gem is likely to already give them transport meaning of its own — an `input_schema` that describes the wire format the transport expects. Where the class or its singleton ancestry already defines one, axn leaves it alone rather than extending its own over the top:

```ruby
class MyTool < TransportBase   # defines `self.input_schema`
  include Axn
end

MyTool.input_schema    # => TransportBase's, untouched
MyTool.output_schema   # => axn's, since TransportBase does not define it
```

The deferral is per name, and there is no annotation and no warning on this side: an adapter base owning these names is the expected arrangement rather than a collision to resolve.

## Field declarations follow the same rule

The names your hierarchy owns are off limits to field declarations too, since a field's reader is defined on the action itself and would take the name over. `expects :log` on a class under `ApplicationService` raises at declaration, naming the class the name belongs to:

```
Cannot declare a reader named `log`: that name belongs to ApplicationService (not axn's to
surrender). A field's reader is defined on the action itself, so declaring it would take the
name over. Rename the field, or keep the wire key and rename only the reader, with `as:`
(or `prefix:`).
```
