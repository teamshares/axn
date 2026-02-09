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

**Important**: The transaction wraps:
- `before` hooks
- The main `call` method
- `after` hooks

So the transaction is still open until all of the above complete. If any of them raise or call `fail!`, the transaction is rolled back.

**`on_success` runs after the transaction commits.** It is invoked only after the transaction block has finished successfully. Use `on_success` (not `after` hooks) for work that should run outside the transaction—for example, calling an external HTTP service—so the DB transaction can commit and release the connection before that work runs. Putting slow or unreliable external calls inside `call` or `after` keeps the transaction open until they complete and can block the connection.

**Requirements**: Requires ActiveRecord to be available in your application.
