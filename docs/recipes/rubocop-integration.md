# RuboCop Integration

Axn provides custom RuboCop cops to help enforce best practices and maintain code quality in your Action-based codebase.

## Overview

The `Axn/UncheckedResult` cop enforces proper result handling when calling Actions. It can detect when Action results are ignored and help ensure consistent error handling patterns.

## Installation

### 1. Add to Your .rubocop.yml

```yaml
require:
  - axn/rubocop

# Enable Axn's custom cop
Axn/UncheckedResult:
  Enabled: true
  CheckNested: true      # Check nested Action calls
  CheckNonNested: true   # Check non-nested Action calls
  Severity: warning      # or error
```

### 2. Verify Installation

Run RuboCop to ensure the cop is loaded:

```bash
bundle exec rubocop --show-cops | grep Axn
```

You should see:
```
Axn/UncheckedResult
```

## Configuration Options

### CheckNested

Controls whether the cop checks Action calls that are inside other Action classes.

```yaml
Axn/UncheckedResult:
  CheckNested: true   # Check nested calls (default)
  CheckNested: false  # Skip nested calls
```

**When to use `CheckNested: false`:**
- You're gradually adopting the rule and want to focus on top-level calls first
- Your team has different standards for nested vs. non-nested calls
- You're using a different pattern for nested Action handling

### CheckNonNested

Controls whether the cop checks Action calls that are outside Action classes.

```yaml
Axn/UncheckedResult:
  CheckNonNested: true   # Check non-nested calls (default)
  CheckNonNested: false  # Skip non-nested calls
```

**When to use `CheckNonNested: false`:**
- You're only concerned about nested Action calls
- Top-level Action calls are handled by other tools or processes
- You want to focus on the most critical use case first

### Severity

Controls how violations are reported.

```yaml
Axn/UncheckedResult:
  Severity: warning  # Show as warnings (default)
  Severity: error    # Show as errors (fails CI)
```

## Common Configuration Patterns

### Full Enforcement (Recommended for New Projects)

```yaml
Axn/UncheckedResult:
  Enabled: true
  CheckNested: true
  CheckNonNested: true
  Severity: error
```

### Gradual Adoption (Recommended for Existing Projects)

```yaml
Axn/UncheckedResult:
  Enabled: true
  CheckNested: true      # Start with nested calls
  CheckNonNested: false  # Add this later
  Severity: warning      # Start with warnings
```

### Nested-Only Focus

```yaml
Axn/UncheckedResult:
  Enabled: true
  CheckNested: true
  CheckNonNested: false
  Severity: warning
```

## What the Cop Checks

The cop analyzes your code to determine if you're:

1. **Inside an Action class** - Classes that `include Action`
2. **Inside the `call` method** - Only the main execution method
3. **Calling another Action** - Using `.call` on Action classes
4. **Properly handling the result** - One of the acceptable patterns

## What the Cop Ignores

The cop will NOT report offenses for:

- Action calls outside of Action classes (if `CheckNonNested: false`)
- Action calls in methods other than `call`
- Action calls that use `call!` (bang method)
- Action calls where the result is properly handled

## Proper Result Handling Patterns

### ✅ Using call!

```ruby
class OuterAction
  include Action
  def call
    InnerAction.call!(param: "value")  # Exceptions bubble up
  end
end
```

### ✅ Checking result.ok?

```ruby
class OuterAction
  include Action
  def call
    result = InnerAction.call(param: "value")
    return result unless result.ok?
    # Process successful result...
  end
end
```

### ✅ Checking result.failed?

```ruby
class OuterAction
  include Action
  def call
    result = InnerAction.call(param: "value")
    if result.failed?
      return result
    end
    # Process successful result...
  end
end
```

### ✅ Accessing result.error

```ruby
class OuterAction
  include Action
  def call
    result = InnerAction.call(param: "value")
    if result.error
      return result
    end
    # Process successful result...
  end
end
```

### ✅ Returning the result

```ruby
class OuterAction
  include Action
  def call
    result = InnerAction.call(param: "value")
    result  # Result is returned, so it's properly handled
  end
end
```

### ✅ Using result in expose

```ruby
class OuterAction
  include Action
  exposes :nested_result
  def call
    result = InnerAction.call(param: "value")
    expose nested_result: result  # Result is used, so it's properly handled
  end
end
```

### ✅ Passing result to another method

```ruby
class OuterAction
  include Action
  def call
    result = InnerAction.call(param: "value")
    process_result(result)  # Result is used, so it's properly handled
  end
end
```

## Common Anti-Patterns

### ❌ Ignoring the result

```ruby
class OuterAction
  include Action
  def call
    InnerAction.call(param: "value")  # Result ignored - will trigger offense
    # This continues even if InnerAction fails
  end
end
```

### ❌ Assigning but not using

```ruby
class OuterAction
  include Action
  def call
    result = InnerAction.call(param: "value")  # Assigned but never used
    # Will trigger offense unless result is properly handled
  end
end
```

### ❌ Using unrelated attributes

```ruby
class OuterAction
  include Action
  def call
    result = InnerAction.call(param: "value")
    some_other_method(result.some_other_attribute)  # Not checking success/failure
    # Will trigger offense - need to check result.ok? first
  end
end
```

## Migration Strategies

### For New Projects

1. Enable the cop with full enforcement from the start
2. Use `Severity: error` to catch violations early
3. Train your team on the proper patterns

### For Existing Projects

1. **Phase 1**: Enable with `CheckNested: true, CheckNonNested: false, Severity: warning`
2. **Phase 2**: Fix all nested Action violations
3. **Phase 3**: Enable `CheckNonNested: true`
4. **Phase 4**: Fix all non-nested Action violations
5. **Phase 5**: Set `Severity: error`

### Using RuboCop Disable Comments

For intentional violations, you can disable the cop:

```ruby
class OuterAction
  include Action
  def call
    # rubocop:disable Axn/UncheckedResult
    InnerAction.call(param: "value")  # Intentionally ignored
    # rubocop:enable Axn/UncheckedResult
  end
end
```

## Troubleshooting

### Cop Not Loading

If you see "uninitialized constant" errors:

1. Ensure the gem is properly installed: `bundle list | grep axn`
2. Check your `.rubocop.yml` syntax
3. Verify the require path: `require: - axn/rubocop`

### False Positives

If the cop reports violations for properly handled results:

1. Check that you're using the exact patterns shown above
2. Ensure the result variable name matches exactly
3. Verify the result is being used in an acceptable way

### Performance Issues

The cop analyzes AST nodes, so it's generally fast. If you experience slowdowns:

1. Ensure you're not running RuboCop on very large files
2. Consider using RuboCop's `--parallel` option
3. Use `.rubocop_todo.yml` for gradual adoption

## Best Practices

1. **Start Small**: Begin with warnings and nested calls only
2. **Be Consistent**: Choose one pattern and stick with it
3. **Train Your Team**: Make sure everyone understands the rules
4. **Review Regularly**: Use the cop in your CI/CD pipeline
5. **Document Exceptions**: Use disable comments sparingly and document why

## Integration with CI/CD

Add RuboCop to your CI pipeline to catch violations early:

```yaml
# .github/workflows/rubocop.yml
name: RuboCop
on: [push, pull_request]
jobs:
  rubocop:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.2
      - run: bundle install
      - run: bundle exec rubocop
```

## Related Resources

- [Action Result Reference](/reference/action-result)
- [Configuration Guide](/reference/configuration)
- [Testing Recipes](/recipes/testing)
- [Best Practices Guide](/advanced/conventions)
