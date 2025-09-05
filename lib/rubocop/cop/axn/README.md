# Axn RuboCop Cops

This directory contains custom RuboCop cops specifically designed for the Axn library.

## Axn/UncheckedResult

This cop enforces proper result handling when calling Axns. It can be configured to check nested calls, non-nested calls, or both.

**Important**: The cop only applies to files in configured target directories to avoid false positives on standard library classes and other non-action classes that happen to have `call` methods.

### Why This Rule Exists

When Axns are nested, proper error handling becomes crucial. Without proper result checking, failures in nested Axns can be silently ignored, leading to:

- Silent failures that are hard to debug
- Inconsistent error handling patterns
- Potential data corruption or unexpected behavior

### Configuration Options

The cop supports flexible configuration to match your team's needs:

```yaml
Axn/UncheckedResult:
  Enabled: true
  TargetDirectories:     # Directories to check (default shown)
    - app/actions
    - app/services
    - lib/actions
    - lib/services
  CheckNested: true      # Check nested Axn calls (default: true)
  CheckNonNested: true   # Check non-nested Axn calls (default: true)
  Severity: warning      # or error, if you want to enforce it strictly
```

#### TargetDirectories

Controls which directories the cop will analyze. The cop only applies to files within these directories to avoid false positives on standard library classes and other non-action classes.

#### Configuration Modes

1. **Full Enforcement** (default):
   ```yaml
   CheckNested: true
   CheckNonNested: true
   ```
   Checks all Axn calls regardless of nesting.

2. **Nested Only**:
   ```yaml
   CheckNested: true
   CheckNonNested: false
   ```
   Only checks Axn calls from within other Axns.

3. **Non-Nested Only**:
   ```yaml
   CheckNested: false
   CheckNonNested: true
   ```
   Only checks top-level Axn calls.

4. **Disabled**:
   ```yaml
   CheckNested: false
   CheckNonNested: false
   ```
   Effectively disables the cop.

### Usage Examples

#### ❌ Bad - Missing Result Check

```ruby
class OuterAction
  include Axn
  def call
    InnerAction.call(param: "value")  # Missing result check
    # This will always continue even if InnerAction fails
  end
end
```

#### ✅ Good - Using call!

```ruby
class OuterAction
  include Axn
  def call
    InnerAction.call!(param: "value")  # Using call! ensures exceptions bubble up
  end
end
```

#### ✅ Good - Checking result.ok?

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

#### ✅ Good - Checking result.failed?

```ruby
class OuterAction
  include Axn
  def call
    result = InnerAction.call(param: "value")
    if result.failed?
      return result
    end
    # Process successful result...
  end
end
```

#### ✅ Good - Accessing result.error

```ruby
class OuterAction
  include Axn
  def call
    result = InnerAction.call(param: "value")
    if result.error
      return result
    end
    # Process successful result...
  end
end
```

#### ✅ Good - Returning the result

```ruby
class OuterAction
  include Axn
  def call
    result = InnerAction.call(param: "value")
    result  # Result is returned, so it's properly handled
  end
end
```

#### ✅ Good - Using result in expose

```ruby
class OuterAction
  include Axn
  exposes :nested_result
  def call
    result = InnerAction.call(param: "value")
    expose nested_result: result  # Result is used, so it's properly handled
  end
end
```

#### ✅ Good - Passing result to another method

```ruby
class OuterAction
  include Axn
  def call
    result = InnerAction.call(param: "value")
    process_result(result)  # Result is used, so it's properly handled
  end
end
```

### What the Cop Checks

The cop analyzes your code to determine if you're:

1. **In a target directory** - File is within one of the configured `TargetDirectories`
2. **Inside an Axn class** - Classes that `include Axn`
3. **Inside the `call` method** - Only the main execution method
4. **Calling another Axn** - Using `.call` on Axn classes
5. **Properly handling the result** - One of the acceptable patterns above

### What the Cop Ignores

The cop will NOT report offenses for:

- Files outside of target directories (prevents false positives on standard library classes)
- Axn calls outside of Axn classes
- Axn calls in methods other than `call`
- Axn calls that use `call!` (bang method)
- Axn calls where the result is properly handled

### Configuration

Enable the cop in your `.rubocop.yml`:

```yaml
require:
  - axn/rubocop

Axn/UncheckedResult:
  Enabled: true
  TargetDirectories:
    - app/actions
    - app/services
    - lib/actions
    - lib/services
  CheckNested: true      # Check nested Axn calls
  CheckNonNested: true   # Check non-nested Axn calls
  Severity: warning      # or error, if you want to enforce it strictly
```

### Best Practices

1. **Prefer `call!` for simple cases** where you want exceptions to bubble up
2. **Use result checking for complex logic** where you need to handle different failure modes
3. **Always handle results explicitly** - don't let them be silently ignored
4. **Return results early** when they indicate failure
5. **Use meaningful variable names** for results to make your code more readable

### Common Patterns

#### Early Return Pattern
```ruby
def call
  result = InnerAction.call(param: "value")
  return result unless result.ok?

  # Continue with successful result...
end
```

#### Conditional Processing Pattern
```ruby
def call
  result = InnerAction.call(param: "value")

  if result.ok?
    process_success(result)
  else
    handle_failure(result)
  end
end
```

#### Pass-Through Pattern
```ruby
def call
  result = InnerAction.call(param: "value")
  # Pass the result through to the caller
  result
end
```
