---
outline: deep
---

# Class Methods

## `.expects` and `.exposes`

Actions have a _declarative interface_, whereby you explicitly declare both inbound and outbound arguments.  Specifically, variables you expect to receive are specified via `expects`, and variables you intend to expose are specified via `exposes`.

Both `expects` and `exposes` support the same core options:

| Option | Example (same for `exposes`) | Meaning |
| -- | -- | -- |
| `sensitive` | `expects :password, sensitive: true` | Filters the field's value when logging, reporting errors, or calling `inspect`
| `default` | `expects :foo, default: 123` | If `foo` is missing or explicitly `nil`, it'll default to this value (not applied for blank values)
| `optional` | `expects :foo, optional: true` | **Recommended**: Don't fail if the value is missing, nil, or blank. Equivalent to `allow_blank: true`
| `allow_nil` | `expects :foo, allow_nil: true` | Don't fail if the value is `nil` (but will fail for blank strings)
| `allow_blank` | `expects :foo, allow_blank: true` | Don't fail if the value is blank (nil, empty string, whitespace, etc.)
| `allow_empty` | `expects :ids, type: Array, allow_empty: true` | Speaks to **emptiness only**, leaving nullability to the options above: `true` accepts an empty value while the field stays required and non-nil; `false` rejects an empty one (pair it with `optional:` for "may be omitted, but not empty"). Requires a `type:` whose values can be empty, and accepts only `true`/`false`/`nil`. See [the four requiredness contracts](#requiredness-is-two-questions)
| `if` / `unless` | `expects :coupon, type: String, if: :promo_enabled?` | Conditionally validate: gates **every** check in this declaration (including the implicit presence check) on an action method (Symbol) or Proc. See [Conditional validation](#conditional-validation-if-unless)
| `type` | `expects :foo, type: String` | Custom type validation -- fail unless `name.is_a?(String)`
| anything else | `expects :foo, inclusion: { in: [:apple, :peach] }` | Any other arguments will be processed [as ActiveModel validations](https://guides.rubyonrails.org/active_record_validations.html) (i.e. as if passed to `validates :foo, <...>` on an ActiveRecord model) — with four exceptions. `confirmation:` axn extends past ActiveModel's own behavior (see below). `inclusion:`/`exclusion:` constrain the value at the position they are declared at, where ActiveModel distributes a set over an `Array` value's elements (see [Where a validator applies](#where-a-validator-applies)). `format:`/`numericality:` are refused at declaration on a container-typed field rather than silently constraining the container's `to_s` or coercing it. And an `inclusion:`/`acceptance:`/`comparison:` literal that no value of the declared type could satisfy is refused at declaration, at every type. An `Axn::FormObject` is an ActiveModel model rather than an axn contract, so `validates` there keeps ActiveModel's own readings throughout

### Dynamic `sensitive` fields

The `sensitive` option can accept a proc or symbol in addition to a boolean, allowing you to conditionally filter fields based on runtime values. Those — plus `nil`, which means `false` — are the **only** values it accepts: anything else raises at class definition, because a value that isn't a redaction rule would silently leave the field logged in the clear rather than fail (`sensitive: "yes"` reads like an opt-in and redacts nothing). The rule is the same wherever `sensitive:` is accepted: a field, an `exposes`, an `on:` subfield, and a shape member.

```ruby
class MyAction
  include Axn

  expects :include_pii, type: :boolean
  expects :ssn, sensitive: -> { !include_pii } # [!code focus]

  exposes :api_response, sensitive: :should_redact? # [!code focus]

  def call
    expose api_response: fetch_data
  end

  private

  def should_redact?
    !include_pii || result.api_response[:contains_secrets]
  end
end

# When include_pii is false, ssn is filtered
MyAction.call(include_pii: false, ssn: "123-45-6789")
#=> inputs: { ssn: [FILTERED], include_pii: false }

# When include_pii is true, ssn is visible
MyAction.call(include_pii: true, ssn: "123-45-6789")
#=> inputs: { ssn: "123-45-6789", include_pii: true }
```

The callable receives no arguments and is evaluated via `instance_exec`, so it has access to:
- All `expects` field values (via their reader methods, e.g., `include_pii`)
- Exposed values via `result.field` (e.g., `result.api_response`) — bare field names are **not** available for `exposes`-only fields
- Any instance methods defined on the action

::: warning Timing: sensitive evaluated before defaults
For `expects` fields, the `sensitive` callable is evaluated **before** defaults are applied. This means if your sensitivity logic depends on another field's value, that field should either be required or you should handle `nil` explicitly:

```ruby
# CAUTION: mode may be nil if caller doesn't provide it
expects :mode, default: "public"
expects :api_key, sensitive: -> { mode != "debug" }  # mode could be nil here!

# SAFER: handle nil explicitly
expects :api_key, sensitive: -> { mode.nil? || mode != "debug" }
```

This is because automatic logging of inputs happens before defaults are applied in the execution flow. For `exposes` fields, this is not a concern since output logging happens after the action completes.
:::

### Validation details

::: warning
While we _support_ complex interface validations, in practice you usually just want a `type`, if anything.  Remember this is your validation about how the action is called, _not_ pretty user-facing errors (there's [a different pattern for that](/recipes/validating-user-input)).
:::

In addition to the [standard ActiveModel validations](https://guides.rubyonrails.org/active_record_validations.html), we also support five additional custom validators:
* `type: Foo` - fails unless the provided value `.is_a?(Foo)`
  * Edge case: use `type: :boolean` to handle a boolean field (since ruby doesn't have a Boolean class to pass in directly)
    * Boolean `expects` fields also define a predicate reader, so `expects :enabled, type: :boolean` provides both `enabled` and `enabled?` on the action instance. The same applies to subfield readers. Boolean `exposes` fields provide predicate readers on the result, so `exposes :enabled, type: :boolean` provides `result.enabled?`.
  * Edge case: use `type: :uuid` to handle a confirming given string is a UUID (with or without `-` chars)
  * Edge case: use `type: :params` to accept either a Hash or ActionController::Parameters (Rails-compatible)
  * `type:` must name a type — a class or module, a union of them (`type: [String, Symbol]`), or one of `:boolean`/`:uuid`/`:params` — and this is checked at declaration: `type: false`, `type: 5`, `type: [String, nil]` and `type: { klass: false }` all raise `ArgumentError` when the class is defined rather than reaching `value.is_a?(...)` and raising a bare `TypeError` on every call. Same rule at every position a field's own `type:` can be declared — `expects`, `exposes`, a subfield, an ambient subfield, and a shape member.
* `of:` - names what is INSIDE a container: for `type: Array`, each element; for `type: Hash`, its keys and/or values. A validator declared alongside `of:` (rather than inside it) still constrains the container's own value, not its contents — see [Where a validator applies](#where-a-validator-applies)
  * For `type: Array`: `of: Foo` validates each element (fails unless every element `.is_a?(Foo)`). Accepts the same forms as `type:`: a single class (`of: String`), a union array (`of: [String, Numeric]` — an element passes if it matches *any*), the `:boolean`/`:uuid`/`:params` symbols, or a `Data.define` class. Error messages report the failing element's index (e.g. `element at index 2 is not a String`). Pass `of: { klass: Foo, message: "..." }` to override the type description while still reporting the index — `message:` is only accepted here, not on a Hash's `of:`
  * For `type: Hash`: `of: { keys: Foo, values: Bar }` declares a map. Either axis may be omitted, which is how you say that axis is unconstrained (`of: { values: Integer }` constrains only the values, leaving any key through); an axis you *do* write has to name a type, so `values: []`, `values: nil` and `values: false` all raise `ArgumentError` rather than passing as a constraint that matches nothing (omitting the axis is the spelling of "unconstrained"; writing one that names nothing is not), and `of: {}` raises on the same rule. Each axis accepts the same forms `type:` does — a single class, a union array (`keys: [String, Symbol]` — a key passes if it matches *any*), the `:boolean`/`:uuid`/`:params` symbols, or a `Data.define` class. The bare form (`of: Foo`) is Array-only and raises `ArgumentError` on a Hash — a bare class can't say which axis it constrains, so both have to be spelled out (or omitted) explicitly. Error messages report the failing entry's ordinal position rather than its key (e.g. `key at index 0 is not a Symbol`, `value at index 0 is not a Integer`): the key itself is never rendered into the message, since a validation message settles unredacted, and rendering it would leak a `sensitive:` map's own data into `result.exception.message` and the log line
  * **The inner-contract bag**: the `of:` value at any one position, naming what that position holds — `klass:` (its class, playing the role `type:` plays at the top level), `of:` (what is inside *it*, recursively), `shape:` (its members, in the same raw form the field-level [`shape:`](#shape-blocks) option takes), `message:` (the description used when that position fails), and the **value validators** for the value at that position: `format:`, `inclusion:`, `exclusion:`, `length:`, `numericality:`, `comparison:`, `presence:`, `absence:`, `acceptance:` and `validate:`. It sits in exactly three positions — an Array's element (`of: { ... }`), a map's `keys:` axis and a map's `values:` axis — and a bare class in any of them is still sugar for `{ klass: <that class> }`. Which grammar a bag's own `of:` is held to is decided by that bag's `klass:`, exactly as `type:` decides it at the top level: `klass: Array` takes an element contract, `klass: Hash` takes a `keys:`/`values:` pair. A block reaches an Array's element (`type: Array, of: Hash do field :sku, type: String end` declares the element's members) but never an axis, so a map's shaped values are spelled with the raw form, whose `members:` are objects answering `field` and `validations` — a `Struct.new(:field, :validations)` is enough.
    ```ruby
    expects :matrix,    type: Array, of: { klass: Array, of: Integer }
    expects :buckets,   type: Array, of: { klass: Hash, of: { values: Integer } }
    expects :by_region, type: Hash,  of: { values: { klass: Array, of: Integer } }
    expects :counts,    type: Hash,  of: { keys: { klass: String }, values: { klass: Integer, message: "must be a whole number" } }
    ```
  * A bag's **value validators constrain the value at that position** — the same rule a field's own validators follow, one rung down. So `of: { klass: String, format: { with: /\A[A-Z]{2}\z/ } }` holds every element to a two-letter code, `of: { values: { klass: Integer, numericality: { greater_than: 0 } } }` holds every map value positive, and `of: { keys: { klass: Symbol, inclusion: { in: KNOWN } } }` holds every key to a known set. `exclusion:` works correctly here where it never could at a field level, and a `validate: ->(value) { ... }` callable reaches a single element. Failure messages locate the position, never the key: `element at index 1 is invalid`, `value at index 0 must be greater than 0`.

    Because it is the same rule, it is enforced by the same guards: `format:` and `numericality:` are refused when the bag's `klass:` names a container (their contents have their own position — nest another `of:`), and a set no value of the bag's `klass:` could satisfy is refused as unsatisfiable, exactly as at a field. Validators a *position* cannot read are refused outright: `type:` (the bag spells that `klass:`), `model:` (it resolves against a `<field>_id` reader), `confirmation:` (it reads a sibling reader), `coerce:` (a transform rather than a constraint) and `uniqueness:` (it needs a record and a relation).

  * Whether a position admits `null` in its emitted type is derived from the bag's own `klass:` **and** its validators together, so `of: { klass: [String, NilClass] }` advertises the null branch and `of: { klass: [String, NilClass], presence: true }` does not.

  * A bag's `allow_nil:`/`allow_blank:` govern **the whole field**, not the position — `of: { klass: String, allow_nil: true }` says the field may be nil, and does **not** make individual `nil` elements legal. There is currently no per-element spelling: widening the element's class (`of: { klass: [String, NilClass] }`) does admit a `nil` element on its own, but only while the bag carries no other validator, since ActiveModel runs `format:`/`length:`/`inclusion:`/`numericality:` on a `nil` regardless of what the type permits.

  * A bag has to **constrain something** — at least one of `klass:`, `of:`, `shape:` or a value validator. `of: {}` and `of: { message: "..." }` raise `ArgumentError` at declaration, since a message describes a constraint rather than being one. `klass:` is the part you may leave out (`of: { shape: ... }` constrains an element's members while leaving its class open), but a bag carrying `of:` must name its container: `of: { of: Integer }` raises, because with no `klass:` nothing says whether that inner `of:` is an element contract or a map's axes. A `klass:` that names no single container is refused for the same reason — `of: { klass: String, of: Integer }` (a String has nothing inside it) and `of: { klass: [Array, Hash], of: ... }` (a union names two grammars) both raise. And a `klass:` naming something that is not a type at all raises wherever it is written — `of: false`, `of: { klass: 5 }`, `of: { values: { klass: nil } }`, `of: { klass: [String, nil] }` — since it takes exactly the forms `type:` does (a class or module, a union of them, or one of `:boolean`/`:uuid`/`:params`) and anything else reaches `value.is_a?(...)` and raises a bare `TypeError` on every call; the message names `klass:`, which is what there is to fix at every position a bag sits at.
  * Failures compose one position per level, so a message locates the value inside the whole structure rather than at its outermost container: `matrix` above reports `element at index 0: element at index 1 is not a Integer`, and `by_region` reports `value at index 0: element at index 1 is not a Integer`. A map entry is located by its **ordinal, never its key**, at every depth, for the leak reason given above.
  * Only valid alongside `type: Array` or `type: Hash` (exactly) — using it on any other type, including a union like `type: [Array, Hash]`, raises `ArgumentError` at declaration time, since axn can't tell which container's grammar the bag belongs to
  * A Hash's `of: { values: Bar }` reflects in the schema as `additionalProperties: <Bar's schema>` (a union `values:` emits `anyOf` branches, a `Data` `values:` class emits its members as `properties`); a `keys:` axis that names only a TYPE emits nothing — every JSON object key is already a string, so `keys: String` would say nothing actionable and `keys: Symbol` would misdescribe the wire format (an axis carrying a *constraint* does reflect, as `propertyNames` — see below). A nested bag reflects at the node it names, so nesting in the declaration is nesting in the document: `of: { klass: Array, of: Integer }` on an Array emits `items: { type: "array", items: { type: "integer" } }`, and `of: { values: { klass: Hash, of: { values: Integer } } }` on a Hash emits `additionalProperties: { type: "object", additionalProperties: { type: "integer" } }`. On **output**, a self-gated positional validator (`of: { klass: String, inclusion: { in: ["a"], if: :flag } }`) is reduced away rather than emitted — the action may successfully expose a value a closed gate never checked, and an output schema that rejects what the action serializes is worse than one that says less. On input it is advertised regardless, reflection being static-maximal there.

  * A bag's **value validators** reflect at the node the bag names, through the same projection a field's do: `of: { klass: String, format: { with: /\A[A-Z]{2}\z/ } }` emits `items: { type: "string", pattern: "^[A-Z]{2}$" }`, and `of: { values: { klass: Integer, numericality: { greater_than: 0 } } }` emits `additionalProperties: { type: "integer", exclusiveMinimum: 0 }`. A `length:` at a position measures the element's own length, so it emits `maxLength` for a string element where the field's own `length:` emits `maxItems` for the array

  * A **constrained `keys:` axis** is the one thing that now reflects, as `propertyNames` — a bare `keys: String` or a bag that only names a class still emits nothing, since every JSON object key is already a string and that says nothing actionable. Only the constraints that survive the string form of a key are emitted: a `format:` emits `pattern`, a `length:` emits `minLength`/`maxLength`, and a Symbol `inclusion:` set emits its members in their wire form (`inclusion: { in: %i[a b] }` becomes `enum: ["a", "b"]`). A set whose members have no property-name form emits no `enum` at all — `keys: { klass: Integer, inclusion: { in: [1] } }` really does accept `{ 1 => v }` at runtime, and no `propertyNames` set can say so, so the axis's other constraints are emitted without it rather than publishing a set no key satisfies. A numeric bound on a keys axis emits nothing — a Ruby Hash key may legitimately be an Integer, but no `propertyNames` subschema says "parses to an integer greater than zero", so that stays a Ruby-side check.

    Where a `shape:` sits beside a constrained `keys:` axis, the emitted `propertyNames` is a **union**: `propertyNames: { anyOf: [<the axis constraint>, { enum: [<the shape's key names>] }] }`. JSON Schema applies `propertyNames` to every key including ones `properties` matches, while the runtime exempts a shape-named key from both axes — so the bare constraint would forbid a key the shape requires, leaving a node no value satisfies. The union is the runtime rule verbatim: a key is one the shape names, or one the axis admits
  * The `of:` option bag itself only accepts the keys its container allows (`klass:`/`of:`/`shape:`/`message:` plus the shared ActiveModel options for an Array's element; `keys:`/`values:` plus those shared options for a Hash, with each axis taking a type or an inner-contract bag of its own) — anything else, a misspelled option (`mesage:` for `message:`) included, raises `ArgumentError` at declaration time, naming every offending key at once. The shared options are refused on a map **axis** specifically (`of: { values: { klass: Integer, if: :flag } }` raises): an axis is the one position a bag is never handed to ActiveModel as a validator entry, so nothing would read them — gate the field instead (`expects :m, type: Hash, of: { values: Integer }, if: :flag`). A subfield (`on:`) rooted at a map is still refused at any depth, as "not supported yet"
  * **`of:` beside `shape:` on a Hash** is supported, and a Hash is the only container where the two name different nodes: `shape:` (or a [block](#shape-blocks)) names specific keys, `of:` names everything else. A key the shape names is therefore **exempt** from the map contract, on both axes — which is exactly what JSON Schema means by `additionalProperties` applying only to keys `properties` does not match, so the runtime and the emitted document say the same thing. It is also what makes the pairing worth writing: the named keys usually differ in type from the rest, and a named key that wants more than the blanket type simply restates it. The exemption matches a string key as readily as a symbol one (`{"label" => "q3"}` is the exempt `label`, not an entry for `of:` to check), and the ordinal in a failure message counts every entry, exempt keys included
    ```ruby
    expects :metrics, type: Hash, of: { values: Integer } do
      field :label, type: String
    end

    # { label: "q3", visits: 120, signups: 4 }  => ok
    # { label: "q3", visits: "lots" }           => Metrics value at index 1 is not a Integer
    # { visits: 120 }                           => Metrics label is not a String
    ```
    ...and the emitted property carries both halves at one node:
    ```ruby
    # input_schema[:properties][:metrics]
    { type: "object",
      additionalProperties: { type: "integer" },
      properties: { label: { type: "string", minLength: 1 } },
      required: ["label"],
      minProperties: 1 }
    ```
* `validate: [callable]` - Support custom validations (fails if any string is returned OR if it raises an exception)
  * Example:
    ```ruby
    expects :foo, validate: ->(value) { "must be pretty big" unless value > 10 }
    ```
* `model: true` (or `model: TheModelClass` or `model: { klass: TheModelClass, finder: :find }`) - allows auto-hydrating a record when only given its ID
  * Example:
    ```ruby
    expects :user, model: true
    # or
    expects :user, model: User
    # or with custom finder
    expects :user, model: { klass: User, finder: :find }
    ```
    This line will add expectations that:
      * `user_id` is provided (automatically derived from field name)
      * `User.find(user_id)` (or custom finder) returns a record

    And, when used on `expects`, will create reader methods for you:
      * `user` (the auto-found record)
      * `user_id` (the record's primary key) — see below

    ::: info NOTES
    * The system automatically looks for `#{field}_id` (e.g., `:user` → `:user_id`)
    * The `klass` option defaults to the field name classified (e.g., `:user` → `User`)
    * The `finder` option defaults to `:find` but can be any method that takes an ID directly
    * This works with any class that has a finder method (e.g., `User.find`, `ApiService.find_by_id`, etc.)
    * For external APIs, you can pass a `Method` object as the finder
    :::

    **The `<field>_id` reader.** Alongside `user`, a `model:` field defines a `user_id` reader whose one meaning is *the primary key of the record* — regardless of whether you were called with `user:` or `user_id:`:

    ```ruby
    expects :user, model: true
    # called with user_id: 5  → user_id == 5,         user resolves the record
    # called with user: <rec> → user_id == rec.id,    user is that record
    ```

    It never triggers an extra lookup: for the default `:find` finder a supplied id *is* the pk and is returned as-is; otherwise it reads the (memoized) record's `.id`, reusing the same resolution `user` already does. So it's meaningful even with a custom finder — where the `user_id` *key* holds a finder-specific token, `user_id` still returns the resolved record's actual primary key. The reader is alias-aware (`as: :raw_user` → `raw_user_id`) and silently defers (with a debug-level log) to any same-named method you've already declared. (Composite primary keys are not supported by the singular `<field>_id` convention.)

    **Record / id consistency.** For the default `:find` finder, passing **both** a record and a `<field>_id` that disagree (`user: <rec id=5>, user_id: 9`) raises `InboundValidationError` rather than silently preferring one — contradictory input is a developer error. Passing just one, or both in agreement, is fine. The check is skipped for custom finders, where the `<field>_id` value is a lookup token, not a primary key, so a record-vs-id comparison would be meaningless.

    `klass:` must name a single Class or Module — a record is resolved by calling the finder method **on** it, so there is nothing for a union or a `type:`-style pseudo-type to dispatch through, and either raises `ArgumentError` at declaration.

* `confirmation: true` - declares a companion input, `<field>_confirmation`, and fails unless it matches the field's actual value
  * Note this departs from ActiveModel, which lets an omitted confirmation pass. See [Confirmation pairs](#confirmation) for the details.

#### Where a validator applies {#where-a-validator-applies}

A validator constrains the value at the position it is declared at.

On the `expects` that is the field's own value, so `inclusion:` on a `type: Array` field asks whether the ARRAY is a member of the set (`inclusion: { in: [["a", "b"], ["c"]] }`), and `length:` measures the array's size.

A constraint on the *contents* belongs at the contents' own position — inside `of:` — and until that bag accepts value validators, a `validate: ->(value) { ... }` callable expresses it.

Two validators have no reading at a container position at all and are refused at declaration: `format:`, which ActiveModel matches against `value.to_s`, so on an `Array` it would constrain the Ruby inspect form, and `numericality:`, which parses a numeric coercion no container has.

`comparison:` and `acceptance:` are **not** refused by key — their options can name a container, and then they work (`comparison: { equal_to: ["a"] }` accepts `["a"]`, `comparison: { greater_than_or_equal_to: { "read" => true } }` accepts a Hash superset, `acceptance: { accept: [["a"]] }` accepts `["a"]`) — so they are judged by their literals instead, below.

An `inclusion:` set, an `acceptance:` `accept:` set, or a `comparison:` bound that no value of the declared `type:` could satisfy is refused on the same terms, at every type — `type: Array, inclusion: { in: ["a", "b"] }`, `type: Integer, inclusion: { in: ["1", "2"] }`, `type: Array, comparison: { greater_than: 1 }` and `type: Array, acceptance: true` (compared against ActiveModel's default `["1", true]`) alike — since each rejects every input while looking like a constraint.

It stands down wherever a value could still pass or the literals cannot be judged at declaration: a contract that admits nil at all (a tolerance flag, a nil-admitting `type:`, or a validator like `acceptance:` that skips nil of its own accord — judged across every validator on the field, since one entry's tolerance does not carry a field whose other checks still reject nil), an undeclared or pseudo-type `type:`, a set read dynamically (a Symbol, a Proc, an `ActiveRecord::Relation`) or held in an `Array` subclass, a `Hash` `accept:` set, and a `comparison:` bound ActiveModel resolves per call, and a `comparison:` bound on any non-container type at all (outside a container, `<=>` and `==` belong to the declared class — a `Comparable` value object whose `<=>` accepts a `Numeric` satisfies `type: Money, comparison: { greater_than: 0 }`, and no ancestry test predicts that).

The judgment is a closed world: it reaches only pairs drawn from Ruby's core value types — `String`, `Symbol`, `Integer`, `Float`, `Rational`, `nil`, `true`/`false`, `Array`, `Hash`, `Set`, `Date`, `Time`, `DateTime` — and stands down on every other pair, a SUBCLASS of one of them included. Equality is not inferable from ancestry: an `Array` subclass equals a plain Array (`SubArray.new([1]) == [1]`), a `Regexp` subclass equals a plain Regexp, and a `Comparable` value object may accept any class its `<=>` chooses to — so the guard names what it knows rather than enumerating exceptions, and a pair it does not vouch for declares. Within that set, a literal in the same cross-comparable family as the declared type still compares across classes (every `Numeric` with every other, and the `Date`/`Time`/`DateTime` trio), which is why `type: Float, inclusion: { in: [0, 1] }` declares.

A `Range` set is the one literal the position itself decides. At a scalar position it stands the check down, because cross-type comparison genuinely works there (`(1.0..5.0).cover?(3)` is true, so a Float-bounded range is satisfiable on `type: Integer`). At a container position it is judged by its **bounds**, because `<=>` is nil across unrelated classes and `type: Array, inclusion: { in: 1..5 }` can never match.

An `if:`/`unless:` gate does **not** excuse either refusal: a gate decides whether a check runs, not what it can mean.

`exclusion:` follows the positional rule alongside `inclusion:`, but it is **not** checked for satisfiability, and the asymmetry is deliberate. A set no value of the declared type could be a member of makes an exclusion enforce **nothing** rather than reject everything, so there is no unsatisfiable contract to refuse. `type: Array, exclusion: { in: ["admin"] }` therefore declares cleanly and permits every array, `["admin"]` included — the elements it reads as forbidden are at their own position, not this one. Nothing raises for it, so audit an `exclusion:` on a container-typed field yourself.

#### Describing the shape of structured fields (block syntax) {#shape-blocks}

For a structured field — `type: Array`, `type: Hash`, or a class such as a `Data.define` — you can pass a block to declare per-member contracts (types, enums, descriptions, nesting). This works on both `expects` and `exposes`:

```ruby
exposes :integrations, type: Array, of: IntegrationRecord do
  field :source, type: String
  field :status, type: String, inclusion: { in: %w[connected connected_with_issues needs_reconnect incomplete error] }

  field :config, type: Hash do                  # nested object
    field :region, type: String
  end
  field :endpoints, type: Array do              # nested array of objects
    field :url, type: String
  end
end
```

* The block requires a single, **structured** `type:` (Array, Hash, or a class). Declaring it on a scalar type (`String`, `Integer`, `:boolean`, …), a union (`type: [Array, String]`), or with no `type:` raises `ArgumentError` at declaration time.
* For `type: Array`, each element is validated and errors report the element's index (e.g. `element at index 2: status is not included in the list`). For a `type: Hash`/class, the single value's members are validated directly.
* A **raw `shape:` kwarg** — a Hash you build yourself, rather than the block above — names the members of the value it is declared on, with no exception: `shape:` beside `type: Array` raises `ArgumentError` at declaration, pointing at the inner-contract bag (`of: { klass: Hash, shape: { members: [...] } }`) or at the block above, both of which still distribute. A raw shape naming `container: Array` itself is refused the same way, wherever it is written — an Array has no members of its own, so `shape:` has exactly one meaning at every position.
* Members accept validations (`type`, `inclusion`, …), `optional`/`allow_blank`/`allow_nil`/`allow_empty`, `sensitive:`, `user_facing:` (`expects` shapes only), and `description`, and **recurse** — a member with its own block validates its nested members at any depth. On an **`expects`** shape, `user_facing:` on a member has full parity with a field's — `true`/String/Symbol/Proc — and surfaces that member's own failure to the caller; a member that doesn't opt in stays dev-facing. On an **`exposes`** shape it is **rejected at declaration** (an outbound failure is a dev-facing bug — bad output — never the caller's fault), so the `exposes` example above cannot carry it. Members are **reader-less, validation/schema-only** declarations, so `default:` and `preprocess:` are **not** supported on a member (they raise at declaration time): they produce or transform a value, which needs a resolution target (a reader) to land on — a member has none; declare it as an `expects … on:` subfield if you need those. (`model:` is likewise rejected — it resolves a record from an id and exposes a `<field>_id` reader a member can't provide; use `type: Klass` for a plain instance check.) Two members under the same parent — or two top-level members of one shape — must have distinct names (a duplicate raises at declaration), and may not carry two names that render as the same JSON property ([which raises when the schema is first built](#property-name-rules)). Members of different parent blocks never collide even at the same depth: a `zip` inside a `from` block and a `zip` inside a `to` block are properties of different objects, exactly like `zip` under both `billing` and `shipping` for subfields.
* A declared contract is **fixed at declaration**: axn deep-copies a `shape:` you pass as a raw Hash, so mutating that Hash (or the members Array, or a nested shape inside it) afterwards does not change a class already declared — building one up in a loop and declaring after each step gives each class the members it had at the time. Your object is copied, never frozen, so reusing or extending it is fine. The `of:`/`validate:`/`inclusion:` option containers are copied on the same terms — appending to an `inclusion:` list after declaring cannot widen a declared enum. A container axn cannot copy faithfully is **refused at declaration** rather than copied: if it defines methods of its own — an `include?`, a duplication hook, anything, whether on its class, on a module extended onto it, or on the object itself — pass a plain Array, or `freeze` yours, which is stored as-is with no copy at all (a frozen container can't be mutated afterwards, which is the only thing the copy protects against). `dup` copies the elements but shares the instance variables and drops singleton methods, so a copy answers as you declared only where every answer is Ruby's own: a set whose `include?` reads its own identity, an ivar, or a singleton method accepts what you declared and its copy does not — and the copy *is* the stored contract, so the class would reject the values you declared as valid. A membership container that is not an Array (a `Set`, a `Range`, your own object answering `include?`) is stored as your object and answers membership itself, so it is neither copied nor refused — a mutable one is still yours to widen after the class is declared. Shape **members** are copied too, whatever they are: axn reads each one's `field`, validations, metadata, `sensitive:`, `user_facing:`, `method_call:` and `description` once and stores its own `ShapeConfig`, so a member object of your own — and any nested `shape:` it carries — is snapshotted rather than shared. Mutating it afterwards changes nothing about a class already declared.
* `sensitive:` **is** supported on a member and redacts its value from logs, exception context, and `inspect` — statically (`sensitive: true`) or dynamically (a `Proc`/`Symbol` resolved against the action, like a top-level field). Redaction is by member **name**, so for a **Hash** value (or an `Array` of Hashes) it is precise — only the sensitive member is masked, its siblings and every array element handled individually. **When the value carrying the member is not a Hash** — an object-backed shape (`type: SomeData`, `Array, of: SomeStruct`), or a malformed non-Hash value a caller sent by mistake (which reaches the pre-validation before-log) — the filter (which redacts Hash keys) can't reach inside it, so the **entire value is masked** (`person: [FILTERED]`) rather than risk a leak. This over-redacts — non-sensitive siblings inside that object are hidden too — and applies only to a field that actually carries a sensitive member (a shape with none is logged in full). For per-member precision on an object, expose the sensitive attribute as its own subfield (`expects :ssn, on: :person, method_call: true, sensitive: true`), which resolves to a scalar value that filters precisely.
* A member is read off the element by declared data only — a Hash key, or a `Struct`/`OpenStruct`/`Data` member (`Data` via `#to_h`, so no method is ever invoked). Reading a member off a non-`Data` object (a reader) or an Array (an Array method) invokes a method, so — like a subfield's [`method_call:`](#resolving-a-subfield-by-calling-a-method-method-call) — it's opt-in: `field :status, type: String, method_call: true`. Without the flag, reaching such a member raises `Axn::ContractViolation::MethodCallNotPermittedError` (loud, never silent — no method runs, so a mutating one like `field :pop` never mutates during validation). The rule applies at each depth of a nested shape.
* Unlike `expects … on:` subfields, a shape block does **not** define reader methods — there is no single value to bind (an array has many elements). It is a contract on structure only.
* Composes with `of:`: on an Array, `of:` checks each element's *class* while the block describes that element's *fields*; on a Hash, the block names specific keys and `of:` governs every key it does not name (see the exemption above). `of:` is optional.

::: tip Shape block vs. `on:` subfield — two tools, two jobs
Both describe nested structure, but they answer different questions:

* A **shape block** (`expects :items, type: Array do field … end`) **validates a structure** — it constrains the members of a value you already hold and defines **no** reader. Reach for it to assert the shape of an array's elements or a hash/object you pass through as one unit.
* An **`on:` subfield** (`expects :zip, on: "address.billing"`) **reads a value out** — it lifts a nested value up to a flat, validated field with [its own reader](#nested-subfield-expectations).

Rule of thumb: use a shape when you want to *check* the shape of a value; use `on:` when you want to *read* a value out of one.
:::

#### How `optional`, `allow_blank` and `allow_nil` work with validators

When you specify `optional: true`, `allow_blank: true`, or `allow_nil: true` on a field, these options are automatically passed through to **all validators** applied to that field. This means:

- **ActiveModel validations** (like `inclusion`, `length`, etc.) will respect these options
- **Custom validators** (`type`, `validate`, `model`, `of`) will also respect these options
- **Type validator edge case**: Note passing `allow_blank` is nonsensical for type: :params and type: :boolean
- **`of` validator note**: these options govern whether the whole Array field may be absent — they do **not** make individual elements optional. A `nil` (or blank) element is still validated against `of:` regardless.

**Recommended approach**: Use `optional: true` instead of `allow_blank: true` for better clarity. The `optional` parameter is equivalent to `allow_blank: true` and makes the intent clearer.

`allow_empty:` is **not** one of these pass-through options: it speaks to emptiness rather than nil-tolerance, so it is never pushed into your validators. `allow_empty: true` suppresses the automatic presence check (leaving the type check to reject `nil`), and `allow_empty: false` installs a non-emptiness check of its own — one that asks the value's `empty?` rather than measuring its length, so it works on a `type: :params` value that reports no length.

If none of `optional`, `allow_blank`, `allow_nil` or `allow_empty: true` is specified, a default presence validation is automatically added (unless the type is `:boolean` or `:params`, which have their own validation logic as described above).

#### Requiredness is two questions

Requiredness is really two independent questions — may the value be `nil` (or absent), and may it be empty? All four combinations are declarable:

| Declaration | `nil` / absent | empty (`[]`, `{}`, `""`) | non-empty |
| --- | --- | --- | --- |
| `type: Array` | rejected | rejected | accepted |
| `type: Array, allow_empty: true` | rejected | accepted | accepted |
| `type: Array, optional: true` | accepted | accepted | accepted |
| `type: Array, optional: true, allow_empty: false` | accepted | rejected | accepted |

`optional:`, `allow_blank:` and `allow_nil:` are three spellings of the third row. `allow_empty:` is the only option that speaks to emptiness alone, and it requires a `type:` whose values can be empty (`Array`, `Hash`, `Set`, `String`, `:params`, or any class or module defining `empty?`) — on a type with no empty state to talk about it raises at declaration. A union type must have an empty state on *every* member: `type: [Hash, Array]` is fine, `type: [Array, Integer]` raises. Emptiness is `empty?`, not `blank?`: a whitespace-only String is not empty, so `type: String, optional: true, allow_empty: false` accepts `" "` and rejects `""`.

`Set` is listed above because a `Set` has an empty state at *runtime*, and the runtime rules are exactly the four rows. Reflection is the caveat: `Set` has no JSON Schema mapping, so a `type: Set` field falls back to the permissive `{ type: "string" }` hint — and a `Set` that rejects empty therefore advertises `minLength: 1`, a string-shaped floor over a value that is not a string, while a declared `length:` ceiling advertises `maxLength` on the same terms. Treat a reflected `Set` as a hint, not a contract.

A field that rejects empty reflects that into its schema as `minItems` / `minProperties` / `minLength`, and a declared `length:` ceiling reflects as `maxItems` / `maxProperties` / `maxLength` (an exact `length: { is: 2 }` emitting both). A bound ActiveModel resolves per call (a Symbol or Proc) and an infinite one emit nothing, since no fixed number expresses them.

A declared `numericality:` or `comparison:` bound reflects the same way: `greater_than` as `exclusiveMinimum`, `greater_than_or_equal_to` as `minimum`, `less_than` as `exclusiveMaximum`, `less_than_or_equal_to` as `maximum`, `equal_to` as `const`, and a `numericality: { in: 1..10 }` range as both bounds. Where two of them bound the same side — two validators declaring `greater_than`, or an `in:` range beside an explicit `greater_than_or_equal_to` — the emitted bound is the **tighter** one, since ActiveModel enforces both. Two `equal_to:` values that disagree emit no `const` at all: nothing satisfies both, and no keyword says so. `other_than:`, `odd:`/`even:`, a per-call Symbol/Proc bound, a non-finite bound, and a non-numeric `comparison:` bound emit nothing — no keyword says what they mean.

An `inclusion:` set is likewise **intersected** with any `enum` the position's own type already imposes rather than replacing it, so `of: { klass: TrueClass, inclusion: { in: [true, false] } }` keeps `enum: [true]` — the type accepts only the singleton, and both constraints are enforced.

A declared `format:` reflects as `pattern` **when the regex translates faithfully**, and emits nothing when it cannot. JSON Schema's `pattern` is an ECMA-262 source carrying no flags, so `/\A[A-Z]{2}\z/` reflects as `"^[A-Z]{2}$"` — `\A`/`\z` become the ECMA input anchors, which is exact, since `^`/`$` there mean start/end of input with no `m` flag available to change that. A regex axn cannot translate exactly emits nothing rather than an approximation: a flag that changes what the source means (`/i` has no `pattern` spelling at all, Ruby's `/m` is ECMA's `s`, and `/n` matches bytes where a `pattern` is a Unicode string — a non-ASCII pattern is *not* refused, though Ruby marks every one of them with a fixed encoding), a Ruby-only escape or construct (`\Z`, `\h`, `\p{…}`, a POSIX bracket class, an atomic or named group, an inline flag group, a possessive quantifier, a class intersection, a nested class union — Ruby reads `[a[bc]]` as the set {a,b,c} where ECMA reads `[a[bc]` plus a literal `]`), an escape whose character set differs between the dialects (`\s`/`\S` — Ruby's is ASCII whitespace, ECMA's also includes NBSP and the Unicode Zs category — and `\b`/`\B`, where Ruby's word boundary is Unicode-aware though its own `\w` is not, so `/\A\Bé\B\z/` rejects `"é"` while `^\Bé\B$` accepts it; `\d` and `\w` themselves agree and are emitted), a `\A`/`\z` anywhere but the ends, a brace that is not a quantifier, a numeric backreference (where the referenced group did not participate, Ruby fails and ECMA matches empty), a hex or octal escape (Ruby reads `\xHH` as a byte and ECMA as a character; `\uHHHH` agrees and is emitted), a source in an encoding the translator cannot inspect, and a pattern ActiveModel resolves per call. `format: { without: }` emits nothing too — its honest spelling is `not: { pattern: … }`, and that slot is already spoken for.

One narrowing worth knowing: a Ruby `^`/`$` is a **line** anchor and ECMA's, with no flag available, is an **input** anchor, so `/^\d+$/` reflects as `"^\\d+$"` and the emitted pattern accepts a subset of what the runtime does. That is the direction reflection is documented to err in — stricter, never looser.

Only one thing may answer the emptiness question per declaration. An explicit `presence:` occupies the very check `allow_empty:` governs, so the two must agree — `presence: false, allow_empty: false` and `presence: true, allow_empty: true` each raise at declaration, naming both spellings. An author-declared `length:` is a different matter: it is your own size constraint, so `allow_empty: false` defers to a `length:` floor of 1 or more (and makes it fire on the empty value even under `optional:`, which would otherwise tolerate blank), adds its own floor alongside a `length:` that only caps the size, and raises for one that explicitly admits an empty value (`minimum: 0`, `is: 0`, `maximum: 0`, a range starting at 0, or its own `allow_blank: true`). `allow_empty: true` asks for nothing to be enforced, so it never conflicts with a `length:`.

#### Conditional validation (`if:` / `unless:`)

Both `expects` and `exposes` accept ActiveModel's `if:`/`unless:` as declaration-level options. The condition gates **every** validator in the declaration — including the automatically-added presence check — so a field can be *conditionally required*:

```ruby
expects :promo_enabled, type: :boolean
expects :coupon_code, type: String, if: :promo_enabled?
```

When `promo_enabled` is falsey, `coupon_code` is wholly unvalidated (it may be omitted, and a supplied value is not type-checked); when truthy, it is required and must be a String. `unless:` is the negation. Both may be given together and combine with AND — every condition must pass for validation to run. This also composes with subfields, making "required only when the parent is supplied" expressible:

```ruby
expects :data, optional: true
expects :user, type: String, on: :data, if: -> { data.present? }
```

To gate a *single* check instead of the whole declaration, nest the condition in that validator's own options — no duplicate declaration needed:

```ruby
expects :num, type: Integer, numericality: { greater_than: 100, if: :big_num_needed? }
```

Rules and caveats:

- **Conditions gate validation only.** `default:` and `preprocess:` are pipeline stages, not validations — they still apply when the condition is false. Readers and `sensitive:` filtering are likewise ungated.
- **Condition forms**: a Symbol names an action method or reader (a boolean field's generated `?` predicate works: `if: :promo_enabled?`); a Proc should be zero-arity and call reader methods (`if: -> { data.present? }`). Inside a Proc, method calls resolve to the action, but `self` is a validation-internal object — instance variables will not resolve; use readers.
- **Conditions must be cheap and side-effect-free**: a declaration-level condition may be evaluated once *per validator* on the field during a single validation pass.
- Combining a tolerance flag (`optional:`/`allow_nil:`/`allow_blank:`) with an explicit `presence:` raises at declaration — the tolerance would make the presence check unable to fire. `allow_empty:` raises alongside an explicit `presence:` only when the two **disagree** about emptiness (`presence: true` with `allow_empty: true`, or `presence: false` with `allow_empty: false`); agreeing spellings are redundant but legal.
- Shape-block members (`field :x` inside `do … end`) support `if:`/`unless:` too, with the same action-scoped semantics — the condition resolves against the action, **not** the element being validated (a condition cannot reference sibling members). This also means Symbol validator arguments (e.g. `inclusion: { in: :allowed_statuses }`) now resolve on members.

::: warning Schema reflection advertises the maximal contract
`input_schema` never executes conditions. It reflects every conditional field **as if every gate were open** — `if:` treated as true, `unless:` treated as false, every declared validator counted — so the schema may be *stricter* than the runtime (it can tell a caller a field is required when a closed gate would have accepted omission), but never looser. One narrow, documented exception: a gated required subfield whose condition does not reference its own parent's presence — omitting the parent while the condition is true passes the schema but fails at runtime with a normal validation error (the canonical `if: -> { parent.present? }` pattern is exact). Two refinements: a Symbol condition referencing a declared sibling field (like `if: :promo_enabled?` above) is emitted *exactly*, as a JSON Schema `allOf`/`if`/`then` conditional instead of an unconditional requirement; and a gated required subfield keeps its nested `required` without forcing its ancestors, so the parent's own declared optionality is honored. On `output_schema`, a gated exposed field is left untyped (a closed gate skips every validator, so the action can expose whatever it assigned — no type is assertable).
:::

Axn has **no validation contexts.** ActiveModel lets a model gate a validator on a context (`record.valid?(:create)` against `validates … on: :create`), but axn validates with no context at all, so a validator carrying `on:` would never run on any call. Rather than accept a check that silently enforces nothing, axn refuses the declaration:

```ruby
expects :v, type: { klass: String, on: :create }
# => ArgumentError: `on:` inside type: on ["v"] names an ActiveModel validation context, and axn validates
#    with no context — so that check runs on no call and the declaration is left unenforced.
```

Use `if:`/`unless:` to gate a check instead. The same rejection covers a shape member's own `on:`, and `on:` on an `exposes`.

Note that this is only about `on:` **inside a validator's options.** A declaration-level `on:` on `expects` is a completely different option — it is axn's [subfield parent](#nested-subfield-expectations) (`expects :zip, on: :address`) — and is unaffected.
#### Confirmation pairs (`confirmation:`) {#confirmation}

`confirmation: true` declares a **companion input** alongside the field and fails unless the two match — the password/password-confirmation pattern, as one line.

```ruby
expects :password, type: String, sensitive: true, confirmation: true
# also accepts `password_confirmation`; you do not declare it yourself
```

**What the companion inherits.** `type:`, `coerce:`, `preprocess:`, `method_call:`, `user_facing:` and `sensitive:` all carry over, so redaction and caller-facing errors treat `password_confirmation` exactly as they treat `password`. `default:` deliberately does not: a defaulted companion would produce and then match its own value, quietly passing a confirmation nobody supplied. Neither do `shape:`, `of:` or `inclusion:` — the companion is checked for equality against the base, and a value equal to one that already satisfies those constraints satisfies them too.

**When it is required.** Exactly when the base field is present. Send `password` without its confirmation and the call fails; send neither and it passes, because there is nothing to confirm. A companion you *do* supply is always compared, whatever the base holds — a blank or `nil` base is still a value a mismatched companion contradicts. Anything that stops the comparison from running also stops the requirement: an `if:`/`unless:` on the declaration or on the entry itself (`confirmation: { if: :admin }`), and an `allow_blank:` on the entry for a blank base.

**A base with a `default:` is always present**, so its companion is always required — and since `default:` is not inherited, the schema never shows the default's value. The only passing call supplies a confirmation equal to whatever that default happens to be.

**The companion's reader.** You get `password_confirmation`, or `<base reader>_confirmation` when the base is aliased (`as: :pw` reads as `pw_confirmation`). That reader is inferred rather than declared, so it defers: if you wrote a method of that name, or another declaration's `as:` claims it, yours stands and the companion goes without one. Validation, redaction and reflection are unaffected — a companion without a reader is enforced against the wire value directly, so a method you wrote can never stand in for the input the pair requires. A reader name belongs to whichever declaration answers to it, so everything that names a reader follows that declaration rather than the companion that yielded — an `on:` parent, and a Symbol `if:`/`unless:` gate, in the emitted schema as at run time. That holds wherever the two sit relative to each other: which declaration owns a name is settled across the whole contract, not at the point each line is read.

**Declaring the companion yourself** overrides the implicit one, so `expects :password_confirmation, type: String, optional: true` alongside the base gives it whatever contract you want. The implicit version only fills in when you have not.

**Not supported** on `exposes` (there is no caller input to confirm an output against) or on a shape block's `field` (a member has no reader for a companion to attach to). Both raise at declaration.

::: warning This departs from ActiveModel on purpose
ActiveModel skips the comparison whenever the confirmation accessor reads `nil`, so an omitted `password_confirmation` silently passes there. That default fits ActiveModel's situation rather than axn's: its confirmation attribute is a virtual accessor on a persistent record, reading `nil` on every save that does not touch the field — failing on `nil` would break `user.update(name: "x")` until someone re-typed the password, which is why [the Rails guides](https://guides.rubyonrails.org/active_record_validations.html#confirmation) tell you to add a `presence` check by hand. An axn call carries no such history: one inbound message, validated once. So the presence check is built in rather than left as a footnote.
:::

### Details specific to `.exposes`

For fields you declare via `exposes`, you'll need [a corresponding `expose` call](/reference/instance#expose) — unless the field is also declared via `expects`, in which case axn auto-copies it from the input into the result on all outcome paths (success, `fail!`, and exception). See [Re-exposing an expected field](/usage/writing#re-exposing-an-expected-field-auto-copy).


### Details specific to `.expects`

#### `user_facing:` — surface a violation to the caller

By default a failed `expects` validation is **dev-facing**: it lands in the exception bucket, pages the global handler, and `result.error` is the generic `"Something went wrong"`. Mark a field `user_facing:` and a violation of it settles as a **failure** instead — firing `on_failure`, skipping the global report, and surfacing a meaningful message on `result.error`:

```ruby
expects :note, user_facing: true            # surfaces the field's own message ("Note can't be blank")
expects :note, user_facing: "Add a note"    # override the surfaced message
expects :note, user_facing: :note_message   # call an action method to compute it
expects :note, user_facing: ->(e) { ... }   # compute it from the InboundValidationError
```

The value matches the `error`/`fail!`/`fails_on` handler shape — `true`, a String, a Symbol naming an action method, or a Proc; one that resolves blank falls back to the field's own validation message. The surfaced message is a failure **reason**, so a declared base `error` [attaches it under the base](/usage/writing#prefixing-failure-reasons) by default (standalone with no base), just like a `fail!` message. The field stays **required** (unlike `optional:`, which removes the check) — `user_facing:` changes who is blamed for a violation, not whether it's validated. In a mixed failure (a `user_facing:` field *and* a plain one both invalid), the dev-facing one dominates and the call still pages. `user_facing:` works at **any depth**: on a subfield (`on:`), classification follows the subfield's own declaration, and on a parent whose subfields fail *because the parent itself* failed, those stranded checks are attributed to the parent rather than paging over its user-facing message. Any dev-facing violation anywhere still dominates a mixed failure. `user_facing:` composes at shape depth too: a shape-carrying field's own errors (its presence/type check, independent of its members) honor the field's own `user_facing:`, and a shape member may itself opt into `user_facing:` (defaulting dev-facing) with the same `true`/String/Symbol/Proc parity a field has. One exception remains a declaration error: an ambient_context subfield is framework-supplied — there is no user to face. See [the narrative](/usage/writing#user-facing-contract-violations) for the full picture.

#### Nested/Subfield expectations

`expects` is for defining the inbound interface. Usually it's enough to declare the top-level fields you receive, but sometimes you want to make expectations about the shape of that data, and/or to define easy accessor methods for deeply nested fields. `expects` supports the `on` option for this (all the normal attributes can be applied as well):

```ruby
class Foo
  expects :event
  expects :data, type: Hash, on: :event  # [!code focus:2]
  expects :some, :random, :fields, on: :data
  expects :optional_field, on: :data, default: "default value"  # [!code focus]

  def call
    puts "THe event.data.random field's value is: #{random}"
  end
end
```

::: tip Subfield Defaults
Defaults work the same way for subfields as they do for top-level fields - they are applied when the subfield is missing or explicitly `nil`, but not for blank values.
The default is resolved at the **value** level, when the subfield is read: the reader and validation see it, but it is never written back into the parent. axn never mutates or materializes a caller-supplied object (or Hash) to apply a subfield default — the parent reader returns exactly what the caller passed, and the child reader returns the default. A subfield default therefore fixes the child's own `nil`; it does not satisfy the parent's own validations (a required parent given `{}` or omitted still fails its own presence — a child default no longer launders it non-blank).
:::

#### Reaching into nested parents

`on:` accepts a **dotted path** — this is the tool for pulling a single deeply-nested value out of a big provided hash, declaring it (and validating it) as a flat field with a clean reader named after the leaf:

```ruby
expects :address, type: Hash
expects :zip, on: "address.billing", type: String  # validates address[:billing][:zip]; defines a `zip` reader
```

Now `zip` reads `address[:billing][:zip]` directly — you name only the leaf you care about, not every intermediate. The **root** segment (`address`) must be a declared field (or subfield); the dots after it name intermediate keys that need no declaration of their own. Resolution is canonical: the chain resolves through the deepest *declared* ancestor's reader (so `on: "payload.company"` where `:company` is a `model:` subfield sees the resolved record, exactly like `on: :company`), and only undeclared intermediate segments are dug as plain hashes. Nested keys are read indifferently: a parent holding either symbol or string keys resolves the same (symbol keys are checked first). A dotted tail addresses the wire **node**, not a route to it — so where the same wire key was declared twice (two spellings of one route, distinguishable only by `as:`), a dotted reference through it names neither and is refused at declaration. Anchor on the route you mean instead (`on: :<that route's reader>`).

The field name is always a single key; the path lives entirely in `on:`. (A dotted field *name* — `expects "billing.zip", on: :address` — is not valid; write the leaf as the name and the path in `on:`.)

::: info Nested parents support the full kwarg surface
`default:`, `preprocess:`, and `sensitive:` work on a **nested** parent too — whether reached via a dotted path (`on: "address.billing"`) or by pointing `on:` at another subfield. `default:` and `preprocess:` resolve on the **read path**, when the subfield is read: a nested `default:` returns the declared value for a missing/`nil` leaf, and a nested `preprocess:` transforms the resolved value. Neither materializes intermediate objects nor writes into the parent — the parent reader returns exactly what the caller passed, while the subfield's own reader (named after its leaf, or an `as:` alias) returns the transformed value. A nested `sensitive:` is **not** part of that read: it resolves only when something requests redaction — logging, `inspect`, or an error report — and then filters its full nested path from that output. An ambient parent (`on: :ambient_context`) supports `default:`/`preprocess:`/`coerce:` the same way — they resolve on the read path against the framework-supplied value; only `user_facing:` stays unsupported there (see below).
:::

#### Ambient context (`on: :ambient_context`)

`ambient_context` is a reserved, always-present parent whose subfield values are supplied **per-invocation by the framework** rather than by the caller's arguments. It's how an action declares a dependency on ambient request/tenant state — the current company, the acting user, a request id — as an explicit part of its contract:

```ruby
class ChargeCard
  include Axn
  expects :company, on: :ambient_context, model: Company   # framework-supplied, not a caller argument
  expects :actor,   on: :ambient_context, model: User

  def call = do_thing(company, actor)   # `company` / `actor` read like any other declared input
end
```

Each declared ambient subfield resolves from the first source that provides it, checked in order:

1. an explicit `ambient_context:` kwarg on the call (`ChargeCard.call(ambient_context: { company_id: 7 })`) — an explicit kwarg **replaces** the provider entirely (no merge), so passing `ambient_context: {}` or `nil` deliberately supplies nothing;
2. otherwise the configured `Axn.config.ambient_context_provider` (a callable returning a Hash);
3. otherwise, in a Rails app, a live view over every registered `ActiveSupport::CurrentAttributes`;
4. otherwise `{}`.

Whatever the source, the hash is **filtered to the declared ambient subfields, along their declared paths** — only keys you declared survive, so ambient state never carries a process-wide dump of `Current` into logs or exception context. Ambient subfields are validated like any other input (a required one that resolves absent fails the call) but are deliberately excluded from `input_schema` (they're framework-supplied, never client input).

::: tip Declare the dependency — don't reach into `Current` directly
Prefer `expects :company, on: :ambient_context` over reading `Current.company` inside `call`. A declared ambient subfield is visible in the contract (a caller can see what ambient state the action needs), is validated and sensitive-filtered, and is trivially driven in tests by passing `ambient_context:` (or the [`with_ambient_context`](/recipes/testing#ambient-context) helper) — no `CurrentAttributes` setup. Reading `Current` directly hides all of that. The optional [`Axn/AmbientContextBypass`](/recipes/rubocop-integration#axn-ambientcontextbypass) RuboCop cop flags a direct `Current.<attr>` read inside an Axn and points at the `on: :ambient_context` fix.
:::

Ambient subfields **nest to any depth**, exactly like a non-ambient parent — the source can be a nested object and subfields reach into it:

```ruby
expects :request, on: :ambient_context, type: Hash
expects :ip,      on: :request, type: String   # resolves ambient_context[:request][:ip]

# equivalently, without the intermediate reader:
expects :ip, on: "ambient_context.request", type: String
```

The filter reconstructs only the declared leaves along their paths, never a whole sub-hash — so an undeclared sibling at any depth (`request[:token]` when only `request[:ip]` is declared) never reaches the resolved value, logs, or exception context. `sensitive:` composes down the path (mark a nested leaf, or an ancestor, and the reconstructed nested value is filtered). `default:`, `preprocess:`, and `coerce:` are supported on any ambient subfield (nested or not) — they resolve on the read path against the framework-supplied value, exactly as for every other subfield. A `shape:` block is supported on an ambient subfield the filter copies whole — one with no nested subfields, or a `model:` node (whose children read off the resolved record): the shape validates against that copied value. A non-`model:` shape node that also declares nested subfields is rejected at declaration — declare the nested structure one way, either the `shape:` (validation only) or subfields (`expects :ip, on: :request`, which also give readers and `sensitive:`). `user_facing:` is **not** supported on an ambient subfield, including on a shape member (rejected at declaration): an ambient value is framework-supplied, so there is no caller to face.

#### Resolving a subfield by calling a method (`method_call:`)

By default a subfield is resolved by reading **declared data** off its parent: a Hash key, or a `Struct`/`OpenStruct`/`Data` member. That's the safe path, and it's all you need for the usual case of reaching into a nested payload.

Sometimes the value you want isn't stored data but the result of **invoking a method** on the parent — an `Array` method (`items.count`), a plain object's reader (`event.data`), a `Data` object's computed method, or an attribute off a resolved `model:` record (`company.name`). Because invoking an arbitrary method can have side effects (and resolution runs during inbound validation), and because a method result has no JSON-schema representation, this is opt-in: declare `method_call: true`.

```ruby
expects :event
expects :data, on: :event, method_call: true            # invokes event.data (a reader, not a key)

expects :payload, type: Hash
expects :count, on: "payload.items", type: Integer, as: :item_count, method_call: true  # invokes Array#count

expects :company, model: Company
expects :name, on: :company, method_call: true          # invokes company.name off the resolved record
```

Note the last example: reaching into a resolved `model:` record reads its attributes **by invoking methods**, so it needs `method_call: true` too — a record from a finder can expose computed or side-effecting readers just like any other object, so it isn't treated as automatically safe.

Reaching a method-dispatch segment **without** `method_call: true` raises `Axn::ContractViolation::MethodCallNotPermittedError`. It settles as a bug (fires the global `on_exception`; `result.error` shows the generic headline) with the actionable fix — the field, the parent's runtime class, and "add `method_call: true`" — on the exception's own message. This is deliberately loud: it is never silently treated as an absent value.

`method_call:` is a per-declaration property, so it's only valid on a subfield (a declaration with `on:`). It composes with `default:` — the method is invoked and a `nil` result falls back to the declared default (a value-level default, resolved on read). `preprocess:` and `coerce:` compose with `method_call:` — the method is invoked and its result is coerced then preprocessed (the same order as a top-level field), all on the read path.

`method_call: true` means "permit dispatch resolving this expectation" **uniformly across its path** — so a single dotted-`on:` declaration whose intermediate must be method-dispatched works in one line:

```ruby
expects :event
expects :name, on: "event.data", method_call: true   # event.data (a method) → Hash; [:name] read as a key
```

Here the implicit `data` hop is method-dispatched (honoring the declaration's flag) and the `name` leaf is read as a plain key. An **explicitly declared** intermediate keeps its own flag — a child opting in never makes its parent dispatch — so declaring `expects :data, on: :event` (no flag) leaves `data` key-access-only even if a subfield beneath it sets `method_call: true`.

::: tip The DRY idiom for reading many leaves off a method-resolved object
When you need several values off the same method-resolved object (a PORO, a `model:` record), declare that hop **once** with `method_call: true`, then read its leaves with plain key access — no per-leaf flag:

```ruby
expects :event
expects :data, on: :event, method_call: true   # invoke event.data once → a Hash
expects :name, on: :data, type: String         # plain key reads off the resolved Hash
expects :role, on: :data, type: String, default: "member"
```

The flat one-line spelling above is best for pulling a *single* leaf through a method intermediate; declaring the object hop once is best when you want *many* leaves off it.
:::

#### Subfield readers always generate

Every subfield defines a top-level reader method (e.g., `random` in the example above). When a sub-key's name would collide with an existing reader, rename it with `as:`/`prefix:` (below) so both values stay reachable.

#### Renaming the reader (`as:` / `prefix:`)

By default the generated reader is named after the field — `expects :channel` defines a `channel` reader. Use `as:` to give the reader a different name while keeping `channel` as the caller-facing contract. The most common motivation is freeing the field's name so you can define your own method on top of the raw input:

```ruby
expects :channel, as: :raw_channel              # caller still passes `channel:`
def channel = @channel ||= Channel.find(raw_channel)
```

The wire key stays canonical everywhere caller-facing — validation messages, required-inputs, logging, and sensitive-field filtering all still key off `channel`. Only the in-action reader (and its `?` predicate) is renamed.

`as:` applies to a single field. For subfields it's especially handy to disambiguate or namespace unwrapped values; `prefix:` is sugar that renames several at once (literal concatenation, so you supply the separator):

```ruby
expects :event_params, type: Hash
expects :id, on: :event_params, as: :event_id           # reader: event_id (extracts `id`)
expects :id, :type, on: :event_params, prefix: :event_  # readers: event_id, event_type
```

`as:` and `prefix:` cannot be combined (raises at declaration). A renamed reader must clear the same reserved-name bar as a field and can't collide with another reader — which is how you disambiguate two subfields that share a leaf key (e.g. `zip` under both `billing` and `shipping`, or two routes converging on one wire path): give each a distinct `as:`. Renaming composes with `model:` — the model is resolved (including the `<field>_id` lookup) against the wire key and exposed under the aliased reader. Neither value may be dotted (a reader name must name a method, and a dotted `prefix:` composes one that doesn't), and each must be a String or Symbol in an ASCII-compatible encoding — see [the name rules](#property-name-rules). Every spelling of absence (`nil`, `false`, an empty or whitespace-only String, the empty Symbol) means "no rename". Two fields under the same parent — or two top-level fields — may not **share a wire key**, and may not carry two names that **render as the same JSON property** (`:café` spelled in UTF-8 and in ISO-8859-1 are one property); a name whose bytes have no UTF-8 rendering at all is refused as a property name too. Both rules, and exactly when each raises, are in [Names that one JSON property can't keep apart](#property-name-rules).

When you declare subfields `on:` a renamed parent, reference it by its **reader name** (the alias), not the wire key — `on:` is resolved by calling the parent's reader:

```ruby
expects :channel, type: Hash, as: :raw_channel
expects :id, on: :raw_channel    # ✅ reader name;  on: :channel would raise (no `channel` reader)
```

#### `preprocess`
`expects` also supports a `preprocess` option that, if set to a callable, will be executed _before_ applying any defaults or validations. Use it for a custom, field-specific transform. For the common case of turning a wire string into a Ruby type (`Date`/`Symbol`/…), prefer `coerce:` (below), which is the shared, standard inverse of the output serializer. If the preprocess callable raises an exception, that'll be swallowed and the action failed.

#### `coerce`
`expects` supports a `coerce:` option that parses an inbound wire string into its declared Ruby type _before_ your `preprocess`, defaults, and validation run — the inbound inverse of how a `Date`/`Symbol` result serializes on the way out. This closes the round-trip gap: a JSON client (or a Rails form) sending `"2026-07-08"` or `"active"` is accepted for a `Date`/`Symbol` field, rather than rejected for not already being the Ruby object.

```ruby
expects :on, coerce: Date                          # "2026-07-08"  → Date
expects :mode, coerce: Symbol, inclusion: { in: %i[a b] }  # "a" → :a, then validated
expects :count, coerce: Integer                    # "123" → 123 (base 10)
expects :active, coerce: :boolean                  # "true"/"on"/"1"/1 → true; "false"/"0"/0 → false
expects :on, type: { klass: Date, coerce: true }   # explicit form (use with sibling type options like message:)
expects :on, coerce: [Date, String]                # union: parse a date if possible, else keep the string
```

The supported types are `Date`, `DateTime`, `Time`, `Symbol`, `Integer`, `Float`, and `:boolean`. Coercion is **coerce-or-leave**: only strings are transformed (a value already of the right type, or a JSON-native number, is untouched; a blank string is left as-is so presence validation still applies), and an unparseable string passes through to a normal validation error (reported as "could not be coerced to a Date", distinct from a wrong-type "is not a Date"). `coerce:` is opt-in per field, so a direct Ruby caller's strictness is unchanged. It works on top-level `expects` fields and subfields (`on:`) alike, including ambient_context subfields (the coerced value is what the reader and validation see).

`:boolean` accepts the case-insensitive strings `1/true/t/yes/y/on` and `0/false/f/no/n/off`, plus the integers `1`/`0` (the one type that also coerces a non-string wire form). Both sides are an explicit allowlist — an unrecognized value (`"maybe"`, `2`) is left uncoerced and fails validation rather than silently becoming `true`.

Date/time coercion accepts any **ISO-8601-shaped** wire string — a `YYYY-MM-DD` date optionally followed by a time (`T` or space separator, optional seconds/fraction, optional `Z`/`±HH:MM` offset). That covers JSON/RFC3339 timestamps, a Rails `date_field` (`2026-07-08`), a `datetime-local` (`2026-07-08T14:30`, no offset — read in the local zone), and Rails' `Time#to_s` (`2026-07-08 14:30:00 +0000`). Ambiguous or partial input that Ruby's `Date.parse`/`Time.parse` would otherwise guess against today's date (`"12"`, `"01/02/2026"`, a bare `14:30` time) is left uncoerced and fails validation rather than becoming a silently-wrong value.

##### Coercing a whole action: `coerce_input_types`

Per-field `coerce:` is the right tool for a single wire-shaped field. For an action that is _entirely_ transport-facing — a controller handing it a params hash of strings, an adapter decoding JSON — annotating every field is noise. The `coerce_input_types` config setting declares "treat all inbound values here as wire data": when on, every field with a coercible declared type behaves as if it set `coerce: true`.

```ruby
# Whole app (a consumer's informed choice — e.g. a pure-API service):
Axn.config.coerce_input_types = true

# One action (or a base class its controller-facing actions inherit):
class CreateThing
  include Axn
  configure { |c| c.coerce_input_types = true }
  expects :starts_on, type: Date   # "2026-07-08" is now coerced, no per-field coerce:
end
```

The default is **off** (`false`), and deliberately so: `type: Date` is a contract assertion, and a string where a `Date` is declared is usually a bug for an in-process Ruby caller — coercing it globally by default would mask that. You opt in where you know the input crossed a wire.

A field's own `coerce:` always wins over the flag, so a mixed action can opt one field back out with the explicit form:

```ruby
class ImportRow
  include Axn
  configure { |c| c.coerce_input_types = true }
  expects :on, type: Date                          # coerced
  expects :raw, type: { klass: Date, coerce: false }  # left strict despite the flag
end
```

Scope matches `coerce:` itself — top-level fields **and subfields** (non-coercible types like `String`/`Hash` are untouched either way), with each field's own tri-state `coerce:` flag still winning over the action-wide setting.

## `.success` and `.error`

The `success` and `error` declarations allow you to customize the `error` and `success` messages on the returned result.

Both methods accept a string (returned directly), a symbol (resolved as a local instance method on the action), or a block (evaluated in the action's context, so can access instance methods and variables).

When an exception is available (e.g., during `error`), handlers can receive it in either of two equivalent ways:
- Keyword form: accept `exception:` and it will be passed as a keyword
- Positional form: if the handler accepts a single positional argument, it will be passed positionally

This applies to both blocks and symbol-backed instance methods. Choose the style that best fits your codebase (clarity vs concision).

In callables and symbol-backed methods, you can access:
- **Input data**: Use field names directly (e.g., `name`)
- **Output data**: Use `result.field` pattern (e.g., `result.greeting`)
- **Instance methods and variables**: Direct access

```ruby
success { "Hello #{name}, your greeting: #{result.greeting}" }
error { |e| "Bad news: #{e.message}" }
error { |exception:| "Bad news: #{exception.message}" }

# Using symbol method names
success :build_success_message
error :build_error_message

def build_success_message
  "Hello #{name}, your greeting: #{result.greeting}"
end

def build_error_message(e)
  "Bad news: #{e.message}"
end

def build_error_message(exception:)
  "Bad news: #{exception.message}"
end
```

## Message Matching Order {#message-matching-order}

Messages follow the [base/reason model](/usage/writing#prefixing-failure-reasons): an **unconditional** `error`/`success` (literal or block) is the **base headline**, while a **conditional** (`if:`/`unless:`) or explicitly `standalone: false` entry is a **reason**. Resolution shows the most-recently-declared matching *reason* (attached under the base), or — when none matches — the base headline, or finally the generic default.

### How It Works

1. Entries are stored **last-defined-first** and evaluated in that order.
2. The displayed message is the first matching **reason** (a conditional or `standalone: false` entry), attached under the base.
3. If no reason matches, the **base headline** is shown — it's found by shape, so **its declaration position doesn't matter**.
4. Among multiple reasons that could match (or multiple unconditional headlines), the **most-recently declared wins** — so declare the most-specific reasons last.

### The base's position doesn't matter

Because the base is identified by shape, matching reasons are attached under it no matter where it's declared — there is no "shadowing" to avoid (declaring it last is fine):

```ruby
class MyAction
  include Axn

  error "Invalid input provided", if: ArgumentError
  error "Record not found", if: ActiveRecord::RecordNotFound
  error "Something went wrong"   # the base — position-independent
end

# ArgumentError raised => "Something went wrong: Invalid input provided"
# unmatched exception   => "Something went wrong"  (base alone)
```

### With Inheritance

Child class entries are evaluated before parent class entries, so a child's headline (or matching reason) wins over the parent's:

```ruby
class ParentAction
  include Axn
  error "Parent error"
end

class ChildAction < ParentAction
  error "Child error"   # wins — child is evaluated first
end
```

## Conditional messages

While `.error` and `.success` set the default messages, you can register conditional messages using an optional `if:` or `unless:` matcher. The matcher can be:

- an exception class (e.g., `ArgumentError`)
- a class name string (e.g., `"Axn::InboundValidationError"`)
- a symbol referencing a local instance method predicate (arity 0 or 1, or keyword `exception:`), e.g. `:bad_input?`
- a callable (arity 0 or 1, or keyword `exception:`)

Symbols are resolved as methods on the action instance. If the method accepts `exception:` it will be passed as a keyword; otherwise, if it accepts one positional argument, the raised exception is passed positionally; otherwise it is called with no arguments. If the action does not respond to the symbol, we fall back to constant lookup (e.g., `if: :ArgumentError` behaves like `if: ArgumentError`). Symbols are also supported for the message itself (e.g., `success :method_name`), resolved via the same rules.

```ruby
error "bad"

# Custom message with exception class matcher
error "Invalid params provided", if: ActiveRecord::InvalidRecord

# Custom message with callable matcher and message
error(if: ArgumentError) { |e| "Argument error: #{e.message}" }
error(if: -> { name == "bad" }) { "Bad input #{name}, result: #{result.status}" }

# Base error attaches to a conditional reason by default
error "Foo"                                    # base — never itself shown as a reason
error("bar", if: ArgumentError)                # ArgumentError => "Foo: bar"
error(if: TypeError, &:message)                # TypeError     => "Foo: <exception.message>"
# (reasons are checked last-declared-first; if two conditional reasons both match the same
#  exception, the later-declared one wins — keep their matchers disjoint to avoid surprises)

# Custom message with symbol predicate (arity 0)
error "Transient error, please retry", if: :transient_error?

def transient_error?
  # local decision based on inputs/outputs
  name == "temporary"
end

# Symbol predicate (arity 1), receives the exception
error(if: :argument_error?) { |e| "Bad argument: #{e.message}" }

def argument_error?(e)
  e.is_a?(ArgumentError)
end

# Symbol predicate (keyword), receives the exception via keyword
error(if: :argument_error_kw?) { |exception:| "Bad argument: #{exception.message}" }

def argument_error_kw?(exception:)
  exception.is_a?(ArgumentError)
end

# Lambda predicate with keyword
error "AE", if: ->(exception:) { exception.is_a?(ArgumentError) }

# Using unless: for inverse logic
error "Custom error", unless: :should_skip?

def should_skip?
  # local decision based on inputs/outputs
  name == "temporary"
end
```

::: tip Combining `if:` and `unless:`
`if:` and `unless:` may be given together on the same message; they combine with AND — the message only matches when every condition passes — the same combination rule used by [conditional steps](/usage/steps#conditional-steps) and by [conditional validation](#conditional-validation-if-unless) on field declarations. These are different mechanisms, though: a message's `if:`/`unless:` only selects which failure message renders, while a field's `if:`/`unless:` (see [Conditional validation](#conditional-validation-if-unless)) gates whether the field is validated at all.
:::

## Composing error messages across actions

Most of the time you don't need to do anything special: declare a base `error` on the parent and it attaches to the parent's own failures *and* any child failure surfaced via `call!`. A child that fails via `fail!` re-raises the same `Axn::Failure` (no wrapping), so the base is prepended automatically — see [Prefixing failure reasons](/usage/writing#prefixing-failure-reasons).

```ruby
class OuterAction
  include Axn
  error "Couldn't onboard"

  def call
    InnerAction.call!(...) # inner's fail!("email taken") surfaces as "Couldn't onboard: email taken"
  end
end
```

Reach for an explicit `call` + `fail!` only when the base headline isn't enough — specifically:

- **Per-call-site context**, when a single class-level headline can't express what you need (e.g. distinguishing two invocations of the same child). Don't also repeat the headline in the `fail!` string — a declared base already attaches to it (`"<base>: validating: …"`).

  ```ruby
  def call
    a = StepA.call(...); fail!("validating: #{a.error}") unless a.ok?
    b = StepB.call(...); fail!("charging: #{b.error}") unless b.ok?
  end
  ```

- **Absorbing an unhandled child exception** into a parent *failure* rather than letting it stay an exception. A child that fails via a raw exception (not `fail!`) re-raises *that exception* through `call!`, so the parent settles as an `exception` outcome. Its `result.error` still aggregates normally (the parent's base prefixed to the child's resolved message) — unless the parent declares its own conditional `error "…", if: SomeError` matching the bubbled exception, which *replaces* the child's presentation rather than prefixing it. An unhandled exception picks up an authored leaf only when a conditional reason matches it (reason matching is independent of `fails_on`); with no matching reason only the declared base headers chain. The raw exception `#message` stays out of `result.error` unless you opt it in explicitly with `error(if: SomeError, &:message)` or `fails_on SomeError, &:message`. Running the child with non-bang `call` and `fail!`ing on `!result.ok?` instead converts it to a `failure` outcome, and lets you author the message yourself. Either way the exception is [reported once](/usage/writing#reporting-a-nested-bug-once) — so this choice is about the **outcome**, and about authoring a message the automatic aggregation wouldn't produce.

::: tip Suppressing reports for expected failures
If an inner action raises an exception that is an expected business outcome (not a bug), declare `fails_on ExceptionClass` on the **inner** action to reclassify it into the failure bucket — it fires `on_failure`, skips `Axn.config.on_exception`, and preserves the original exception on `result.exception`. See [Suppressing reports for expected failures](/usage/writing#suppressing-reports-for-expected-failures-in-composed-actions).
:::

## `.async`

Configures the async execution behavior for the action. This determines how the action will be executed when `call_async` is called.

```ruby
class MyAction
  include Axn

  # Configure Sidekiq
  async :sidekiq do
    sidekiq_options queue: "high_priority", retry: 5, priority: 10
  end

  # Or use keyword arguments (shorthand)
  async :sidekiq, queue: "high_priority", retry: 5

  # Configure ActiveJob
  async :active_job do
    queue_as "data_processing"
    self.priority = 10
    self.wait = 5.minutes
  end

  # Disable async execution
  async false

  expects :input

  def call
    # Action logic here
  end
end
```

### Available Adapters

**`:sidekiq`** - Integrates with Sidekiq background job processing
- Supports all Sidekiq configuration options via `sidekiq_options`
- Supports keyword argument shorthand for common options (`queue`, `retry`, `priority`)

**`:active_job`** - Integrates with Rails' ActiveJob framework
- Supports all ActiveJob configuration options
- Works with any ActiveJob backend (Sidekiq, Delayed Job, etc.)

**`false`** - Disables async execution
- `call_async` will raise a `NotImplementedError`

### Inheritance

Async configuration is inherited from parent classes. Child classes can override the parent's configuration:

```ruby
class ParentAction
  include Axn

  async :sidekiq do
    sidekiq_options queue: "parent_queue"
  end
end

class ChildAction < ParentAction
  # Inherits parent's Sidekiq configuration
  # Can override with its own configuration
  async :active_job do
    queue_as "child_queue"
  end
end
```

### Default Configuration

If no async configuration is specified, the action will use the default configuration set via `Axn.config.set_default_async`. If no default is set, async execution is disabled.

## `prefer_inherited` and `prefer_axn`

`prefer_inherited(*names)` and `prefer_axn(*names)` say which implementation is live for an
instance-side sugar name (`log`, `fail!`, `result`, …) that both axn and your own class hierarchy
define — `include Axn` steps aside for your hierarchy's version by default, and these two
declarations make that explicit (`prefer_inherited`, silencing the one-time deferral warning) or
override it (`prefer_axn`, putting axn's own implementation back in front, since a bare `super`
from your own `def` reaches the inherited version either way). Both raise at declaration for a name
axn does not hand over to anyone (`call`, an axn internal, a Ruby method). Scoped to the class that
writes them — a subclass may choose differently from its parent without changing the parent's or a
sibling's behavior. See [Inheritance & Method Conflicts](/advanced/inheritance) for the full
explanation and worked examples.

## Callbacks

In addition to the [global exception handler](/reference/configuration#on-exception), a number of custom callback are available for you as well, if you want to take specific actions when a given Axn succeeds or fails.

::: tip Callback Ordering
* Callbacks are executed in **last-defined-first** order, similar to messages
* Child class callbacks execute before parent class callbacks
* Multiple matching callbacks of the same type will *all* execute
:::


::: tip Callbacks vs Hooks
  * *Hooks* (`before`/`after`) are executed _as part of the `call`_ -- exceptions or `fail!`s here _will_ change a successful action call to a failure (i.e. `result.ok?` will be false)
  * *Callbacks* (defined below) are executed _after_ the `call` -- exceptions or `fail!`s here will _not_ change `result.ok?`
:::


**Note:** Symbol method handlers for all callback types follow the same argument pattern as [message handlers](#conditional-messages):
- If the method accepts `exception:` as a keyword, the exception is passed as a keyword
- If the method accepts one positional argument, the exception is passed positionally
- Otherwise, the method is called with no arguments

::: tip Combining `if:` and `unless:`
`if:` and `unless:` may be given together on the same callback; they combine with AND — the callback only fires when every condition passes — the same combination rule used by [messages](#conditional-messages), [conditional steps](/usage/steps#conditional-steps), and [conditional validation](#conditional-validation-if-unless) on field declarations.
:::

### `on_success`

This is triggered after the Axn completes successfully, once the enclosing database transaction has committed (immediately if none is open); it is skipped if that transaction rolls back. Nested `on_success` callbacks fire child-first (inner before outer). Difference from `after`: if the given block raises an error, this WILL be reported to the global exception handler, but will NOT change `ok?` to false.

### `on_error`

Triggered on ANY error (explicit `fail!` or uncaught exception). Optional filter argument works the same as `on_exception` (documented below).

`on_error` is a superset of `on_failure` and `on_exception`, so it co-fires with whichever specific bucket applies: a `fail!` triggers both `on_error` and `on_failure`, and an uncaught exception triggers both `on_error` and `on_exception`. If you register `on_error` alongside the specific callback, expect both to run — they are not mutually exclusive.

### `on_failure`

Triggered ONLY on explicit `fail!` (i.e. _not_ by an uncaught exception). Optional filter argument works the same as `on_exception` (documented below).

### `on_exception`

Much like the [globally-configured on_exception hook](/reference/configuration#on-exception), you can also specify exception handlers for a _specific_ Axn class:

```ruby
class Foo
  include Axn

  on_exception do |exception| # [!code focus:3]
    # e.g. trigger a slack error
  end
end
```

Note that by default the `on_exception` block will be applied to _any_ `StandardError` that is raised, but you can specify a matcher using the same logic as for conditional messages (`if:` or `unless:`):

::: tip Exceptions outside `StandardError`
Two families outside `StandardError` are still bugs, and are treated as such: **`SystemStackError`** (runaway recursion) and **`ScriptError`** (`NotImplementedError`, `LoadError`, `SyntaxError`). Either settles as an `exception` outcome that `call` returns like any other, with `on_error` and `on_exception` firing and the global handler notified; `call!` raises it, as always.

Every *other* exception outside `StandardError` passes straight through untouched — no outcome, no callbacks, no report, and no *completion* log line (the "About to execute" line is already out before your `call` runs, so `auto_log` still emits that one) — raised from `call` as well as `call!`. Signals and `exit` mean the process is going away, `Timeout::ExitException` must reach the enclosing `Timeout.timeout` intact for the timeout to fire, and any library may define its own control-flow signal as a direct `Exception` subclass. Since that set is open-ended, axn names what it swallows rather than what it lets through. See [what `call` can still raise](/usage/using#common-case).
:::

```ruby
class Foo
  include Axn

  on_exception(if: NoMethodError) do |exception| # [!code focus]
    # e.g. trigger a slack error
  end

on_exception(unless: :transient_error?) do |exception| # [!code focus]
    # e.g. trigger a slack error for non-transient errors
  end

def transient_error?
  # local decision based on inputs/outputs
  name == "temporary"
end

  on_exception(if: ->(e) { e.is_a?(ZeroDivisionError) }) do # [!code focus]
    # e.g. trigger a slack error
  end
end
```


If multiple `on_exception` handlers are provided, ALL that match the raised exception will be triggered in the order provided.

The _global_ handler will be triggered _after_ all class-specific handlers.

## `.fails_on`

`fails_on` reclassifies the listed exception classes from the **exception** outcome into the **failure** outcome: a matching raised exception settles as a failed result (firing `on_failure`, **not** `on_exception`, and skipping the global `on_exception` report) while the original exception is preserved on `result.exception` so the normal `error` message resolution still applies. It does not wrap the exception in `Axn::Failure`.

```ruby
class SubmitOrder
  include Axn

  fails_on ActiveRecord::RecordInvalid                          # default message
  # fails_on ActiveRecord::RecordInvalid, "Unable to submit"    # positional string
  # fails_on(ActiveRecord::RecordInvalid) { |e| e.message }     # block (receives the exception)
  # fails_on [RecordInvalid, RecordNotUnique], "Couldn't save"
  # fails_on RecordInvalid, "Unable to submit", standalone: true # message replaces the base headline

  def call = order.save!
end
```

Reclassification only means anything for an exception axn settles onto a result. A signal, an `exit`, `NoMemoryError`, and a library's own control-flow signal are [raised straight through `.call`](/usage/using#common-case) and never reach classification, so naming one here would be inert — it **raises `ArgumentError` at class definition** instead of silently doing nothing. (`fails_on Exception` is still accepted.)

Signature: `fails_on(exceptions, message = nil, standalone: nil, &block)` — `exceptions` is an Exception class or array of classes; the optional message/block is wired through the [`error`](#message-matching-order) DSL (so it composes with base/reason attachment and ordering). `standalone:` is forwarded to that wired `error`: omitted (the default) the message attaches as a reason under any declared base `error`; `standalone: true` makes it replace the base headline instead — the same knob [`error`](#message-matching-order) itself exposes. Because it only configures the wired message, passing `standalone:` (`true` or `false`) without a message/block raises at declaration rather than silently doing nothing. See [Reclassifying exceptions as failures](/usage/writing#reclassifying-exceptions-as-failures) for the full explanation.

## Contract reflection (`.input_schema` / `.output_schema`)

`.input_schema` and `.output_schema` return [JSON Schema](https://json-schema.org/) Hashes derived from your `expects`/`exposes` declarations — the lingua franca that OpenAPI, MCP `inputSchema`, and LLM function-calling `parameters` all speak. Paired with `Axn::Extensions::Serialization.render(result)` (which renders a result to a JSON-safe Hash), this is the groundwork for exposing any Axn as a callable tool. Both methods are read-only and **off the execution path** — reflecting an Axn never instantiates it, runs its validators, or executes any of your code. (One deliberate exception: `input_schema` logs a single diagnostic warning per class when it omits a deep subfield that has no JSON-object representation — see below — writing only to the configured logger.)

```ruby
class FindWidget
  include Axn
  expects :id, type: :uuid
  expects :verbose, type: :boolean, default: false
  exposes :widget, type: Hash
end

FindWidget.input_schema
#=> { type: "object",
#     properties: { id: { type: "string", format: "uuid", minLength: 1 },
#                   verbose: { type: "boolean", default: false } },
#     required: ["id"] }   # `verbose` is optional — it has a default
```

A field is marked `required` unless a **declared signal** says it may be omitted: a usable `default:` (present, and not blank — a `default: {}`/`""` can't satisfy the field's presence, so it stays required), or a nil/blank-tolerant declaration (`optional:` / `allow_nil:` / `allow_blank:`). `presence: false` alone does **not** make a typed field omittable — it only drops the presence (blank) check, leaving the type check to still reject `nil`; combine it with a tolerance flag (or use `optional:`/`allow_nil:` directly) to actually permit omission. Every `exposes` field is `required` in `output_schema` (the serializer always emits every key; nullability is carried by the property's `type`, e.g. `["string", "null"]`).

::: warning Requiredness is advisory, not a runtime guarantee
To keep reflection cheap and free of running your code, the schema is built from your **declarations**, not by test-running your validators against each default. In these narrow cases the reflected `required` can therefore disagree with what `Axn.call` actually accepts:

- a **non-blank but invalid default** (e.g. `expects :name, type: String, default: 123`) is reflected as optional, but omitting it still fails validation at runtime — a self-contradictory contract;
- a **`do…end` shape member under a nil-tolerant parent that carries its own object default** (e.g. `expects :payload, type: Hash, allow_nil: true, default: -> { {} }` with a required member): strict reflection ignores a `Proc` default, so it reflects the parent as nullable/omittable, but at runtime the Proc fills `{}` and the required member is then enforced, so the omitted/`nil` call fails.

These surface as ordinary, recoverable validation errors (a tool client simply gets a failed result and can retry). Give the default a valid value, or send the parent explicitly, and the schema and runtime agree.
:::

### Names that one JSON property can't keep apart {#property-name-rules}

Before any of this, a name has to **be** a name, which every option that carries one is held to at class definition. It must be a **String or a Symbol** — those are the only two types whose `to_s` and `to_sym` are each other's inverse, so they are the only values with one name to canonicalize to — and it must be written in an **ASCII-compatible encoding**. This covers the names `expects`/`exposes` take, `as:`, `prefix:`, a subfield's `on:`, and `Axn::Factory.build`'s `expose_return_as:`; anything else raises an `ArgumentError` naming the option and the offending class rather than whatever the value's own `to_sym` happened to raise. The optional ones (everything but a field name) run their absent check first, so every spelling of "not supplied" — `nil`, `false`, an empty or whitespace-only String, the empty Symbol — still means the option was omitted; a field name is never optional, so `expects nil` names no field and raises. The encoding rule is not a UTF-8 rule: a Latin-N name is ASCII-compatible and legal, while a wide encoding (UTF-16, UTF-32) interns to a different Symbol than the UTF-8 property it renders as, so nothing a caller sends could ever match it.

A declared name becomes a JSON **property** name — in `input_schema`/`output_schema`, and in a result rendered by `Axn::Extensions::Serialization.render` — so two further rules apply to every name axn can emit.

1. **It must have a UTF-8 rendering.** JSON is a UTF-8 format, so a Symbol holding bytes that don't convert has no property name at all, and `JSON.generate` refuses it outright.
2. **It must not collapse onto a property another declared name already renders as.** `:café` spelled in UTF-8 and the same word spelled in ISO-8859-1 are two different Symbols and one property; emitting it twice silently drops one of the two.

Six things name a property at a node, and each is judged against all the others: a **top-level field**; a **subfield leaf** at its *resolved* parent; a **shape member** at any depth; a `model:`-generated **`<field>_id`**; a **nested key** a dotted `on:` introduces; and the **members of a structured type** declared alongside a shape (a `Data` field's own members, or an `of:` element type's inside `items`).

One wire slot named twice by the **same spelling** is a merge, not a collision — two routes to one node, a shape member and a subfield of one name, a generated `<field>_id` and an explicitly declared one — and still emits exactly one property. Only two *different* spellings that render alike are rejected, and the error names both spellings and the property they collapse to.

**When a rule fires** depends on what can see the defect: what your declarations alone settle raises at class definition, while what only the built schema reveals raises the first time a projection is demanded (`input_schema`, `output_schema`, `render`) — and at app setup for [tool axns](/recipes/running-without-rails#tool-contract-validation).

| | at class definition | at first projection |
| --- | --- | --- |
| no UTF-8 rendering | an `exposes` field name — it names a property in the serialized body whatever a schema emits | a top-level `expects` name, a subfield, a shape member |
| collapses onto one property | two field names; two `exposes` names; two subfields under one parent — including one route spelled two ways (`on: "p"` and `on: :p`) | two shape members; a `model:`-generated `<field>_id` against a differently-spelled explicit one; a structured type's members against a shape's; two routes only *resolution* equates (`on: "foo.bar"` against `on: :bar`, where `bar` is itself a subfield of `foo`) |

Rule 1 is applied to the property names a schema actually **emits**, so a name it never emits — a leaf on a subfield the tree drops, a shape member under a scalar `of:`, a member of a type an outbound gate strips — is not rejected for bytes that never reach a schema.

Both rules rest on one premise, which the DSL guarantees for you: a name must render through Ruby's own `to_s`, so that the property axn judges is the property `JSON.generate` emits. `expects`/`exposes` symbolize every name you declare, and a shape member is stored as the Symbol it was judged under, so nothing you can declare violates it. A name built into a field config and assigned onto a class directly can — a `String` subclass (or a String carrying a singleton) that defines `to_s` has bytes *and* a rendering, and only its author knows which one names the property — and such a name is refused when the projection is built, alongside the two rules above.

Two further bounds guard *size* rather than naming, and they are different limits:

* **The graph you declared**, at class definition: a `shape:` graph may have at most 25,000 member **paths**. A nested shape object shared between **sibling** members multiplies out, so N levels of two-way sharing are 2^N paths, and every walk of a stored graph pays one step per path — runtime shape validation on each call, and `sensitive:` redaction once per class, or once per *logged call* for a `sensitive:` that resolves against the action (a Proc or Symbol), which no memo can decide ahead of time. Measured with the bound removed, 786,000 paths (18 levels of two-way sharing) cost ≈1.3s per log line that way, and ≈2s for the one derivation any contract makes on its first logged call. Shallow sharing is unaffected.
* **The schema it would emit**, when a projection is first built: at most 25,000 JSON properties. What counts is derived from the same decisions the emitter makes, so anything the schema names nowhere costs nothing here. A shape whose members never become properties: a scalar `of:` (`of: String` with `field :length`) validates members off an element that stays a string, and an outbound-gated or non-member-keyed value emits no object at all. On **output** that includes anything a per-validator gate could skip — `exposes :x, type: { klass: SomeData, if: :flag }` promises none of `SomeData`'s members, so they cost nothing there, while the same declaration on **input** still counts them (a gate can only relax enforcement at runtime, so the input schema advertises the type regardless). And a whole config the projection represents nowhere: one rooted at `on: :ambient_context`, a subfield under a `model:`/non-object/mixed-union parent at any depth, a `model:` route's own declared type on input (the client sends `<field>_id`), or the second of two routes to one wire path, whose `shape:`/`of:` the emitter never reaches (the property is built from the first). An `of:` element type's own members *do* reach `items`, so they still count — including a union `of: [A, B]`, where each element type reaches `items` in its own `anyOf` branch (two branches may name the same member without colliding: they describe one property two ways) — as does a contract whose fields merely **sum** past the bound (only the total reveals that one).


Subfields nest to any depth: a dotted `on:` path (`on: "address.billing"`) and a subfield of a subfield both appear as recursively nested object `properties`, keyed by wire key (aliases resolve to the key a client actually sends). A required subfield at any depth forces its whole ancestor chain into `required` (and strips those ancestors' nullability): a `nil`/omitted ancestor yields every descendant absent, so runtime could never satisfy the leaf. Intermediate keys introduced by a dotted segment reflect as plain object properties that are required (and non-nullable) exactly when something beneath them is. The structural exclusions: a deep subfield whose chain passes through a `model:` parent (the client sends `<field>_id`, not the object) or a non-object parent (`type: Array`, a mixed union) has no JSON-object representation. These are omitted from the schema — calling `input_schema` on such a class logs a one-time warning naming the omitted field(s), so the gap is visible rather than silent when you build tooling on the schema. A nested `model:` subfield reached via a dotted `on:` (`expects :widget, on: "payload.order", model:`) is not one of these exclusions — it reflects like any nested model, with the client sending the nested `<field>_id` (`order.widget_id`).

::: tip Ruby-object input types are coercible
The schema advertises each `type:` as its JSON wire form — so `expects :on, type: Date` shows `{ type: "string", format: "date" }` and `expects :mode, type: Symbol` shows `{ type: "string" }`. Add `coerce:` (see [`coerce`](#coerce) above) so a JSON client sending the string `"2026-07-08"` or `"active"` is parsed into the declared `Date`/`Symbol` — the inbound inverse of how the value serializes on output. Without `coerce:`, core still validates strictly against the Ruby type (a direct Ruby caller must pass a real `Date`).
:::

::: tip Declare `type:` on every tool input
[`Axn::Tools::Invoker`](/reference/tool-invoker) (the entry point an adapter uses to run an Axn as a tool) always coerces, so a field only picks up that coercion — and gets a useful entry in the schema above — when it declares a `type:` axn recognizes. Declare `type:` on every tool input rather than reaching for a defensive per-field `coerce: true`; the always-on tool coercion and the schema reflection both key off the same `type:` declaration.
:::

