# Axn RuboCop Cops

This directory contains custom RuboCop cops specifically designed for the Axn library.

## Axn/UncheckedResult

This cop enforces proper result handling when calling Axns. It can be configured to check nested calls, non-nested calls, or both.

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
  CheckNested: true      # Check nested Axn calls (default: true)
  CheckNonNested: true   # Check non-nested Axn calls (default: true)
  Severity: warning      # or error, if you want to enforce it strictly
```

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

1. **Inside an Axn class** - Classes that `include Axn`
2. **Inside the `call` method** - Only the main execution method
3. **Calling another Axn** - Using `.call` on Axn classes
4. **Properly handling the result** - One of the acceptable patterns above

### What the Cop Ignores

The cop will NOT report offenses for:

- Axn calls outside of Axn classes
- Axn calls in methods other than `call`
- Axn calls that use `call!` (bang method)
- Axn calls where the result is properly handled

### Configuration

Enable the cop in your `.rubocop.yml`:

```yaml
require:
  - ./lib/rubocop/cop/axn/unchecked_result

Axn/UncheckedResult:
  Enabled: true
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

## Axn/AmbientContextBypass

This cop flags direct reads of `Current.<attr>` / `::Current.<attr>` and steers you toward declaring the dependency explicitly with `expects :<attr>, on: :ambient_context`. It only flags reads — assignments (`Current.company = c`) and calls with arguments (`Current.foo(bar)`) are left alone, since those aren't ambient-context bypasses.

### Why This Rule Exists

Reaching into `Current` directly inside an Axn hides a real dependency: the class's `expects`/`exposes` declarations no longer describe everything it depends on, callers can't tell what ambient state is required just by reading the class, and tests have to reach for `CurrentAttributes` (or similar) to reproduce behavior instead of just passing a value.

### Usage Examples

#### ❌ Bad - Reading `Current` directly

```ruby
class ChargeCard
  include Axn

  def call = do_thing(Current.company)
end
```

#### ✅ Good - Declared via `expects ... on: :ambient_context`

```ruby
class ChargeCard
  include Axn

  expects :company, on: :ambient_context

  def call = do_thing(company)
end
```

### What the Cop Ignores

- Assignments: `Current.company = c`
- Calls with arguments: `Current.foo(bar)`
- Unrelated receivers: `Time.current`, `SomeOther.current`, etc.

### Configuration

This cop is **opt-in** — axn ships no default config that enables it. Enable it explicitly in your `.rubocop.yml`:

```yaml
require:
  - ./lib/rubocop/cop/axn/ambient_context_bypass

Axn/AmbientContextBypass:
  Enabled: true
  Severity: warning
```
