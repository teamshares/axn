# frozen_string_literal: true

# `include Axn` puts helpers on the user's class, and the user may take any of those names — with a
# `def`, or with a field declaration whose generated reader lands on the same class. Taking one must
# cost them that helper and nothing else: axn's own machinery reaches its implementations through
# `Internal::ActionState`, which binds a method object no shadow can intercept.
#
# A grep cannot prove this. `result.respond_to?(key)` is indistinguishable from a local named
# `result`, and a self-send has no receiver to match on at all. So the coverage here is behavioural:
# shadow each name, run an action, and check that the paths the user did NOT take still work.
RSpec.describe "shadowing an axn instance method" do
  # A swallowed internal error must fail an example here, not print a warning and pass. Every one of
  # these actions runs its exception-report and logging paths, and those live inside `best_effort` —
  # which absorbs whatever they raise, so a broken funnel would otherwise look green.
  around do |example|
    swallowed = []
    original = Axn.config.instance_variable_get(:@on_ignored_exception)
    # Read back through the ivar, not the reader: `Axn.config.on_ignored_exception` is the DISPATCH
    # (it takes the exception and invokes the configured handler), not an accessor for the setting.
    Axn.config.on_ignored_exception = ->(exception, **) { swallowed << exception }

    example.run

    Axn.config.instance_variable_set(:@on_ignored_exception, original)
    expect(swallowed).to be_empty, "axn swallowed #{swallowed.map(&:class).join(', ')} into a side channel"
  end

  it "does not corrupt the framework when `result` is shadowed by a def" do
    klass = build_axn do
      exposes :out
      def result = "shadowed"
      def call = expose(out: 1)
    end

    result = klass.call

    expect(result).to be_ok
    expect(result.out).to eq(1)
  end

  it "does not corrupt the framework when `result` is shadowed by a declaration" do
    klass = build_axn do
      expects :result
      exposes :out
      def call = expose(out: result * 2)
    end

    outcome = klass.call(result: 21)

    expect(outcome).to be_ok
    expect(outcome.out).to eq(42)
  end

  # Every generated field reader resolves its value through the inbound facade, so taking that name used
  # to cost the user EVERY other field's reader rather than one helper: `def internal_context` made a
  # sibling reader read off the user's object, and `expects :internal_context` made the generated reader
  # call itself (SystemStackError). Both shapes are in the matrix below; these two name the corruption
  # directly, and pin that the facade is no longer part of the public surface a user has to work around.
  it "does not poison every other field's reader when `internal_context` is declared" do
    klass = build_axn do
      expects :internal_context, :other
      exposes :out
      def call = expose(out: "#{internal_context}/#{other}")
    end

    result = klass.call(internal_context: "mine", other: "theirs")

    expect(result).to be_ok
    expect(result.out).to eq("mine/theirs")
  end

  it "does not poison every other field's reader when `internal_context` is shadowed by a def" do
    klass = build_axn do
      expects :given
      exposes :out
      def internal_context = "taken by the user"
      def call = expose(out: given * 2)
    end

    result = klass.call(given: 21)

    expect(result).to be_ok
    expect(result.out).to eq(42)
  end

  it "no longer injects internal_context as public surface" do
    expect(build_axn {}.public_method_defined?(:internal_context)).to be false
  end

  it "injects no unprefixed class_attribute accessors onto the instance" do
    leaked = build_axn {}.public_instance_methods.grep_v(/\A_/) &
             %i[before_hooks after_hooks around_hooks internal_field_configs
                external_field_configs subfield_configs]

    expect(leaked).to be_empty
  end

  it "exposes a field named for a config accessor without breaking the Result" do
    klass = build_axn do
      exposes :out
      def call = expose(out: 1)
    end

    expect(klass.call.out).to eq(1)
  end

  describe "the sugar matrix" do
    # Every name `include Axn` puts on the instance. `expose` is handled on its own below, because an
    # action that has lost it cannot use it to produce the exposure the other examples check.
    shadowable_by_def = %i[
      result inputs log debug info warn error fatal
      execution_context ambient_context default_error default_success
      fail! done! forward! internal_context
    ].freeze

    # The subset a field declaration can take. The rest are rejected by `expects`: `ambient_context` is
    # a sentinel the subfield resolver compares roots against rather than a convenience,
    # `default_error`/`default_success` are owned by the inbound facade the value is read from, and
    # `fail!`/`done!` are owned there too (ContextFacade#fail!).
    shadowable_by_declaration = %i[
      result inputs expose log debug info warn error fatal execution_context internal_context forward!
    ].freeze

    def shadowing(name, &declaration)
      build_axn(&declaration).tap do |klass|
        klass.send(:define_method, name) { |*, **| :taken_by_the_user }
      end
    end

    shadowable_by_def.each do |name|
      it "still runs, exposes, and logs when `#{name}` is shadowed by a def" do
        logged = []
        klass = shadowing(name) do
          expects :given
          exposes :out
          def call = expose(out: given * 2)
        end
        allow(klass).to receive(:log) { |msg, **| logged << msg }

        result = klass.call(given: 21)

        expect(result).to be_ok
        expect(result.out).to eq(42)
        expect(logged).to include(a_string_including("About to execute"))
      end

      it "still reports the exception with full context when `#{name}` is shadowed by a def" do
        reports = []
        klass = shadowing(name) do
          expects :given
          exposes :out
          def call = raise("boom")
        end

        with_global_reporter(reports) { expect(klass.call(given: 21)).not_to be_ok }

        expect(reports.size).to eq(1)
        expect(reports.first[:context]).to include(inputs: { given: 21 })
      end
    end

    shadowable_by_declaration.each do |name|
      it "still runs and exposes when `#{name}` is taken by a field declaration" do
        klass = build_axn do
          expects :given
          exposes :out
          def call = done!(out: given * 2)
        end
        klass.class_eval { expects(name) }

        result = klass.call(given: 21, name => "an input value")

        expect(result).to be_ok
        expect(result.out).to eq(42)
      end

      it "hands the user their own value back for `#{name}`" do
        klass = build_axn { expects :given }
        klass.class_eval { expects(name) }

        expect(klass.send(:new, given: 1, name => "an input value").public_send(name)).to eq("an input value")
      end
    end

    # `expose` is the one helper whose loss the user cannot route around, so these check the routes
    # axn itself owns: `fail!`, `done!`, and the default `#call`'s auto-exposure.
    it "still exposes from fail! when `expose` is shadowed" do
      klass = build_axn do
        exposes :out
        def expose(*) = nil
        def call = fail!("nope", out: 3)
      end

      result = klass.call

      expect(result.error).to eq("nope")
      expect(result.out).to eq(3)
    end

    it "still exposes from done! when `expose` is shadowed" do
      klass = build_axn do
        exposes :out
        def expose(*) = nil
        def call = done!(out: 3)
      end

      result = klass.call

      expect(result).to be_ok
      expect(result.out).to eq(3)
    end

    it "still auto-exposes a declared exposure when `expose` is shadowed" do
      klass = build_axn do
        exposes :out
        def expose(*) = nil
        def out = 3
      end

      result = klass.call

      expect(result).to be_ok
      expect(result.out).to eq(3)
    end

    it "still forwards a sub-action's exposures when `expose` is shadowed" do
      child = build_axn do
        exposes :out
        def call = expose(out: 3)
      end
      klass = build_axn do
        exposes :out
        def expose(*) = nil
        define_method(:call) { forward!(child) }
      end

      result = klass.call

      expect(result).to be_ok
      expect(result.out).to eq(3)
    end

    it "still passes a step chain its resolved inputs when `inputs` is shadowed" do
      klass = shadowing(:inputs) do
        expects :given
        exposes :out
        step :double, expects: [:given], exposes: [:out] do
          expose(out: given * 2)
        end
      end

      result = klass.call(given: 21)

      expect(result).to be_ok
      expect(result.out).to eq(42)
    end

    it "still hands `forward!` the caller's resolved inputs when `inputs` is shadowed" do
      child = build_axn do
        expects :given
        exposes :out
        def call = expose(out: given * 2)
      end
      klass = shadowing(:inputs) do
        expects :given
        exposes :out
        define_method(:call) { forward!(child) }
      end

      result = klass.call(given: 21)

      expect(result).to be_ok
      expect(result.out).to eq(42)
    end

    # The step orchestrator settles the PARENT by failing it, so a shadowed `fail!` does not cost the
    # user a helper — it makes the failure never happen, and a chain whose step failed reports success.
    it "still settles the parent as a failure when a step fails and `fail!` is shadowed" do
      klass = shadowing(:fail!) do
        step(:inner) { fail! "inner boom" }
      end

      result = klass.call

      expect(result).not_to be_ok
      expect(result.error).to eq("inner: inner boom")
    end

    it "still settles the parent when `fail!` is shadowed and the step's own fail! is its user's" do
      child = build_axn { def call = fail!("child boom") }
      klass = shadowing(:fail!) { step :inner, child }

      result = klass.call

      expect(result).not_to be_ok
      expect(result.error).to eq("inner: child boom")
    end

    # The form strategy's `before` hook is axn's own machinery: it exposes the built form and gates the
    # action on its validity. A shadow taking either name would leave the exposure unwritten (an
    # outbound contract violation) or the invalid form unreported.
    describe "the form strategy's before hook" do
      let(:form_class) do
        Class.new(Axn::FormObject) do
          attr_accessor :foo

          validates :foo, presence: true
        end
      end

      # A `#call` of its own, deliberately: the default `#call` would auto-expose the memoized form
      # reader on its own and mask whether the hook's exposure landed.
      it "still exposes the form when `expose` is shadowed by a def" do
        klass = shadowing(:expose) { def call = nil }
        klass.use(:form, type: form_class)

        result = klass.call(params: { foo: "bar" })

        expect(result).to be_ok
        expect(result.form).to be_a(form_class)
      end

      it "still exposes the form when `expose` is taken by a field declaration" do
        klass = build_axn { expects :expose }
        klass.use(:form, type: form_class)

        result = klass.call(params: { foo: "bar" }, expose: "an input value")

        expect(result).to be_ok
        expect(result.form).to be_a(form_class)
      end

      it "still fails the action on an invalid form when `fail!` is shadowed by a def" do
        klass = shadowing(:fail!) {}
        klass.use(:form, type: form_class)

        expect(klass.call(params: { foo: nil })).not_to be_ok
      end
    end

    # `Factory.build` takes `superclass:` / `include:` / `prepend:`, all public API — so the generated
    # #call runs on a class that may carry the user's own `expose`.
    it "still exposes the return value when a factory-built action's `expose` is shadowed" do
      shadow = Module.new { def expose(*, **) = :taken_by_the_user }
      klass = Axn::Factory.build(expose_return_as: :out, include: [shadow]) { 3 }

      result = klass.call

      expect(result).to be_ok
      expect(result.out).to eq(3)
    end

    it "still forwards a Result handed to `expose` when `_expose_from_result` is shadowed" do
      klass = build_axn do
        exposes :out
        def _expose_from_result(*, **) = :taken_by_the_user
        def call = expose(Axn::Result.ok(out: 3))
      end

      result = klass.call

      expect(result).to be_ok
      expect(result.out).to eq(3)
    end

    it "still redacts a sensitive field whose predicate raises when `warn` is shadowed" do
      logged = []
      klass = shadowing(:warn) do
        expects :ssn, sensitive: :broken_check

        def call = nil

        private

        def broken_check(_unexpected_arg) = true
      end
      allow(klass).to receive(:log) { |msg, **| logged << msg }

      expect(klass.call(ssn: "123-45-6789")).to be_ok
      expect(logged).to include(a_string_matching(/sensitive: :ssn \(:broken_check\) raised ArgumentError/))
    end

    # `ambient_context` is axn's own reserved parent (`expects :ambient_context` is refused), so an
    # ambient subfield must read the framework's value however the class is shaped. A dispatched read
    # fed the user's object to the ambient filter, which reported the resulting absence as a bogus
    # "can't be blank" on the subfield rather than an error naming the cause.
    it "still resolves an ambient subfield when `ambient_context` is shadowed by a def" do
      klass = shadowing(:ambient_context) do
        expects :tenant, on: :ambient_context
        exposes :out
        def call = expose(out: tenant)
      end

      result = with_ambient_provider(-> { { tenant: "acme" } }) { klass.call }

      expect(result).to be_ok
      expect(result.out).to eq("acme")
    end

    def with_ambient_provider(provider)
      previous = Axn.config.ambient_context_provider
      Axn.config.ambient_context_provider = provider
      yield
    ensure
      Axn.config.ambient_context_provider = previous
    end

    def with_global_reporter(reports)
      previous = Axn.config.instance_variable_get(:@on_exception)
      Axn.config.on_exception = ->(e, action:, context:) { reports << { exception: e, action:, context: } }
      yield
    ensure
      Axn.config.instance_variable_set(:@on_exception, previous)
    end
  end
end
