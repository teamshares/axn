# Form Strategy

The `form` strategy provides a declarative way to validate user input using form objects. It bridges the gap between raw user input (like `params`) and validated, structured data.

::: tip When to Use
Use the form strategy when you need to validate **user-facing input** with user-friendly error messages. This is different from `expects` validations, which validate the **developer contract** (how the action is called).
:::

## Basic Usage

```ruby
class CreateUser
  include Axn

  use :form, type: CreateUser::Form

  def call
    # form is automatically validated and exposed
    # If validation fails, the action fails with form.errors
    User.create!(form.to_h)
  end
end

class CreateUser::Form < Axn::FormObject
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true, length: { minimum: 2 }
end
```

## Configuration Options

The form strategy accepts several configuration options:

| Option | Default | Description |
| ------ | ------- | ----------- |
| `type` | Auto-detected | The form class to use (see [Type Resolution](#type-resolution)) |
| `expect` | `:params` | The input field name to read from |
| `expose` | `:form` | The field name to expose the form object as |
| `inject` | `nil` | Additional context fields to inject into the form |

### Type Resolution

The `type` option determines which form class to use:

1. **Explicit class**: `use :form, type: MyFormClass`
2. **String constant path**: `use :form, type: "CreateUser::Form"`
3. **Auto-detected**: If not specified, inferred from action name + expose name (e.g., `CreateUser` + `:form` → `CreateUser::Form`)

```ruby
# Explicit type
use :form, type: RegistrationForm

# String constant (useful for avoiding load order issues)
use :form, type: "Users::RegistrationForm"

# Auto-detected from action name
class CreateUser
  include Axn
  use :form  # Uses CreateUser::Form
end
```

### Inline Form Definition

You can pass the form in directly as a block instead of a separate class.

**Block only** — the form class is not assigned to a constant, but it is given a `name` (default: the action’s name + `Form`, e.g. `"CreateUser::Form"`) so it shows up clearly in logging and exception reporting:

```ruby
class CreateUser
  include Axn

  use :form do
    validates :email, presence: true
    validates :name, presence: true
  end

  def call
    User.create!(form.to_h)
  end
end
```

**Block + type string** — the form class is named using the given string (e.g. `"CreateUser::Form"`). If that constant doesn't exist yet, the block defines the class and we assign it to that name:

```ruby
use :form, type: "CreateUser::Form" do
  validates :email, presence: true
  validates :name, presence: true
end
```

### Custom Field Names

```ruby
class ProcessOrder
  include Axn

  # Read from :order_params, expose as :order_form
  use :form, expect: :order_params, expose: :order_form, type: OrderForm

  def call
    # Access via order_form instead of form
    Order.create!(order_form.to_h)
  end
end
```

### Injecting Context

Use `inject` to pass additional context fields to the form:

```ruby
class UpdateProfile
  include Axn

  expects :user, model: User
  use :form, type: ProfileForm, inject: [:user]

  def call
    user.update!(form.to_h)
  end
end

class ProfileForm < Axn::FormObject
  attr_accessor :user  # Injected from action context

  validates :email, presence: true
  validate :email_unique_for_other_users

  private

  def email_unique_for_other_users
    return if user.nil?
    return unless User.where.not(id: user.id).exists?(email: email)

    errors.add(:email, "is already taken")
  end
end
```

## How It Works

When you use the form strategy, the following happens automatically:

1. **Expects params**: Adds `expects :params, type: :params` (or your custom `expect` field)
2. **Exposes form**: Adds `exposes :form` (or your custom `expose` field)
3. **Creates form**: Defines a memoized method that creates the form from params
4. **Validates in before hook**: Runs `form.valid?` in a before hook; if invalid, the action fails

```ruby
# This:
use :form, type: MyForm

# Is roughly equivalent to:
expects :params, type: :params
exposes :form, type: MyForm

def form
  @form ||= MyForm.new(params)
end

before do
  expose form: form
  fail! unless form.valid?
end
```

## Error Handling

When form validation fails:
- The action fails (returns `ok? == false`)
- `result.error` contains a generic message
- `result.form.errors` contains the detailed validation errors

```ruby
result = CreateUser.call(params: { email: "", name: "" })

result.ok?                    # => false
result.form.errors.full_messages
# => ["Email can't be blank", "Name can't be blank"]
```

### User-Facing Errors

To expose user-friendly error messages, configure a custom error handler:

```ruby
class CreateUser
  include Axn

  use :form, type: CreateUser::Form

  error { form.errors.full_messages.to_sentence }

  def call
    User.create!(form.to_h)
  end
end
```

## Complete Example

```ruby
class CreateCompanyMember
  include Axn

  expects :company, model: Company
  use :form, type: MemberForm, inject: [:company]

  exposes :member

  error { form.errors.full_messages.to_sentence }
  success { "#{member.name} has been added to #{company.name}" }

  def call
    member = company.members.create!(form.to_h)
    expose member: member
  end
end

class MemberForm < Axn::FormObject
  attr_accessor :company  # Injected

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :role, presence: true, inclusion: { in: %w[admin member guest] }

  validate :email_not_already_member

  private

  def email_not_already_member
    return unless company&.members&.exists?(email: email)

    errors.add(:email, "is already a member of this company")
  end
end
```

## See Also

- [Axn::FormObject](/reference/form-object) - The base class for form objects
- [Validating User Input](/recipes/validating-user-input) - When to use form validation vs expects validation
