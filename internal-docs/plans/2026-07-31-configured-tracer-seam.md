# Configured Tracer Seam (`Axn.config.tracer`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make axn's tracer a configured, public seam (`Axn.config.tracer`) with three states — unset auto-detects, `nil` disables, an object is used — so no downstream gem needs to stub `Axn::Internal::Tracing`.

**Architecture:** `Axn.config` owns policy (which tracer, or none); `Axn::Internal::Tracing` keeps only mechanism (OpenTelemetry auto-detection, per-tracer capability probe). The executor gates spans on tracer presence rather than `defined?(OpenTelemetry)`. Reaching that shape requires four small changes to the shared `Axn::Configurable` kernel first, so the tri-state is a declared property of the setting rather than an accident of `callable: true`.

**Tech Stack:** Ruby (>= 3.2.1), RSpec, OpenTelemetry API (optional — not a dependency of this gem), ActiveSupport::Notifications.

Full design rationale: `internal-docs/specs/2026-07-31-configured-tracer-seam-design.md`. Ticket: [PRO-3017](https://linear.app/teamshares/issue/PRO-3017/axn-give-tracing-a-configured-seam-axnconfigtracer-instead-of-an).

## Global Constraints

- Ruby floor stays `>= 3.2.1`. Do not use `ObjectSpace::WeakKeyMap` (3.3+) or any other 3.3/3.4-only API.
- OpenTelemetry is **not** a dependency. It is absent at runtime in the spec suite unless a spec `stub_const`s it. Never `require` it.
- Guard every reference to a Rails/OTel/Sidekiq constant with `defined?()`. `spec/` is non-Rails; `spec_rails/` is the Rails dummy app.
- Comments describe current behavior and intrinsic why. Never write "used to X / now Y", never reference a ticket number as justification-by-citation, never mention a code review.
- Do not hard-wrap Markdown prose in docs. One line per paragraph.
- Run `bundle exec rspec` for the suite and `bundle exec rubocop` before each commit. Fix offenses rather than adding `rubocop:disable`; if one is unavoidable, disable the single named cop inline.
- Ruby 3.4 changed `Hash#inspect` spacing. Never assert on `Hash#inspect` output text.
- This gem is pre-release. Dead keyword arguments are removed outright, with no tombstone.

---

### Task 1: Kernel — a Proc `default:` is dynamic; `callable:` is removed

`Axn::Configurable`'s `callable: true` flag conflates "the default is computed lazily" with "a stored value that responds to `call` gets invoked". Only the first is ever used (`bin/support/gem_generator.rb:326` teaches it as "for a lambda default"), and the second would be actively wrong for `emit_metrics`, whose proc value must be called with arguments at its call site rather than resolved on read. Infer dynamism from the default's class and delete the flag.

Separately, the reader currently writes `dup_default` into the setting's ivar on first read, which destroys `defined?(@ivar)` as an "explicitly assigned" sentinel. Dynamic defaults must be read fresh and never stored. Literal defaults keep memoizing, deliberately: in-place mutation of an array default is a relied-upon path (`adapter.config.tool_roots << "actions"`, `additional_includes`), and un-memoizing would make `<<` mutate a throwaway dup.

**Files:**
- Modify: `lib/axn/configurable.rb:37` (the `Setting` struct), `:48-51` (`resolve`), `:373` and `:463` (both `setting` methods), `:432-436` (`Config#_read`), `:285` (`resolve_override`)
- Modify: `lib/axn/configuration.rb` — no setting in this file passes `callable:`, so no change expected; confirm with grep
- Modify: `bin/support/gem_generator.rb:326` (the generated comment mentions the removed flag)
- Test: `spec/axn/configurable_spec.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Setting#dynamic_default?` → `true` when `default.is_a?(Proc)`. `Setting#resolve` no longer exists. `setting(name, default: nil, one_of: nil, validate: nil, overridable: false)` — no `callable:` parameter. A setting declared with a Proc `default:` re-derives on every read while unset; an explicitly assigned value (including `nil`) is returned as-is.

- [ ] **Step 1: Write the failing tests**

Add to `spec/axn/configurable_spec.rb` (a new top-level `describe` block inside the existing outer describe):

```ruby
describe "dynamic defaults" do
  let(:klass) do
    Class.new do
      extend Axn::Configurable::Settings

      def self.derivations = @derivations ||= 0
      def self.bump! = @derivations = derivations + 1

      setting :derived, default: -> { bump!; "derived-#{derivations}" }
      setting :literal_list, default: []
    end
  end

  let(:instance) { klass.new }

  it "re-derives a Proc default on every read while unset" do
    expect(instance.derived).to eq("derived-1")
    expect(instance.derived).to eq("derived-2")
  end

  it "never writes a Proc default into the ivar, so the ivar stays an assignment sentinel" do
    instance.derived
    expect(instance.instance_variable_defined?(:@derived)).to be(false)
  end

  it "returns an explicitly assigned value instead of re-deriving" do
    instance.derived = "explicit"
    expect(instance.derived).to eq("explicit")
    expect(instance.derived).to eq("explicit")
  end

  it "treats an explicitly assigned nil as a value, not as a reset" do
    instance.derived = nil
    expect(instance.derived).to be_nil
    expect(instance.derived?).to be(false)
  end

  it "still memoizes a literal mutable default, so in-place mutation persists" do
    instance.literal_list << :a
    expect(instance.literal_list).to eq([:a])
  end

  it "does not share a literal mutable default across instances" do
    instance.literal_list << :a
    expect(klass.new.literal_list).to eq([])
  end
end
```

Then update the three existing declarations that pass the removed flag — `spec/axn/configurable_spec.rb:10`, `:130`, `:156` (`setting :enabled, default: true, callable: true[, overridable: true]`) — by deleting `callable: true` from each. Their `default: true` is a literal, so behavior is unchanged.

At `spec/axn/configurable_spec.rb:292`, `setting :sandbox_mode, default: -> { true }, callable: true` becomes `setting :sandbox_mode, default: -> { true }`. Its two examples ("returns true for a truthy resolved value (callable default)" and "returns false for an explicitly-assigned false") still pass; rename the first to "returns true for a truthy resolved value (dynamic default)".

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/configurable_spec.rb -e "dynamic defaults"`
Expected: FAIL. The new `setting :derived, default: -> { … }` declares no `callable:`, so today's reader returns the Proc itself: "re-derives a Proc default on every read" fails with `expected "derived-1", got #<Proc…>`, and "never writes a Proc default into the ivar" fails with `expected false, got true`. The two literal-default examples pass already — they are there to pin behavior the implementation must not change. Any example failing for a different reason than predicted is a signal to re-read the current implementation before proceeding.

- [ ] **Step 3: Implement**

In `lib/axn/configurable.rb`, replace the `Setting` struct's member list and its `resolve` method:

```ruby
    Setting = Struct.new(:name, :default, :one_of, :validate, :overridable, keyword_init: true) do
      # Raises ArgumentError if the assigned value is not permitted.
      def validate!(value)
        raise ArgumentError, "#{name} must be one of #{one_of.map(&:inspect).join(', ')}; got #{value.inspect}" if one_of && !one_of.include?(value)

        return unless validate.respond_to?(:call) && !validate.call(value)

        raise ArgumentError, "#{name} got invalid value: #{value.inspect}"
      end

      # A Proc default is DYNAMIC: re-derived on every read while the setting is unset, and never
      # stored. Settings whose default depends on the host app's boot state (a tracer that
      # OpenTelemetry may register after axn loads, a Rails.env-derived flag) would otherwise cache
      # an answer taken before that state existed.
      def dynamic_default? = default.is_a?(Proc)

      # A fresh copy of the default, so mutable defaults (e.g. []) aren't shared
      # across instances. dup is a no-op for nil/true/false/Symbol/Integer.
      def dup_default
        default.dup
      end
    end
```

Replace the generated reader in `Settings#setting` (was `lib/axn/configurable.rb:467-470`):

```ruby
        define_method(name) do
          return instance_variable_get(ivar) if instance_variable_defined?(ivar)
          return setting.default.call if setting.dynamic_default?

          # A literal default IS memoized: mutating it in place (`config.some_list << :x`) is a
          # supported way to extend one, which a fresh dup per read would silently discard.
          instance_variable_set(ivar, setting.dup_default)
        end
```

Replace `Config#_read` in the module-singleton flavor (was `lib/axn/configurable.rb:432-436`):

```ruby
      def _read(name)
        setting = @settings[name]
        return @values[name] if @values.key?(name)
        return setting.default.call if setting.dynamic_default?

        @values[name] = setting.dup_default
      end
```

At `lib/axn/configurable.rb:285`, `setting.resolve(found)` becomes `found` — a per-class override value is stored literally. Keep the surrounding `setting.validate!(found)` call and its comment. Add to that comment's paragraph:

```ruby
          # An override value is used as-is. A setting's dynamic default still reaches a class with
          # no override of its own, through the `fallback` lambda below, which reads the config's
          # own reader.
```

Remove `callable:` from both `setting` signatures (`lib/axn/configurable.rb:373` and `:463`) and from both `Setting.new(...)` calls. In `Settings#setting`, delete `setting.resolve(...)` from the reader (done above). The class-flavor `setting` also declares `define_method(:"#{name}?") { !!public_send(name) }` — leave it.

Update the doc comment at `lib/axn/configurable.rb:440` ("reusing the same Setting kernel (defaults, one_of:/validate:, callable:)") to drop `callable:`.

In `bin/support/gem_generator.rb:326`, change the trailing clause from "`callable: true` for a lambda default." to "A Proc `default:` is re-derived on every read, for a value that depends on host-app boot state."

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/axn/configurable_spec.rb`
Expected: PASS.

Run: `grep -rn "callable" lib/ bin/ spec/`
Expected: no `callable:` keyword remains. Matches inside the word (e.g. `Internal::Callable`, `call_with_desired_shape`) are unrelated.

Run: `bundle exec rspec`
Expected: PASS — the whole suite, since this touches the kernel every setting reads through.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/axn/configurable.rb bin/support/gem_generator.rb spec/axn/configurable_spec.rb
git add lib/axn/configurable.rb bin/support/gem_generator.rb spec/axn/configurable_spec.rb
git commit -m "PRO-3017: a Proc default: is dynamic, replacing the callable: flag"
```

---

### Task 2: Kernel — a `validate:` lambda may return a String as the rejection reason

`Setting#validate!` raises a bare `"<name> got invalid value: <value>"`, which does not tell someone assigning a bad value what a good one looks like. That matters most for a setting whose whole purpose is injecting an object of your own. Let a validator return a truthy String to supply the reason.

**Files:**
- Modify: `lib/axn/configurable.rb:39-45` (`Setting#validate!`)
- Test: `spec/axn/configurable_spec.rb`

**Interfaces:**
- Consumes: `Setting#validate!` from Task 1 (unchanged signature).
- Produces: a `validate:` lambda returning a truthy `String` raises `ArgumentError` with message `"<name> got invalid value: <value> — <string>"`. Returning `true` (or any other truthy value) passes. Returning `false` or `nil` raises the message without a detail clause.

- [ ] **Step 1: Write the failing tests**

Add to `spec/axn/configurable_spec.rb`:

```ruby
describe "validate: rejection reasons" do
  let(:klass) do
    Class.new do
      extend Axn::Configurable::Settings

      setting :bare, validate: ->(v) { v.is_a?(Integer) }
      setting :detailed, validate: ->(v) { v.is_a?(Integer) || "must be an Integer" }
    end
  end

  let(:instance) { klass.new }

  it "raises without a detail clause when the validator returns false" do
    expect { instance.bare = "nope" }.to raise_error(ArgumentError, 'bare got invalid value: "nope"')
  end

  it "appends a String return value as the reason" do
    expect { instance.detailed = "nope" }.to raise_error(
      ArgumentError, 'detailed got invalid value: "nope" — must be an Integer'
    )
  end

  it "accepts a valid value through a String-returning validator" do
    expect { instance.detailed = 3 }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/configurable_spec.rb -e "validate: rejection reasons"`
Expected: FAIL. "appends a String return value" fails because the String is truthy, so today's `!validate.call(value)` treats it as a pass and no error is raised at all.

- [ ] **Step 3: Implement**

Replace `Setting#validate!` in `lib/axn/configurable.rb`:

```ruby
      # Raises ArgumentError if the assigned value is not permitted. A `validate:` lambda may return
      # a String instead of `true` to say WHY the value was rejected — worth it for a setting whose
      # value is an object the app supplies, where "invalid" alone doesn't hint at the contract.
      def validate!(value)
        raise ArgumentError, "#{name} must be one of #{one_of.map(&:inspect).join(', ')}; got #{value.inspect}" if one_of && !one_of.include?(value)
        return unless validate.respond_to?(:call)

        outcome = validate.call(value)
        return if outcome && !outcome.is_a?(String)

        detail = outcome if outcome.is_a?(String)
        raise ArgumentError, ["#{name} got invalid value: #{value.inspect}", detail].compact.join(" — ")
      end
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/axn/configurable_spec.rb`
Expected: PASS.

Run: `bundle exec rspec`
Expected: PASS. Every existing `validate:` in `lib/axn/configuration.rb` returns a boolean, so none change behavior.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/axn/configurable.rb spec/axn/configurable_spec.rb
git add lib/axn/configurable.rb spec/axn/configurable_spec.rb
git commit -m "PRO-3017: validate: may return a String rejection reason"
```

---

### Task 3: Kernel — `reset!(*names)` returns settings to their declared defaults

Returning a setting to its default currently requires `remove_instance_variable`, which is exactly the internals-poking this work exists to eliminate — and its absence is why assigning `nil` looks like the way to reset. `reset!` supplies the verb, and gives the config surface its first supported test-isolation path: `spec_helper.rb` has none today and cannot get one otherwise, because `Axn.config` memoizes into `@config` and `Axn` never defines `config=` (`Axn.configure`'s `self.config ||= Configuration.new` only works because `||=` short-circuits before reaching the writer that isn't there).

**Files:**
- Modify: `lib/axn/configurable.rb` — `Settings` module (around `:452-480`) and `Config` class (around `:394-437`)
- Test: `spec/axn/configurable_spec.rb`

**Interfaces:**
- Consumes: `Setting#dynamic_default?` and the reader shape from Task 1.
- Produces: `<config instance>.reset!(*names)` on the class flavor and `<module>.config.reset!(*names)` on the module-singleton flavor. Both return `self`, drop the named settings back to their declared defaults, raise `ArgumentError` on a name that is not a declared setting, and with no arguments reset every setting declared on the class (or module) that declared them. The class flavor also gains `_declared_settings` as a class-level reader returning `{name => Setting}`.

- [ ] **Step 1: Write the failing tests**

Add to `spec/axn/configurable_spec.rb`:

```ruby
describe "#reset!" do
  context "on the class flavor" do
    let(:klass) do
      Class.new do
        extend Axn::Configurable::Settings

        setting :literal, default: :original
        setting :derived, default: -> { :derived_default }
      end
    end

    let(:instance) { klass.new }

    it "returns a named literal setting to its default" do
      instance.literal = :changed
      instance.reset!(:literal)
      expect(instance.literal).to eq(:original)
    end

    it "returns a named dynamic setting to re-deriving, which an assigned nil had suppressed" do
      instance.derived = nil
      expect(instance.derived).to be_nil
      instance.reset!(:derived)
      expect(instance.derived).to eq(:derived_default)
    end

    it "resets every declared setting when called with no arguments" do
      instance.literal = :changed
      instance.derived = nil
      instance.reset!
      expect(instance.literal).to eq(:original)
      expect(instance.derived).to eq(:derived_default)
    end

    it "raises on a name that is not a declared setting" do
      expect { instance.reset!(:nope) }.to raise_error(ArgumentError, /unknown setting :nope/)
    end

    it "is a no-op for a setting that was never assigned" do
      expect { instance.reset!(:literal) }.not_to raise_error
      expect(instance.literal).to eq(:original)
    end

    it "returns self so it can be chained" do
      expect(instance.reset!(:literal)).to be(instance)
    end
  end

  context "on the module-singleton flavor" do
    let(:mod) do
      Module.new do
        extend Axn::Configurable

        setting :literal, default: :original
        setting :derived, default: -> { :derived_default }
      end
    end

    it "returns a named setting to its default" do
      mod.config.literal = :changed
      mod.config.reset!(:literal)
      expect(mod.config.literal).to eq(:original)
    end

    it "returns a dynamic setting to re-deriving after an assigned nil" do
      mod.config.derived = nil
      mod.config.reset!(:derived)
      expect(mod.config.derived).to eq(:derived_default)
    end

    it "raises on an unknown setting" do
      expect { mod.config.reset!(:nope) }.to raise_error(ArgumentError, /unknown setting :nope/)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/configurable_spec.rb -e "#reset!"`
Expected: FAIL with `NoMethodError: undefined method 'reset!'`.

- [ ] **Step 3: Implement**

In the `Settings` module in `lib/axn/configurable.rb`, add a declared-settings registry and install `reset!` as an instance method on the extending class. Add immediately after `include PerClassOverrides` (`:453`):

```ruby
      # Declared Setting objects by name, for `reset!`. The class flavor otherwise keeps no registry
      # (only overridable settings are tracked, by PerClassOverrides).
      def _declared_settings = @_declared_settings ||= {}

      # `reset!` is an INSTANCE method on the extending class (a config object), so it is installed
      # here rather than declared in this module's body. It closes over the extending class, so a
      # subclass that declares further settings gets its own `reset!` covering its own registry.
      def self.extended(base)
        base.send(:define_method, :reset!) do |*names|
          targets = names.empty? ? base._declared_settings.keys : names.map(&:to_sym)
          targets.each do |name|
            raise ArgumentError, "unknown setting #{name.inspect}" unless base._declared_settings.key?(name)

            ivar = :"@#{name}"
            remove_instance_variable(ivar) if instance_variable_defined?(ivar)
          end
          self
        end
      end
```

In `Settings#setting`, record the setting right after building it:

```ruby
      def setting(name, default: nil, one_of: nil, validate: nil, overridable: false)
        setting = Setting.new(name: name.to_sym, default:, one_of:, validate:, overridable:)
        _declared_settings[setting.name] = setting
        ivar = :"@#{name}"
```

In the `Config` class (module-singleton flavor), add the symmetric method as a public method above `private`:

```ruby
      # Returns the named settings to their declared defaults (all of them with no arguments).
      # `reset_config!` on the owning module discards the whole bag; this is the per-setting form,
      # and the supported alternative to assigning nil, which is a VALUE rather than a reset.
      def reset!(*names)
        targets = names.empty? ? @settings.keys : names.map(&:to_sym)
        targets.each do |name|
          raise ArgumentError, "unknown setting #{name.inspect}" unless @settings.key?(name)

          @values.delete(name)
        end
        self
      end
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/axn/configurable_spec.rb`
Expected: PASS.

Run: `bundle exec rspec`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/axn/configurable.rb spec/axn/configurable_spec.rb
git add lib/axn/configurable.rb spec/axn/configurable_spec.rb
git commit -m "PRO-3017: add Configurable#reset! to return settings to their defaults"
```

---

### Task 4: `Axn.config.tracer` and `Internal::Tracing.autodetected_tracer`

Declare the public seam and the auto-detection method it defaults to. `Internal::Tracing.tracer` stays in place for this task so the suite stays green; Task 5 removes it and switches the executor over.

**Files:**
- Modify: `lib/axn/configuration.rb` (add the setting after `setting :tool_name_stripped_prefixes` at `:115-118`, before `attr_writer :logger, ...` at `:120`)
- Modify: `lib/axn/internal/tracing.rb`
- Test: `spec/axn/configuration/tracer_spec.rb` (create)

**Interfaces:**
- Consumes: dynamic defaults (Task 1), String rejection reasons (Task 2), `reset!` (Task 3).
- Produces: `Axn.config.tracer` → the tracer in use (configured object, auto-detected OTel tracer, or `nil`); `Axn.config.tracer = <obj|nil>`; `Axn.config.tracer?`; `Axn.config.reset!(:tracer)`. `Axn::Internal::Tracing.autodetected_tracer` → the OTel tracer when OpenTelemetry is loaded, else `nil`.

- [ ] **Step 1: Write the failing tests**

Create `spec/axn/configuration/tracer_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "Axn.config.tracer" do
  # OpenTelemetry is not a dependency of this gem, so it is absent unless a spec stubs it. That
  # makes "a configured tracer with OTel unloaded" the default state here.
  let(:fake_tracer) do
    Class.new do
      def in_span(*, **) = yield(nil)
    end.new
  end

  after { Axn.config.reset!(:tracer) }

  it "auto-detects when unset" do
    expect(Axn::Internal::Tracing).to receive(:autodetected_tracer).and_return(fake_tracer)
    expect(Axn.config.tracer).to be(fake_tracer)
  end

  it "returns nil when unset and OpenTelemetry is absent" do
    expect(Axn.config.tracer).to be_nil
    expect(Axn.config.tracer?).to be(false)
  end

  it "returns a configured tracer without consulting auto-detection" do
    expect(Axn::Internal::Tracing).not_to receive(:autodetected_tracer)
    Axn.config.tracer = fake_tracer
    expect(Axn.config.tracer).to be(fake_tracer)
    expect(Axn.config.tracer?).to be(true)
  end

  it "treats an explicit nil as tracing disabled rather than as unset" do
    expect(Axn::Internal::Tracing).not_to receive(:autodetected_tracer)
    Axn.config.tracer = nil
    expect(Axn.config.tracer).to be_nil
    expect(Axn.config.tracer?).to be(false)
  end

  it "returns to auto-detection on reset!" do
    Axn.config.tracer = nil
    Axn.config.reset!(:tracer)
    expect(Axn::Internal::Tracing).to receive(:autodetected_tracer).and_return(fake_tracer)
    expect(Axn.config.tracer).to be(fake_tracer)
  end

  it "rejects an object that cannot receive a span, naming the contract" do
    expect { Axn.config.tracer = Object.new }.to raise_error(ArgumentError, /must respond to #in_span/)
  end

  it "rejects a callable, which would otherwise look like a lazy tracer" do
    expect { Axn.config.tracer = -> { fake_tracer } }.to raise_error(ArgumentError, /must respond to #in_span/)
  end

  describe "Axn::Internal::Tracing.autodetected_tracer" do
    it "is nil when OpenTelemetry is not loaded" do
      Axn::Internal::Tracing.reset!
      expect(Axn::Internal::Tracing.autodetected_tracer).to be_nil
    end
  end
end
```

Note: `Axn::Internal::Tracing.reset!` and the per-tracer probe arrive in Task 5. For this task, add only `reset!` to `Internal::Tracing` (Step 3 below) so this last example passes; the probe change is Task 5's.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/configuration/tracer_spec.rb`
Expected: FAIL with `NoMethodError: undefined method 'tracer' for an instance of Axn::Configuration`.

- [ ] **Step 3: Implement**

In `lib/axn/configuration.rb`, add after the `setting :tool_name_stripped_prefixes` block and before `attr_writer :logger, :env, :on_exception, :rails`:

```ruby
    # The tracer that receives axn's `axn.call` spans. Three states:
    #   unset          → auto-detect: the OpenTelemetry tracer when OTel is loaded, else no spans
    #   nil            → no tracing, even with OpenTelemetry loaded
    #   a tracer       → that object, whether or not OpenTelemetry is loaded
    # `Axn.config.reset!(:tracer)` returns to auto-detection.
    #
    # The default is dynamic — re-derived on every read — because OpenTelemetry may be loaded after
    # axn is. Caching "absent" at gem load (plausible under Bundler.require) would permanently
    # disable tracing for an app that configures OpenTelemetry in an initializer.
    setting :tracer,
            default: -> { Axn::Internal::Tracing.autodetected_tracer },
            validate: ->(v) { v.nil? || v.respond_to?(:in_span) || "must respond to #in_span, or be nil to disable tracing" }
```

In `lib/axn/internal/tracing.rb`, rename `tracer` to `autodetected_tracer`, keeping `tracer` as-is for now (Task 5 deletes it), and add `reset!`:

```ruby
        # The OpenTelemetry tracer, when OpenTelemetry is loaded. Mechanism only: whether axn traces
        # at all, and with which tracer, is Axn.config.tracer's decision. The presence check runs on
        # every call because OpenTelemetry can be loaded lazily, and the provider is re-consulted
        # because it can be replaced (a host app configuring the SDK after boot, or a test swapping
        # in a mock).
        def autodetected_tracer
          return nil unless defined?(OpenTelemetry)

          current_provider = OpenTelemetry.tracer_provider
          return @tracer if defined?(@tracer) && defined?(@tracer_provider) && @tracer_provider == current_provider

          @tracer_provider = current_provider
          @tracer = current_provider.tracer("axn", Axn::VERSION)
        end

        # Drops the auto-detection and capability memos, for specs that swap the OpenTelemetry
        # constant or the tracer out from under them.
        def reset!
          %i[@tracer @tracer_provider @supports_record_exception @probed_tracer].each do |ivar|
            remove_instance_variable(ivar) if instance_variable_defined?(ivar)
          end
        end
```

Keep the existing `tracer` method body, but have it delegate so the two cannot drift within this task: `def tracer = autodetected_tracer`.

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/axn/configuration/tracer_spec.rb`
Expected: PASS.

Run: `bundle exec rspec`
Expected: PASS. The existing tracing specs still call `Internal::Tracing.tracer`, which now delegates.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/axn/configuration.rb lib/axn/internal/tracing.rb spec/axn/configuration/tracer_spec.rb
git add lib/axn/configuration.rb lib/axn/internal/tracing.rb spec/axn/configuration/tracer_spec.rb
git commit -m "PRO-3017: add Axn.config.tracer over Internal::Tracing.autodetected_tracer"
```

---

### Task 5: The executor gates on tracer presence, and the capability probe asks the tracer

Two coupled changes, because the executor is the only caller of both. The span gate becomes "is there a tracer?" instead of `defined?(OpenTelemetry)` — without this, a configured tracer is silently ignored. And `supports_record_exception_option?` starts inspecting the tracer actually being called instead of `OpenTelemetry::Trace::Tracer`, whose signature says nothing about an injected object and can be wrong in both directions.

Only an explicitly-named keyword counts as support. A tracer declaring `**opts` reports `:keyrest` and is read as unsupported, so axn omits the option and an OTel >= 1.7 tracer underneath records the exception in addition to axn's own `span.record_exception` — a duplicate event. That is the safe direction: over-detecting sends `record_exception:` to a strict-arity tracer, and `in_span` is called outside `best_effort`, so the resulting `ArgumentError` would take down the call.

**Files:**
- Modify: `lib/axn/core/executor.rb:124-131`
- Modify: `lib/axn/internal/tracing.rb` (remove `tracer`, rewrite `supports_record_exception_option?`)
- Modify: `spec/axn/internal/tracing/opentelemetry_spec.rb:34-37` and `:174-190`; `spec/axn/internal/tracing/tagging_spec.rb:148-150`
- Test: `spec/axn/configuration/tracer_spec.rb` (extend), `spec/axn/internal/tracing/opentelemetry_spec.rb`

**Interfaces:**
- Consumes: `Axn.config.tracer` and `Internal::Tracing.reset!` (Task 4).
- Produces: `Axn::Internal::Tracing.supports_record_exception_option?(tracer)` — one required positional argument. `Axn::Internal::Tracing.tracer` no longer exists.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/configuration/tracer_spec.rb`, inside the outer describe:

```ruby
  describe "the executor's span gate" do
    let(:recorder) do
      Class.new do
        attr_reader :calls

        def initialize = @calls = []

        def in_span(name, **kwargs)
          @calls << [name, kwargs]
          yield(span)
        end

        def span = @span ||= FakeSpan.new
      end.new
    end

    it "creates a span through an injected tracer with OpenTelemetry not loaded" do
      expect(defined?(OpenTelemetry)).to be_nil
      Axn.config.tracer = recorder
      build_axn.call
      expect(recorder.calls).to eq([["axn.call", { attributes: { "axn.resource" => "Anonymous Axn" } }]])
    end

    it "creates no span when tracing is explicitly disabled" do
      Axn.config.tracer = nil
      expect(Axn::Internal::Tracing).not_to receive(:supports_record_exception_option?)
      expect(build_axn.call).to be_ok
    end

    it "passes record_exception: false only when the tracer's own in_span accepts it" do
      accepting = Class.new do
        attr_reader :kwargs
        def in_span(_name, record_exception: nil, **rest)
          @kwargs = rest.merge(record_exception:)
          yield(FakeSpan.new)
        end
      end.new

      Axn.config.tracer = accepting
      build_axn.call
      expect(accepting.kwargs[:record_exception]).to be(false)
    end

    it "keeps using a configured tracer when the OpenTelemetry provider changes" do
      Axn.config.tracer = recorder
      otel = Module.new { def self.tracer_provider; end }
      stub_const("OpenTelemetry", otel)
      allow(OpenTelemetry).to receive(:tracer_provider).and_return(Object.new, Object.new)

      build_axn.call
      build_axn.call
      expect(recorder.calls.length).to eq(2)
    end
  end
```

Define the shared span stand-in at the top of the file, above the first `describe`'s body:

```ruby
  class FakeSpan
    attr_reader :attributes

    def initialize = @attributes = {}
    def set_attribute(key, value) = @attributes[key] = value
    def record_exception(_exception) = nil
    def status=(_status) = nil
  end
```

Then replace the memo examples in `spec/axn/internal/tracing/opentelemetry_spec.rb` (`:172-190`, the whole `describe ".supports_record_exception_option?"` block, including its NOTE about needing a real OTel class — the probe is now directly testable) with:

```ruby
  describe ".supports_record_exception_option?" do
    let(:accepting) { Class.new { def in_span(_name, record_exception: nil); end }.new }
    let(:rejecting) { Class.new { def in_span(_name, attributes: nil); end }.new }
    let(:splatting) { Class.new { def in_span(_name, **opts); end }.new }

    before { Axn::Internal::Tracing.reset! }

    it "reads the option off the tracer's own signature" do
      expect(described_class.supports_record_exception_option?(accepting)).to be(true)
      expect(described_class.supports_record_exception_option?(rejecting)).to be(false)
    end

    it "reads a **opts tracer as unsupported, since passing the option to a strict tracer would raise" do
      expect(described_class.supports_record_exception_option?(splatting)).to be(false)
    end

    it "is false for no tracer at all" do
      expect(described_class.supports_record_exception_option?(nil)).to be(false)
    end

    it "does not leak one tracer's answer to another" do
      expect(described_class.supports_record_exception_option?(accepting)).to be(true)
      expect(described_class.supports_record_exception_option?(rejecting)).to be(false)
      expect(described_class.supports_record_exception_option?(accepting)).to be(true)
    end

    it "memoizes the answer for a repeated tracer" do
      allow(accepting).to receive(:method).and_call_original
      2.times { described_class.supports_record_exception_option?(accepting) }
      expect(accepting).to have_received(:method).with(:in_span).once
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/configuration/tracer_spec.rb spec/axn/internal/tracing/opentelemetry_spec.rb`
Expected: FAIL. "creates a span through an injected tracer" fails with `recorder.calls` empty, because the gate is still `defined?(OpenTelemetry)`. The `.supports_record_exception_option?` examples fail with `ArgumentError: wrong number of arguments (given 1, expected 0)`.

- [ ] **Step 3: Implement**

In `lib/axn/core/executor.rb`, replace lines 124-131:

```ruby
        # Presence of a TRACER gates the span, not presence of the OpenTelemetry constant: a tracer
        # can be configured explicitly (`Axn.config.tracer`) with OpenTelemetry never loaded, and
        # tracing can be turned off (`Axn.config.tracer = nil`) with it loaded.
        tracer = Axn.config.tracer
        if tracer
          in_span_kwargs = { attributes: { "axn.resource" => resource } }
          in_span_kwargs[:record_exception] = false if Internal::Tracing.supports_record_exception_option?(tracer)

          tracer.in_span("axn.call", **in_span_kwargs) do |span|
            instrument_block.call
          ensure
            finalize_span(span)
          end
```

In `lib/axn/internal/tracing.rb`, delete the `tracer` delegate added in Task 4 and replace `supports_record_exception_option?`:

```ruby
        # Whether THIS tracer's #in_span accepts the `record_exception:` option (added in
        # opentelemetry-api 1.7.0). Asks the object actually being called rather than
        # OpenTelemetry::Trace::Tracer, whose signature says nothing about an injected tracer and can
        # be wrong in both directions.
        #
        # Only an explicitly-named keyword counts. A tracer declaring `**opts` reports :keyrest and is
        # read as unsupported, so axn omits the option and an OTel >= 1.7 tracer underneath records the
        # exception on top of axn's own `span.record_exception` — a duplicate event. That is the safe
        # direction: over-detecting sends the option to a strict-arity tracer, and `in_span` is called
        # outside `best_effort`, so the resulting ArgumentError would take down the call.
        #
        # Single-slot identity memo: there is one tracer per process, so a map would model tracers
        # that never exist, and the slot holds no reference Axn.config isn't already holding.
        def supports_record_exception_option?(tracer)
          return false if tracer.nil?
          return @supports_record_exception if defined?(@supports_record_exception) && @probed_tracer.equal?(tracer)

          @probed_tracer = tracer
          @supports_record_exception = begin
            tracer.method(:in_span).parameters.any? { |type, name| name == :record_exception && %i[key keyreq].include?(type) }
          rescue StandardError
            false
          end
        end
```

Update the three teardown blocks that poke ivars. In `spec/axn/internal/tracing/opentelemetry_spec.rb`, replace lines 34-37:

```ruby
    # Clear the memos so the next example re-detects against the restored OpenTelemetry.
    Axn::Internal::Tracing.reset!
```

In `spec/axn/internal/tracing/tagging_spec.rb`, replace lines 148-150 with the same single call.

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/axn/configuration/tracer_spec.rb spec/axn/internal/tracing/`
Expected: PASS.

Run: `grep -rn "Internal::Tracing.tracer\b" lib/ spec/ docs/`
Expected: no matches.

Run: `bundle exec rspec`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/axn/core/executor.rb lib/axn/internal/tracing.rb spec/
git add lib/axn/core/executor.rb lib/axn/internal/tracing.rb spec/
git commit -m "PRO-3017: gate spans on tracer presence and probe the tracer in use"
```

---

### Task 6: `finalize_span` stops stranding facet attributes without OpenTelemetry

`OpenTelemetry::Trace::Status.error` at `lib/axn/core/executor.rb:156` is the last OTel constant in the span path. With a configured tracer and OTel unloaded it raises `NameError`, which `best_effort` swallows — but that aborts the rest of the block, and the `resolved_tags` / `resolved_dimensions` loops are below it. An injected tracer silently loses every `axn.tag.*` and `axn.dimension.*` attribute on any failure or exception.

Guard the assignment and only the assignment. Hoisting the facet loops above the error branch would also fix the stranding, but it puts user-supplied facet procs first, so a facet proc that raises would newly strand `record_exception` — trading one stranding for another. `span.record_exception` is duck-typed on the span and stays unconditional, so an injected non-OTel tracer keeps the exception and every facet, losing only the status object, which is the one thing that genuinely requires OpenTelemetry to construct.

**Files:**
- Modify: `lib/axn/core/executor.rb:153-157`
- Test: `spec/axn/configuration/tracer_spec.rb`

**Interfaces:**
- Consumes: `Axn.config.tracer` (Task 4), the tracer-presence gate (Task 5), the `FakeSpan` stand-in defined in Task 5's spec file.
- Produces: no new API.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/configuration/tracer_spec.rb`, inside the outer describe:

```ruby
  describe "span finalization without OpenTelemetry" do
    let(:span) { FakeSpan.new }
    let(:tracer) do
      Class.new do
        def initialize(span) = @span = span
        def in_span(_name, **) = yield(@span)
      end.new(span)
    end

    let(:failing_axn) do
      build_axn do
        tag :account, -> { "acct-1" }
        dimension :kind, -> { "widget" }

        def call = fail!("nope")
      end
    end

    before { Axn.config.tracer = tracer }

    it "records declared facets on the span even though the OTel Status class is absent" do
      expect(defined?(OpenTelemetry)).to be_nil
      failing_axn.call
      expect(span.attributes).to include(
        "axn.outcome" => "failure",
        "axn.tag.account" => "acct-1",
        "axn.dimension.kind" => "widget",
      )
    end

    it "still records the exception on the span" do
      expect(span).to receive(:record_exception)
      failing_axn.call
    end
  end
```

The `tag :name, -> { … }` / `dimension :name, -> { … }` form matches `spec/axn/internal/tracing/tagging_spec.rb:160,174`. `build_axn` (from `Axn::Testing::SpecHelpers`, already included globally) `class_eval`s its block, so `def call = fail!("nope")` inside it is valid.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/configuration/tracer_spec.rb -e "span finalization without OpenTelemetry"`
Expected: FAIL — `span.attributes` contains only `"axn.outcome"`, because `OpenTelemetry::Trace::Status` raised `NameError` before the facet loops ran.

- [ ] **Step 3: Implement**

In `lib/axn/core/executor.rb`, replace the error branch inside `finalize_span`:

```ruby
          if %w[failure exception].include?(outcome) && result.exception
            span.record_exception(result.exception)

            # The only OpenTelemetry constant left in this path, and a configured tracer can be in
            # use with OpenTelemetry never loaded. Guarding just this assignment keeps the facet
            # attributes below reachable; there is no vendor-neutral way to construct a Status, so a
            # non-OTel tracer gets the recorded exception without an error status.
            if defined?(OpenTelemetry::Trace::Status)
              error_message = result.exception.message || result.exception.class.name
              span.status = OpenTelemetry::Trace::Status.error(error_message)
            end
          end
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/axn/configuration/tracer_spec.rb spec/axn/internal/tracing/`
Expected: PASS. The existing OTel specs still assert `span.status=` is set, and they `stub_const` a fake `Trace::Status`, so the guard is satisfied there.

Run: `bundle exec rspec`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/axn/core/executor.rb spec/axn/configuration/tracer_spec.rb
git add lib/axn/core/executor.rb spec/axn/configuration/tracer_spec.rb
git commit -m "PRO-3017: keep span facet attributes when OpenTelemetry is unloaded"
```

---

### Task 7: Documentation and CHANGELOG

**Files:**
- Modify: `docs/reference/configuration.md` (the "OpenTelemetry Tracing" section, starting `:252`)
- Modify: `CHANGELOG.md` (the topmost version section)

**Interfaces:**
- Consumes: the full public surface from Tasks 3-6.
- Produces: no code.

- [ ] **Step 1: Document the three states**

In `docs/reference/configuration.md`, the section currently opens: "Axn automatically creates OpenTelemetry spans for all action executions when OpenTelemetry is available." Change "when OpenTelemetry is available" to "when a tracer is available — by default, the OpenTelemetry tracer when OpenTelemetry is loaded." Then add a subsection immediately after the attribute list and before "### Basic Setup":

````markdown
### Supplying or disabling the tracer

`Axn.config.tracer` decides which tracer receives axn's spans, and has three states.

Leave it unset — the default — and axn auto-detects: it uses the OpenTelemetry tracer when OpenTelemetry is loaded, and creates no spans otherwise. Detection re-runs on every action, so OpenTelemetry configured later in boot is still picked up.

Assign a tracer to use it instead, whether or not OpenTelemetry is loaded. Anything responding to `in_span(name, attributes:)` and yielding a span works — a differently-named instrumentation scope, a custom provider, or a test fake:

```ruby
Axn.configure do |c|
  c.tracer = OpenTelemetry.tracer_provider.tracer("my-app.axn", "1.0.0")
end
```

Assign `nil` to turn axn's spans off without unloading OpenTelemetry — the rest of your instrumentation keeps working:

```ruby
Axn.configure { |c| c.tracer = nil }
```

`Axn.config.reset!(:tracer)` returns to auto-detection, which is what a spec that installs a fake tracer wants in its teardown. Note that assigning `nil` is a value, not a reset.

A tracer that is not OpenTelemetry's receives the span, its `axn.resource` / `axn.outcome` attributes, every `axn.tag.*` and `axn.dimension.*` facet, and `record_exception` for a failure — but not an error `Status`, which can only be constructed through OpenTelemetry's own class.
````

- [ ] **Step 2: Write the CHANGELOG entries**

Add to the topmost version section of `CHANGELOG.md`, matching the surrounding `* [FEAT] …` / `* [BREAKING] …` style and its level of detail:

```markdown
* [FEAT] `Axn.config.tracer` supplies or disables the tracer that receives axn's `axn.call` spans. Unset auto-detects (the OpenTelemetry tracer when OpenTelemetry is loaded, no spans otherwise); an object receives spans whether or not OpenTelemetry is loaded; `nil` turns axn's spans off without unloading OpenTelemetry. Spans are now gated on a tracer being present rather than on `OpenTelemetry` being defined, and a non-OpenTelemetry tracer receives the full span — attributes, `tag`/`dimension` facets, and `record_exception` — everything but an error `Status`, which only OpenTelemetry can construct.
* [FEAT] `Axn.config.reset!(:setting)` (and `reset!` with no arguments) returns settings to their declared defaults — the supported alternative to assigning `nil`, which is a value rather than a reset. Available on every `Axn::Configurable` config, including an adapter gem's own.
* [BREAKING] `Axn::Configurable`'s `setting … callable: true` is removed. A Proc `default:` is now dynamic on its own — re-derived on every read while the setting is unset, and never cached — so a default that depends on host-app boot state stays correct. An assigned value is always used as-is, including a Proc and including `nil`.
```

- [ ] **Step 3: Verify the docs build and the examples are honest**

Run: `bundle exec rspec`
Expected: PASS.

Run: `grep -rn "Internal::Tracing" docs/`
Expected: no matches — the docs must not point anyone at an internal constant.

Read back the subsection you added and confirm every claim matches what Tasks 4-6 implemented, in particular that a non-OTel tracer really does get facets (Task 6's test) and really does not get a `Status`.

- [ ] **Step 4: Commit**

```bash
git add docs/reference/configuration.md CHANGELOG.md
git commit -m "PRO-3017: document the configured tracer seam"
```

---

## Downstream snippets (do not apply from this repo)

Both land after this branch merges, in their own repos. Include them in the PR description so they are at hand.

**`axn-ruby_llm`**, branch `kali/pro-2771-axn-ruby_llm-adopt-axn-configuration-dsl`, replacing the `Axn::Internal::Tracing` stub at `spec/axn/ruby_llm/ask_spec.rb:550`. With `verify_partial_doubles` on, that stub fails loudly once the method is gone rather than silently no-opping.

```ruby
# was: allow(Axn::Internal::Tracing).to receive(:tracer).and_return(fake_axn_tracer)
let(:fake_axn_tracer) do
  # `in_span` must be stubbed BEFORE the assignment below: the config writer validates
  # `respond_to?(:in_span)`, and a verifying double only responds to what it has been stubbed with.
  instance_double("OpenTelemetry::Trace::Tracer").tap do |tracer|
    allow(tracer).to receive(:in_span).and_yield(fake_axn_span)
  end
end

before { Axn.config.tracer = fake_axn_tracer }
after  { Axn.config.reset!(:tracer) }
```

**`slack_sender`**, into its currently-open upgrade PR — `lib/slack_sender/configuration.rb`. Drops the removed kwarg and corrects the comment, whose claim about `nil` is wrong today and stays wrong after this change.

```ruby
# Whether messages are redirected/suppressed for non-production. A dynamic default derives from
# Rails.env on each read while unset; an explicit true/false wins. An explicit nil is a VALUE, not a
# reset — it reads back as nil, making `sandbox_mode?` false (sandbox off). Use
# `SlackSender.config.reset!(:sandbox_mode)` to return to derivation. Marked overridable so an
# individual action can opt in/out of sandbox for its own sends via `configure(:slack_sender)`
# (resolved in the strategy and threaded down to DeliveryAxn).
setting :sandbox_mode,
        default: -> { defined?(Rails) && Rails.respond_to?(:env) ? !Rails.env.production? : true },
        overridable: true
```

Also grep that PR for an actual `sandbox_mode = nil` assignment. If one exists it is a live bug — non-production sends going out for real — independent of this work.
