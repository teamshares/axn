# Client Strategy

The `client` strategy provides a declarative way to configure HTTP clients for API integrations. It creates a memoized Faraday connection with sensible defaults and optional error handling.

::: warning Peer Dependency
This strategy requires the `faraday` gem to be available. It is only registered when Faraday is loaded.
:::

## Basic Usage

```ruby
class FetchUserData
  include Axn

  use :client, url: "https://api.example.com"

  expects :user_id
  exposes :user_data

  def call
    response = client.get("/users/#{user_id}")
    expose user_data: response.body
  end
end
```

## Configuration Options

| Option | Default | Description |
| ------ | ------- | ----------- |
| `name` | `:client` | The method name for accessing the client |
| `url` | (required) | Base URL for the API |
| `headers` | `{}` | Default headers to include in all requests |
| `user_agent` | Auto-generated | Custom User-Agent header |
| `debug` | `false` | Enable Faraday response logging |
| `prepend_config` | `nil` | Proc to prepend middleware configuration |
| `error_handler` | `nil` | Error handling configuration (see below) |

Any additional options are passed directly to `Faraday.new`.

## Default Middleware

The client strategy automatically configures these middleware:

1. `Content-Type: application/json` header
2. `User-Agent` header (configurable)
3. `response :raise_error` - Raises on 4xx/5xx responses
4. `request :url_encoded` - Encodes request parameters
5. `request :json` - JSON request encoding
6. `response :json` - JSON response parsing

## Custom Client Name

```ruby
class ExternalApiAction
  include Axn

  use :client, name: :api_client, url: "https://api.example.com"
  use :client, name: :auth_client, url: "https://auth.example.com"

  def call
    token = auth_client.post("/token").body["access_token"]
    data = api_client.get("/data", nil, { "Authorization" => "Bearer #{token}" })
    # ...
  end
end
```

## Dynamic Configuration

Options can be callables (procs/lambdas) for dynamic values:

```ruby
class SecureApiAction
  include Axn

  use :client,
    url: "https://api.example.com",
    headers: -> { { "Authorization" => "Bearer #{current_token}" } }

  private

  def current_token
    # Fetch or refresh token as needed
    TokenStore.get_valid_token
  end
end
```

## Custom Headers

```ruby
class ApiAction
  include Axn

  use :client,
    url: "https://api.example.com",
    headers: {
      "X-API-Key" => ENV["API_KEY"],
      "Accept" => "application/json"
    }
end
```

## Error Handling

The `error_handler` option configures custom error handling middleware:

```ruby
class ApiAction
  include Axn

  use :client,
    url: "https://api.example.com",
    error_handler: {
      if: -> { status != 200 },           # Condition to trigger error handling
      error_key: "error.message",          # JSON path to error message
      detail_key: "error.details",         # JSON path to error details (optional)
      backtrace_key: "error.backtrace",    # JSON path to backtrace (optional)
      exception_class: CustomApiError,     # Exception class to raise (default: Faraday::BadRequestError)
      formatter: ->(error, details, env) { # Custom message formatter (optional)
        "API Error: #{error} - #{details}"
      },
      extract_detail: ->(key, value) {     # Extract detail from hash/array (optional)
        "#{key}: #{value}"
      }
    }
end
```

### Error Handler Options

| Option | Description |
| ------ | ----------- |
| `if` | Condition proc to trigger error handling (receives `status`, `body`, `response_env`) |
| `error_key` | Dot-notation path to error message in response JSON |
| `detail_key` | Dot-notation path to error details |
| `backtrace_key` | Dot-notation path to backtrace |
| `exception_class` | Exception class to raise (default: `Faraday::BadRequestError`) |
| `formatter` | Custom proc to format the error message |
| `extract_detail` | Proc to extract details from nested structures |

## Prepending Middleware

Use `prepend_config` when you need to add middleware before the default stack:

```ruby
class ApiAction
  include Axn

  use :client,
    url: "https://api.example.com",
    prepend_config: ->(conn) {
      conn.request :retry, max: 3, interval: 0.5
      conn.request :authorization, "Bearer", -> { fetch_token }
    }
end
```

## Complete Example

```ruby
class SyncExternalData
  include Axn

  use :client,
    name: :external_api,
    url: ENV["EXTERNAL_API_URL"],
    headers: -> { { "Authorization" => "Bearer #{api_token}" } },
    user_agent: "MyApp/1.0",
    error_handler: {
      error_key: "error.message",
      detail_key: "error.details",
      extract_detail: ->(node) { node["field"] ? "#{node['field']}: #{node['message']}" : node["message"] }
    }

  expects :company, model: Company
  exposes :synced_records

  error "Failed to sync external data"
  error from: Faraday::BadRequestError do |e|
    "External API error: #{e.message}"
  end

  def call
    response = external_api.get("/companies/#{company.external_id}/data")
    records = response.body["records"].map do |record|
      company.external_records.find_or_create_by!(external_id: record["id"]) do |r|
        r.data = record
      end
    end
    expose synced_records: records
  end

  private

  def api_token
    Rails.cache.fetch("external_api_token", expires_in: 1.hour) do
      # Token refresh logic
    end
  end
end
```

## Memoization

The client is automatically memoized using `memo`, so repeated calls to the client method return the same Faraday connection instance. This ensures efficient connection reuse within a single action execution.

## See Also

- [Strategies Overview](/strategies/index) - How to use and create strategies
- [Memoization](/recipes/memoization) - How memoization works in Axn
