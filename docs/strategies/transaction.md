# Transaction Strategy

The `transaction` strategy wraps your action execution in a database transaction:

```ruby
class TransferFunds
  include Axn

  use :transaction # [!code focus]

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

**`on_success` runs after the enclosing transaction commits.** It is the place for work that must only happen once the DB work is durably persisted—calling an external HTTP service, sending email, enqueuing a job. This holds under nesting too: when an action runs inside another action's transaction (or any open `ActiveRecord::Base.transaction`), its `on_success` is deferred until the **outermost** transaction commits, and is **skipped entirely if that transaction rolls back**. With no open transaction it runs immediately.

Ordering follows from this: nested `on_success` callbacks fire in child-first order (inner before outer). One consequence to be aware of—because `on_success` waits for the commit, an outer action's `after` hooks (which run *inside* the transaction) execute **before** an inner action's `on_success`.

Putting slow or unreliable external calls inside `call` or `after` keeps the transaction open until they complete and can block the connection—use `on_success` instead.

> **Non-joinable transactions:** deferral keys off `ActiveRecord.after_all_transactions_commit`, which by design only tracks **joinable** transactions (the default). An action run *directly* inside an explicitly non-joinable transaction (`ActiveRecord::Base.transaction(joinable: false)`, with no ordinary transaction between it and the action) is treated as if no transaction were open—its `on_success` runs immediately. The `transaction` strategy and ordinary `ActiveRecord::Base.transaction` blocks are joinable, so nested actions are unaffected. (This is also why `on_success` fires normally under Rails' transactional test fixtures, whose outer transaction is non-joinable—the callback runs immediately rather than being suppressed by the fixture rollback.)

**Requirements**: Requires ActiveRecord to be available in your application.
