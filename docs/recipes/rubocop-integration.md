# RuboCop Integration

Axn provides a custom RuboCop cop to help enforce proper result handling when calling Actions.

## What It Does

The `Axn/UncheckedResult` cop detects when you call another Action from within an Action but don't properly handle the result. This helps prevent silent failures and ensures consistent error handling patterns.

> **⚠️ Warning**: This cop uses static analysis and cannot distinguish between actual Axn classes and other classes that happen to have a `call` method. If you're using legacy services or other service patterns alongside Axn, you may encounter false positives. Use RuboCop disable comments for intentional violations.
>
> **💡 Tip**: If you're using the Actions namespace (see [Rails Integration](/docs/usage/setup.md#rails-integration-optional)), you can configure the cop to only check `Actions::*` classes, eliminating false positives from other service objects.

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

For detailed configuration options, usage patterns, and troubleshooting, see the [technical documentation](/lib/rubocop/cop/axn/README.md).
