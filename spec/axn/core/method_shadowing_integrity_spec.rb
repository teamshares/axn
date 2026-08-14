# frozen_string_literal: true

# `include Axn` puts helpers on the user's class, and the user may take any of those names — with a
# `def`, or with a field declaration whose generated reader lands on the same class. Taking one must
# cost them that helper and nothing else: axn's own machinery reaches its implementations through
# `Internal::ActionState`, which binds a method object no shadow can intercept.
#
# A grep cannot prove this. `result.respond_to?(key)` is indistinguishable from a local named
# `result`, and a self-send (`internal_context.public_send(field)` inside `inputs`) has no receiver to
# match on at all. So the coverage here is behavioural: shadow each name, run an action, and check
# that the paths the user did NOT take still work.
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

  describe "the sugar matrix" do
    # Every name `include Axn` puts on the instance. `expose` is handled on its own below, because an
    # action that has lost it cannot use it to produce the exposure the other examples check.
    # `internal_context` is absent because every generated field reader still dispatches it, so taking
    # it poisons the readers rather than costing one helper — the one name still to be freed.
    shadowable_by_def = %i[
      result inputs log debug info warn error fatal
      execution_context ambient_context default_error default_success
      fail! done! forward!
    ].freeze

    # The subset a field declaration can take TODAY. The rest are rejected outright by `expects`
    # (`inputs`, `ambient_context`, `default_error`, `default_success`), or are not legal field names
    # at all (the bang trio).
    shadowable_by_declaration = %i[
      result expose log debug info warn error fatal execution_context
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

    def with_global_reporter(reports)
      previous = Axn.config.instance_variable_get(:@on_exception)
      Axn.config.on_exception = ->(e, action:, context:) { reports << { exception: e, action:, context: } }
      yield
    ensure
      Axn.config.instance_variable_set(:@on_exception, previous)
    end
  end
end
