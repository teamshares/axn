# Transaction Strategy

The `transaction` strategy wraps your action execution in a database transaction:

```ruby
class TransferFunds
  include Axn

  use :transaction

  expects :from_account, :to_account, :amount

  def call
    from_account.withdraw!(amount)
    to_account.deposit!(amount)
    expose :transfer_id, SecureRandom.uuid
  end
end
```

**Important**: The transaction wraps the entire action execution, including:
- `before` hooks
- The main `call` method
- `after` hooks
- Success/failure callbacks (`on_success`, `on_failure`, etc.)

This means that if any part of the action (including hooks or callbacks) raises an exception or calls `fail!`, the entire transaction will be rolled back.

**Requirements**: Requires ActiveRecord to be available in your application.
