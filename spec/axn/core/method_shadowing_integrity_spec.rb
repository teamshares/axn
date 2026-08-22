# frozen_string_literal: true

begin
  require "faraday"
rescue LoadError
  # An optional peer dependency: the client-strategy examples below skip without it.
end

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
    # Every name `include Axn` puts on the instance — `MethodShadowing.deferrable_names` plus
    # `internal_context`, which is private (so it's outside that public-only list by design) but is
    # still guarded by `NameOwnership` exactly like the public sugar (see its comment there). `expose`
    # is excluded and handled on its own below, because an action that has lost it cannot use it to
    # produce the exposure the other examples check.
    shadowable_by_def = (Axn::Core::MethodShadowing.deferrable_names + [:internal_context] - [:expose]).freeze

    # The subset a field declaration can take. The rest are rejected by `expects`: `ambient_context` is
    # a sentinel the subfield resolver compares roots against rather than a convenience (deferrable,
    # per DEFERRAL_SOURCES, but not surrenderable to a declaration), and `default_error`/
    # `default_success`/`fail!` are owned by the inbound facade the value is read from (InternalContext's
    # own two, and ContextFacade#fail!).
    # `done!` is declarable too, but it is exercised on its own below: the generic rows settle through
    # `done!`, so an action that has surrendered it cannot produce the exposure they check.
    shadowable_by_declaration = (Axn::Core::MethodShadowing.deferrable_names + [:internal_context] -
                                  %i[ambient_context default_error default_success fail! done!]).freeze

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

    # `done!` is surrendered by a declaration like any other convenience — early completion is then the
    # user's own value, and every other route to settling still works.
    it "still runs and exposes when `done!` is taken by a field declaration" do
      klass = build_axn do
        expects :given, :done!
        exposes :out
        def call = expose(out: given * 2)
      end

      result = klass.call(given: 21, done!: "an input value")

      expect(result).to be_ok
      expect(result.out).to eq(42)
    end

    it "hands the user their own value back for `done!`" do
      klass = build_axn { expects :given, :done! }

      expect(klass.send(:new, given: 1, done!: "an input value").done!).to eq("an input value")
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

    # The client strategy's middleware annotates the action with the last request it made, so an
    # exception report names the call that preceded it. It writes that annotation onto the action
    # instance, and `set_execution_context` is ordinary sugar the user may take — so a `respond_to?`
    # probe there answers for the user's field reader just as truthfully as for the real method, and
    # the write lands on a reader that takes no arguments.
    describe "the client strategy's request annotation" do
      let(:klass) do
        build_axn do
          expects :set_execution_context
          exposes :status, :annotated

          use :client, url: "https://api.example.com" do |conn|
            conn.adapter :test do |stub|
              stub.get("/users") { [200, { "Content-Type" => "application/json" }, "{}"] }
            end
          end

          def call
            expose(status: client.get("/users").status,
                   annotated: execution_context[:client_strategy__last_request])
          end
        end
      end

      before { skip "Faraday is not available" unless defined?(Faraday) }

      it "still completes the request when `set_execution_context` is taken by a field declaration" do
        result = klass.call(set_execution_context: "an input value")

        expect(result).to be_ok
        expect(result.status).to eq(200)
      end

      it "still annotates the action with the last request" do
        result = klass.call(set_execution_context: "an input value")

        expect(result.annotated).to include(url: a_string_matching(/api\.example\.com.*users/), method: "GET", status: 200)
      end

      it "hands the user their own value back for `set_execution_context`" do
        expect(klass.send(:new, set_execution_context: "an input value").set_execution_context).to eq("an input value")
      end
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

  # The matrix above shadows each name with a `def` on the action itself. This is the other half of the same
  # grid: the name is declared by the user's own HIERARCHY, so axn steps aside for it at include time and the
  # action runs with a wrapper standing in front of axn's helper. Driven off `deferrable_names` rather than a
  # list, so a helper added to a sugar module later is covered here without editing this file.
  #
  # Its job is the sweep the per-feature files do not do: `instance_deferral_spec.rb` proves each behaviour once,
  # on `log` (and `info`), which cannot show a name the mechanism handles differently — a `_collect` that skips
  # one, a `prefer_axn` that cannot find axn's definition of one, a guard that refuses one outright.
  describe "the inherited shape of the sugar matrix" do
    Axn::Core::MethodShadowing.deferrable_names.each do |name|
      context "##{name}" do
        # Anonymous and built per example, so the once-per-`(definer, name)` warning record cannot carry an
        # announcement from one row into the next.
        let(:parent) { Class.new { define_method(name) { |*| :parent_implementation } } }

        it "hands the name to the inherited implementation" do
          action = Class.new(parent) { include Axn }

          expect(action.send(:new).public_send(name)).to eq(:parent_implementation)
        end

        # Two questions the record answers and a re-walk cannot: the deferral is scoped to the name that
        # collided, and the shim — which is now the nearest declarer of that name — reports the module it stands
        # in for rather than itself.
        it "surrenders that name only, and names the definer rather than its own shim" do
          action = Class.new(parent) { include Axn }

          expect(Axn::Core::InstanceDeferral.definers(action).keys).to eq([name])
          expect(Axn::Internal::NameOwnership.owner_of(action, name)).to eq(parent)
        end

        # Settles through the default `#call`'s auto-exposure rather than through `expose`, because `expose` is
        # itself one of the names this loop covers: an action that has surrendered it cannot use it to produce
        # the exposure the row checks, and the route would make that one name the odd one out for a reason
        # unrelated to the mechanism.
        it "still runs the action end to end" do
          action = Class.new(parent) do
            include Axn
            expects :given
            exposes :out
            def out = given * 2
          end

          result = action.call(given: 21)

          expect(result).to be_ok
          expect(result.out).to eq(42)
        end

        # The shim is INCLUDED, so a `def` in the class body still outranks it and `super` reaches the inherited
        # implementation through it. Prepended instead, the wrapper would answer first and the author's own
        # method would never run; absent altogether, `super` would reach axn's helper rather than the parent's.
        it "reaches the inherited implementation from super in the class body" do
          action = Class.new(parent) do
            include Axn
            define_method(name) { |*args| [:wrapped, super(*args)] }
          end

          expect(action.send(:new).public_send(name)).to eq(%i[wrapped parent_implementation])
        end

        describe "the announcement" do
          let(:warnings) { [] }

          before do
            logger = instance_double(Logger, info: nil, debug: nil)
            allow(logger).to receive(:warn) { |message| warnings << message }
            allow(Axn.config).to receive(:logger).and_return(logger)
            Axn::Core::InstanceDeferral.send(:_reset_warned_for_specs!)
          end

          # The positive control for the two silence rows below: without it, a mechanism that announced nothing
          # at all would read as two classes having answered the warning.
          it "names the surrendered helper at the class's first execution" do
            action = Class.new(parent) { include Axn }
            expect(warnings).to be_empty

            action.call

            expect(warnings.size).to eq(1)
            expect(warnings.first).to include("##{name}")
          end

          it "is silent for a class that declared prefer_inherited, which keeps the inherited implementation" do
            action = Class.new(parent) do
              include Axn
              prefer_inherited name
            end

            action.call

            expect(warnings).to be_empty
            expect(action.send(:new).public_send(name)).to eq(:parent_implementation)
          end

          # `prefer_axn` has to find axn's own definition of the name to put it back, and the surrendered helpers
          # are spread across several modules — so which module answers is a per-name question, not one `log`
          # can stand in for.
          it "is silent for a class that declared prefer_axn, which puts axn's implementation back in front" do
            action = Class.new(parent) do
              include Axn
              prefer_axn name
            end

            action.call

            expect(warnings).to be_empty
            owner = Axn::Internal::NameOwnership.owner_of(action, name)
            # `deferral_source?` rather than `surrenderable?`: `ambient_context` is one of the eighteen
            # `deferrable_names` this loop runs over, but it is deliberately excluded from
            # `SURRENDERABLE_OWNERS` (a field declaration may never take that name) — `surrenderable?`
            # would wrongly fail for that one row.
            expect(Axn::Internal::NameOwnership.deferral_source?(owner)).to be true
          end
        end
      end
    end
  end

  # The walk that finds a definer stops at ::Object, so Ruby's own methods are not something axn steps aside
  # for. Untruncated it would defer `warn` to Kernel on EVERY action — silently redirecting `warn("...")` inside
  # an action from the logger to stderr, with no collision the author could see or answer.
  describe "the names Ruby owns" do
    it "defers nothing on an action whose hierarchy is Ruby's alone" do
      # The positive control: this is only worth asserting because Kernel does declare one of the names axn
      # hands over. If that stops being true the example is measuring nothing, and this fails rather than
      # going quietly green.
      kernel_owned = Axn::Core::MethodShadowing.deferrable_names.select do |name|
        Kernel.method_defined?(name) || Kernel.private_method_defined?(name)
      end
      expect(kernel_owned).not_to be_empty

      expect(Axn::Core::InstanceDeferral.definers(build_axn {})).to be_empty
    end

    it "keeps warn on axn's logger rather than Kernel's" do
      messages = []
      logger = instance_double(Logger, info: nil, debug: nil)
      allow(logger).to receive(:warn) { |message| messages << message }
      allow(Axn.config).to receive(:logger).and_return(logger)

      action = build_axn { def call = warn("to the logger") }

      expect { action.call }.not_to output.to_stderr
      expect(messages.join).to include("to the logger")
    end
  end
end
