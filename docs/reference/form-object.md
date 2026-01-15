---
outline: deep
---

# Axn::FormObject

`Axn::FormObject` is a base class for creating form objects that validate user input. It extends `ActiveModel::Model` with conveniences specifically designed for use with Axn actions.

## Overview

Form objects provide a layer between raw user input and your domain logic. They:
- Validate user-facing input with friendly error messages
- Provide a clean interface for accessing validated data
- Support nested form objects for complex forms
- Automatically track field names for serialization

## Basic Usage

```ruby
class RegistrationForm < Axn::FormObject
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, presence: true, length: { minimum: 8 }
  validates :password_confirmation, presence: true

  validate :passwords_match

  private

  def passwords_match
    return if password == password_confirmation

    errors.add(:password_confirmation, "doesn't match password")
  end
end
```

## Auto-Generated Accessors

Unlike plain `ActiveModel::Model`, `Axn::FormObject` automatically creates `attr_accessor` methods for any field you validate:

```ruby
class MyForm < Axn::FormObject
  validates :name, presence: true    # Automatically creates attr_accessor :name
  validates :email, presence: true   # Automatically creates attr_accessor :email
end

form = MyForm.new(name: "Alice", email: "alice@example.com")
form.name   # => "Alice"
form.email  # => "alice@example.com"
```

You can also explicitly declare accessors:

```ruby
class MyForm < Axn::FormObject
  attr_accessor :optional_field  # Tracked in field_names

  validates :required_field, presence: true
end
```

## Field Name Tracking

`Axn::FormObject` tracks all declared fields in `field_names`, which is used for serialization:

```ruby
class MyForm < Axn::FormObject
  validates :name, presence: true
  validates :email, presence: true
  attr_accessor :notes
end

MyForm.field_names  # => [:name, :email, :notes]
```

## Serialization with `#to_h`

The `#to_h` method converts the form object to a hash containing all tracked fields:

```ruby
class ProfileForm < Axn::FormObject
  validates :name, presence: true
  validates :bio, length: { maximum: 500 }
end

form = ProfileForm.new(name: "Alice", bio: "Developer")
form.to_h  # => { name: "Alice", bio: "Developer" }
```

This is particularly useful when creating or updating records:

```ruby
class UpdateProfile
  include Axn

  use :form, type: ProfileForm

  expects :user, model: User

  def call
    user.update!(form.to_h)
  end
end
```

## Nested Forms

Use `nested_forms` (or `nested_form`) to declare child form objects:

```ruby
class OrderForm < Axn::FormObject
  validates :customer_email, presence: true

  nested_form shipping_address: AddressForm
  nested_form billing_address: AddressForm
end

class AddressForm < Axn::FormObject
  validates :street, presence: true
  validates :city, presence: true
  validates :zip, presence: true
end
```

### Nested Form Behavior

- Nested forms are validated when the parent is validated
- Child errors are bubbled up with prefixed attribute names
- The child form receives a `parent_form` accessor if it defines one

```ruby
form = OrderForm.new(
  customer_email: "alice@example.com",
  shipping_address: { street: "123 Main St", city: "Boston", zip: "02101" },
  billing_address: { street: "", city: "", zip: "" }  # Invalid
)

form.valid?  # => false
form.errors.full_messages
# => ["Billing address.street can't be blank", "Billing address.city can't be blank", ...]
```

### Accessing Parent Form

Child forms can access their parent:

```ruby
class LineItemForm < Axn::FormObject
  attr_accessor :parent_form  # Will be set automatically

  validates :quantity, presence: true, numericality: { greater_than: 0 }

  validate :quantity_available

  private

  def quantity_available
    return unless parent_form&.product

    max = parent_form.product.stock_quantity
    errors.add(:quantity, "exceeds available stock (#{max})") if quantity > max
  end
end
```

## Inheritance

Form objects support inheritance, and field names are inherited:

```ruby
class BaseForm < Axn::FormObject
  validates :created_by, presence: true
end

class UserForm < BaseForm
  validates :email, presence: true
  validates :name, presence: true
end

UserForm.field_names  # => [:created_by, :email, :name]
```

## Integration with Actions

Form objects are designed to work seamlessly with the [Form Strategy](/strategies/form):

```ruby
class CreateUser
  include Axn

  use :form, type: UserForm

  exposes :user

  error { form.errors.full_messages.to_sentence }
  success { "Welcome, #{user.name}!" }

  def call
    user = User.create!(form.to_h)
    expose user: user
  end
end

class UserForm < Axn::FormObject
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :password, presence: true, length: { minimum: 8 }
end
```

## Complete Example

```ruby
class CompanyRegistrationForm < Axn::FormObject
  validates :company_name, presence: true
  validates :industry, presence: true, inclusion: { in: %w[tech finance healthcare retail] }

  nested_form admin: AdminForm
  nested_form billing: BillingForm

  def industry_options
    [
      ["Technology", "tech"],
      ["Finance", "finance"],
      ["Healthcare", "healthcare"],
      ["Retail", "retail"]
    ]
  end
end

class AdminForm < Axn::FormObject
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :password, presence: true, length: { minimum: 8 }
end

class BillingForm < Axn::FormObject
  attr_accessor :parent_form

  validates :billing_email, presence: true
  validates :payment_method, presence: true, inclusion: { in: %w[card ach invoice] }

  def billing_email
    @billing_email.presence || parent_form&.admin&.email
  end
end
```

## See Also

- [Form Strategy](/strategies/form) - Using form objects with actions
- [Validating User Input](/recipes/validating-user-input) - When to use form objects
