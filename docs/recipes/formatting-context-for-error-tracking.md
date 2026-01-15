# Formatting Context for Error Tracking Systems

The `context` hash passed to the global `on_exception` handler may contain complex objects (like ActiveRecord models, `ActionController::Parameters`, or `Axn::FormObject` instances) that aren't easily serialized by error tracking systems. You can format these values to make them more readable.

## Basic Example

```ruby
Axn.configure do |c|
  c.on_exception = proc do |e, action:, context:|
    formatted_context = format_hash_values(context)

    Honeybadger.notify(e, context: { axn_context: formatted_context })
  end
end

def format_hash_values(hash)
  hash.transform_values do |v|
    if v.respond_to?(:to_global_id)
      v.to_global_id.to_s
    elsif v.is_a?(ActionController::Parameters)
      v.to_unsafe_h
    elsif v.is_a?(Axn::FormObject)
      v.to_h
    else
      v
    end
  end
end
```

## What This Converts

- **ActiveRecord objects** → Their global ID string (via `to_global_id`)
- **`ActionController::Parameters`** → A plain hash
- **`Axn::FormObject` instances** → Their hash representation
- **Other values** → Remain unchanged

This ensures that your error tracking system receives serializable, readable context data instead of complex objects that may not serialize properly.

## Recursive Formatting

If your context contains nested hashes with complex objects, you may want to recursively format the entire structure:

```ruby
def format_hash_values(hash)
  hash.transform_values do |v|
    case v
    when Hash
      format_hash_values(v)
    when Array
      v.map { |item| item.is_a?(Hash) ? format_hash_values(item) : format_value(item) }
    else
      format_value(v)
    end
  end
end

def format_value(v)
  if v.respond_to?(:to_global_id)
    v.to_global_id.to_s
  elsif v.is_a?(ActionController::Parameters)
    v.to_unsafe_h
  elsif v.is_a?(Axn::FormObject)
    v.to_h
  else
    v
  end
end
```

## Advanced Example: Production Implementation

Here's a comprehensive example that includes additional context, a retry command generator, and proper handling of ActiveRecord models:

```ruby
Axn.configure do |c|
  def format_hash_values(hash)
    hash.transform_values do |v|
      if v.respond_to?(:to_global_id)
        v.to_global_id.to_s
      elsif v.is_a?(ActionController::Parameters)
        v.to_unsafe_h
      elsif v.is_a?(Axn::FormObject)
        v.to_h
      else
        v
      end
    end
  end

  # Format values for retry commands - produces copy-pasteable Ruby code
  def format_value_for_retry_command(value)
    # Handle ActiveRecord model instances
    if value.respond_to?(:to_global_id) && value.respond_to?(:id) && !value.is_a?(Class)
      begin
        model_class = value.class.name
        id = value.id
        return "#{model_class}.find(#{id.inspect})"
      rescue StandardError
        # If accessing id fails, fall through to default behavior
      end
    end

    # Handle GlobalID strings (useful for serialized values)
    if value.is_a?(String) && value.start_with?("gid://")
      begin
        gid = GlobalID.parse(value)
        if gid
          model_class = gid.model_class.name
          id = gid.model_id
          return "#{model_class}.find(#{id.inspect})"
        end
      rescue StandardError
        # If parsing fails, fall through to default behavior
      end
    end

    # Default: use inspect for other types
    value.inspect
  end

  def retry_command(action:, context:)
    action_name = action.class.name
    return nil if action_name.nil?

    expected_fields = action.internal_field_configs.map(&:field)

    return "#{action_name}.call()" if expected_fields.empty?

    args = expected_fields.map do |field|
      value = context[field]
      "#{field}: #{format_value_for_retry_command(value)}"
    end.join(", ")

    "#{action_name}.call(#{args})"
  end

  c.on_exception = proc do |e, action:, context:|
    axn_name = action.class.name || "AnonymousClass"
    message = "[#{axn_name}] Raised #{e.class.name}: #{e.message}"

    hb_context = {
      axn: axn_name,
      axn_context: format_hash_values(context),
      current_attributes: format_hash_values(Current.attributes),
      retry_command: retry_command(action:, context:),
      exception: e,
    }

    fingerprint = [axn_name, e.class.name, e.message].join(" - ")
    Honeybadger.notify(message, context: hb_context, backtrace: e.backtrace, fingerprint:)
  rescue StandardError => rep
    Rails.logger.warn "!! Axn failed to report action failure to honeybadger!\nOriginal exception: #{e}\nReporting exception: #{rep}"
  end
end
```

This example includes:

- **Formatted context**: Uses `format_hash_values` to serialize complex objects for readable error tracking
- **Smart retry commands**: Generates copy-pasteable Ruby code, converting ActiveRecord models to `Model.find(id)` calls instead of raw inspect output
- **GlobalID support**: Handles both live model instances and serialized GlobalID strings
- **Additional context**: Includes `Current.attributes` (if using a Current pattern) for request-level context
- **Error fingerprinting**: Creates a fingerprint from action name, exception class, and message to group similar errors
- **Error handling**: Wraps the Honeybadger notification in a rescue block to prevent reporting failures from masking the original exception

### Example Output

For an action like:

```ruby
class UpdateUser
  include Axn
  expects :user, model: User
  expects :name, type: String
end
```

The retry command would generate:

```ruby
UpdateUser.call(user: User.find(123), name: "Alice")
```

This can be copied directly from your error tracking system and pasted into a Rails console to reproduce the error.

