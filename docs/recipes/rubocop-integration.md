# RuboCop Integration

Axn provides a custom RuboCop cop to help enforce proper result handling when calling Actions.

## What It Does

The `Axn/UncheckedResult` cop detects when you call another Action from within an Action but don't properly handle the result. This helps prevent silent failures and ensures consistent error handling patterns.

> **⚠️ Warning**: This cop uses static analysis and cannot distinguish between actual Axn classes and other classes that happen to have a `call` method. If you're using legacy services or other service patterns alongside Axn, you may encounter false positives. Use RuboCop disable comments for intentional violations.
>
> **💡 Tip**: If you're using the Actions namespace (see [Rails Integration](/usage/setup#rails-integration-optional)), you can configure the cop to only check `Actions::*` classes, eliminating false positives from other service objects.

## Setup

### 1. Add to Your .rubocop.yml

```yaml
require:
  - axn/rubocop

Axn/UncheckedResult:
  Enabled: true
  Severity: warning
```

### 2. Verify Installation

```bash
bundle exec rubocop --show-cops | grep Axn
```

You should see `Axn/UncheckedResult` in the output.

## Basic Usage

### ✅ Good - Using call!

```ruby
class OuterAction
  include Axn
  def call
    InnerAction.call!(param: "value")  # Exceptions bubble up
  end
end
```

### ✅ Good - Checking the result

```ruby
class OuterAction
  include Axn
  def call
    result = InnerAction.call(param: "value")
    return result unless result.ok?
    # Process successful result...
  end
end
```

### ❌ Bad - Ignoring the result

```ruby
class OuterAction
  include Axn
  def call
    InnerAction.call(param: "value")  # Will trigger offense
    # This continues even if InnerAction fails
  end
end
```

## Configuration

The cop supports flexible configuration:

```yaml
Axn/UncheckedResult:
  Enabled: true
  CheckNested: true      # Check nested Axn calls (default: true)
  CheckNonNested: true   # Check non-nested Axn calls (default: true)
  ActionsNamespace: "Actions"  # Only check Actions::* classes (optional)
  Severity: warning      # or error
```

### ActionsNamespace Configuration

When using the Actions namespace, you can configure the cop to only check calls on `Actions::*` classes:

```yaml
Axn/UncheckedResult:
  ActionsNamespace: "Actions"
```

This eliminates false positives from other service objects while still catching unchecked Axn action calls:

```ruby
class OuterAction
  include Axn
  def call
    SomeService.call(param: "value")        # Won't trigger cop
    Actions::InnerAction.call(param: "value")  # Will trigger cop
  end
end
```

For detailed configuration options, usage patterns, and troubleshooting, see the [technical documentation](https://github.com/teamshares/axn/blob/main/lib/rubocop/cop/axn/README.md).

## Axn/AmbientContextBypass

A second, **opt-in** cop that flags reading `Current.<attr>` / `::Current.<attr>` directly inside an Axn and steers you toward declaring the dependency explicitly with [`expects :<attr>, on: :ambient_context`](/reference/class#ambient-context-on-ambient-context). Reaching into `Current` inside an action hides a real dependency — the class's `expects` declarations no longer describe everything it needs, callers can't tell what ambient state is required, and tests have to set up `CurrentAttributes` instead of just passing a value.

```ruby
# ❌ bad — the dependency on the current company is invisible in the contract
class ChargeCard
  include Axn
  def call = do_thing(Current.company)
end

# ✅ good — declared, validated, sensitive-filtered, and trivially testable
class ChargeCard
  include Axn
  expects :company, on: :ambient_context
  def call = do_thing(company)
end
```

It fires **only** on reads inside a class/module that `include Axn` (the `on: :ambient_context` fix exists nowhere else, so a `Current` read in a controller, model, or plain job is left alone). Assignments (`Current.company = c`), calls with arguments (`Current.foo(bar)`), and unrelated receivers (`Time.current`) are ignored, as are the `CurrentAttributes` lifecycle methods (`reset`, `instance`, …).

Axn ships no default config that enables it, so turn it on explicitly:

```yaml
require:
  - axn/rubocop

Axn/AmbientContextBypass:
  Enabled: true
  Severity: warning
```
