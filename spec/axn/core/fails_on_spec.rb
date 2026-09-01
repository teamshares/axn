# frozen_string_literal: true

RSpec.describe "fails_on" do
  before { allow(Axn.config).to receive(:on_exception) }

  describe "reclassifying a raised exception as a failure" do
    let(:action) do
      build_axn do
        fails_on ArgumentError

        def call = raise ArgumentError, "bad input"
      end
    end

    subject(:result) { action.call }

    it "settles as a failed result" do
      expect(result).not_to be_ok
    end

    it "reports the outcome as failure, not exception" do
      expect(result.outcome).to eq("failure")
      expect(result.outcome).to be_failure
    end

    it "preserves the original exception (not wrapped in Axn::Failure)" do
      expect(result.exception).to be_a(ArgumentError)
      expect(result.exception.message).to eq("bad input")
    end

    it "skips the global on_exception report" do
      result
      expect(Axn.config).not_to have_received(:on_exception)
    end
  end

  describe "an exception class that is NOT declared" do
    let(:action) do
      build_axn do
        fails_on ArgumentError

        def call = raise "some unexpected issue"
      end
    end

    subject(:result) { action.call }

    it "still reports as an exception" do
      expect(result.outcome).to be_exception
    end

    it "still triggers the global on_exception report" do
      result
      expect(Axn.config).to have_received(:on_exception)
    end
  end

  describe "callbacks" do
    let(:fired) { [] }
    let(:action) do
      recorder = fired
      build_axn do
        fails_on ArgumentError

        on_failure { recorder << :failure }
        on_exception { recorder << :exception }
        on_error { recorder << :error }

        def call = raise ArgumentError, "bad"
      end
    end

    it "fires on_failure and on_error, but not on_exception" do
      action.call
      expect(fired).to contain_exactly(:error, :failure)
    end
  end

  describe "message wiring" do
    it "uses a positional string message" do
      action = build_axn do
        fails_on ArgumentError, "Unable to submit"
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Unable to submit")
    end

    it "uses a block that receives the exception" do
      action = build_axn do
        fails_on(ArgumentError) { |e| "Bad: #{e.message}" }
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Bad: raw")
    end

    it "falls back to the default error message when none given" do
      action = build_axn do
        fails_on ArgumentError
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Something went wrong")
    end

    # Codex review finding (PR #261): `Array(exceptions)` returns the CALLER'S array unchanged when
    # one was passed. Classification already guards against this (`entry.classes` is a frozen dup),
    # but the message gate's closure was reading the bare `classes` local -- the caller's own,
    # mutable array -- so mutating it after `fails_on` returned made classification (still correct,
    # via `entry.classes`) and the message (now checking a different class list) disagree.
    it "the wired message is unaffected by mutating the caller's array after fails_on returns" do
      classes = [ArgumentError]
      action = build_axn do
        fails_on classes, "gated message"
        def call = raise ArgumentError, "raw"
      end

      classes << TypeError
      classes.delete(ArgumentError)

      result = action.call
      expect(result.outcome).to be_failure
      expect(result.error).to eq("gated message")
    end
  end

  describe "standalone: forwarding" do
    it "attaches the message under a declared base by default (standalone omitted)" do
      action = build_axn do
        error "Couldn't save widget"
        fails_on ArgumentError, "Unable to submit"
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Couldn't save widget: Unable to submit")
    end

    it "lets the message stand alone (replacing the base) with standalone: true" do
      action = build_axn do
        error "Couldn't save widget"
        fails_on ArgumentError, "Unable to submit", standalone: true
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Unable to submit")
    end

    it "forwards standalone: for the block form too" do
      action = build_axn do
        error "Couldn't save widget"
        fails_on(ArgumentError, standalone: true) { |e| "Bad: #{e.message}" }
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Bad: raw")
    end

    it "raises at declaration when standalone: true is passed without a message or block" do
      expect do
        build_axn { fails_on ArgumentError, standalone: true }
      end.to raise_error(ArgumentError, /standalone: has no effect without a message or block/)
    end

    it "raises for standalone: false without a message or block too (inert either way)" do
      expect do
        build_axn { fails_on ArgumentError, standalone: false }
      end.to raise_error(ArgumentError, /standalone: has no effect without a message or block/)
    end

    it "leaves bare fails_on (no standalone:) untouched" do
      action = build_axn do
        fails_on ArgumentError
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Something went wrong")
    end
  end

  describe "multiple exception classes (array)" do
    let(:action) do
      build_axn do
        fails_on [ArgumentError, KeyError], "Couldn't process"

        expects :which
        def call
          raise ArgumentError, "a" if which == :arg
          raise KeyError, "k" if which == :key

          raise "other"
        end
      end
    end

    it "reclassifies each listed class" do
      expect(action.call(which: :arg).outcome).to be_failure
      expect(action.call(which: :key).outcome).to be_failure
    end

    it "wires the message for any of them (OR semantics, not AND)" do
      expect(action.call(which: :arg).error).to eq("Couldn't process")
      expect(action.call(which: :key).error).to eq("Couldn't process")
    end

    it "leaves unlisted exceptions as reported exceptions" do
      expect(action.call(which: :other).outcome).to be_exception
    end
  end

  describe "invalid arguments" do
    it "rejects a non-Exception class" do
      expect do
        build_axn { fails_on String }
      end.to raise_error(ArgumentError, /requires one or more Exception classes/)
    end

    # An exception axn never absorbs into a result is raised straight through `.call` and never reaches
    # failure classification, so the declaration would be inert. Silence is the worst outcome here: the
    # entire point of `fails_on` is to reclassify, so a caller would reasonably believe it had.
    describe "a class axn never converts into a result" do
      {
        "a signal" => Interrupt,
        "an exit" => SystemExit,
        "resource exhaustion" => NoMemoryError,
      }.each do |label, klass|
        it "rejects #{label} (#{klass}) at declaration, naming it and the reason" do
          expect do
            build_axn { fails_on klass }
          end.to raise_error(ArgumentError, /fails_on cannot reclassify #{klass}.*never converts it into a result/m)
        end
      end

      it "rejects a library's own control-flow signal" do
        gem_signal = Class.new(Exception) # rubocop:disable Lint/InheritException

        expect do
          build_axn { fails_on gem_signal }
        end.to raise_error(ArgumentError, /cannot reclassify/)
      end

      it "names every offender when several are listed at once" do
        expect do
          build_axn { fails_on [ArgumentError, Interrupt, SystemExit] }
        end.to raise_error(ArgumentError, /reclassify Interrupt, SystemExit/)
      end
    end

    # Reachable classes stay accepted — including `Exception`, which still catches everything axn absorbs.
    [StandardError, ArgumentError, Exception, SystemStackError, ScriptError, NotImplementedError].each do |klass|
      it "accepts #{klass}" do
        expect { build_axn { fails_on klass } }.not_to raise_error
      end
    end
  end

  describe "conditional classification (if:/unless:)" do
    describe "if:" do
      it "reclassifies when the condition is true" do
        action = build_axn do
          fails_on ArgumentError, if: -> { true }
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        expect(result.outcome).to be_failure
        expect(Axn.config).not_to have_received(:on_exception)
      end

      it "does not reclassify when the condition is false, and still reports globally" do
        action = build_axn do
          fails_on ArgumentError, if: -> { false }
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        expect(result.outcome).to be_exception
        expect(Axn.config).to have_received(:on_exception)
      end

      it "resolves a Symbol against a public action method" do
        action = build_axn do
          fails_on ArgumentError, if: :reclassify?
          def reclassify? = true
          def call = raise ArgumentError, "boom"
        end

        expect(action.call.outcome).to be_failure
      end

      # Pre-existing `Handlers::SingleRuleMatcher` behavior (shared with `error`/`success`/callbacks),
      # not something this ticket changes: the Symbol-resolves-to-an-action-method check uses a
      # PUBLIC-only `respond_to?`, so a private method name falls through to the constant-lookup
      # branch, fails that too, and reads as "no match" (with a warning logged) rather than an error.
      # Worth knowing since `fails_on if: :some_private_predicate?` is a natural spelling to reach for.
      it "does NOT resolve a Symbol naming a private action method -- falls through to no match" do
        action = build_axn do
          fails_on ArgumentError, if: :reclassify?
          def call = raise ArgumentError, "boom"

          private

          def reclassify? = true
        end

        expect(action.call.outcome).to be_exception
      end

      it "self inside the condition is the action -- reads an expects reader" do
        action = build_axn do
          expects :allow_reclassify, type: :boolean
          fails_on ArgumentError, if: -> { allow_reclassify }
          def call = raise ArgumentError, "boom"
        end

        expect(action.call(allow_reclassify: true).outcome).to be_failure
        expect(action.call(allow_reclassify: false).outcome).to be_exception
      end
    end

    describe "unless:" do
      it "does not reclassify when the condition is true" do
        action = build_axn do
          fails_on ArgumentError, unless: -> { true }
          def call = raise ArgumentError, "boom"
        end

        expect(action.call.outcome).to be_exception
      end

      it "reclassifies when the condition is false" do
        action = build_axn do
          fails_on ArgumentError, unless: -> { false }
          def call = raise ArgumentError, "boom"
        end

        expect(action.call.outcome).to be_failure
      end

      # Codex review finding (PR #261): a raising unless: rule was coerced to a definite `false`
      # ("no match") and then INVERTED to `true` ("match") -- turning a broken condition into a
      # silent reclassification that suppressed the global report for a genuine bug. Fixed at the
      # shared Handlers::Matcher layer (see matcher_spec.rb); this pins the fails_on-visible
      # consequence specifically, since it's the one place this silently swallows a real report.
      it "a raising condition stays inert -- the exception is NOT reclassified, and still reports" do
        action = build_axn do
          fails_on ArgumentError, unless: -> { raise "boom in unless condition" }
          def call = raise ArgumentError, "a real bug"
        end

        result = action.call
        expect(result.outcome).to be_exception
        expect(Axn.config).to have_received(:on_exception)
      end

      it "a raising Symbol condition stays inert too" do
        action = build_axn do
          fails_on ArgumentError, unless: :broken_predicate?
          def broken_predicate? = raise("boom")
          def call = raise ArgumentError, "a real bug"
        end

        result = action.call
        expect(result.outcome).to be_exception
        expect(Axn.config).to have_received(:on_exception)
      end

      # Codex review finding (PR #261), round 6: a DIFFERENT path to the same class of bug as
      # above. `unless: :typo'd_symbol` -- one that names neither an action method nor a real
      # constant -- falls through `apply_symbol`'s NameError-rescue branch, which logged a warning
      # and returned a bare `false`, not the SWALLOWED sentinel. `#call` only special-cased `nil`/
      # `SWALLOWED` before inverting, so this bare `false` got treated as a GENUINE answer and
      # inverted to `true` for `unless:` -- an unresolved Symbol silently reclassified a real bug
      # exactly like a raising one did. Fixed by returning SWALLOWED there too (and from
      # `handle_invalid`, the other "rule never ran" path) -- see matcher_spec.rb.
      it "an unresolved Symbol (names neither a method nor a constant) stays inert too" do
        action = build_axn do
          fails_on ArgumentError, unless: :this_method_does_not_exist_anywhere_zzz
          def call = raise ArgumentError, "a real bug"
        end

        result = action.call
        expect(result.outcome).to be_exception
        expect(Axn.config).to have_received(:on_exception)
      end
    end

    describe "if: and unless: combined (ANDed)" do
      [
        [true, false, :failure],
        [true, true, :exception],
        [false, false, :exception],
        [false, true, :exception],
      ].each do |if_val, unless_val, expected|
        it "if: #{if_val}, unless: #{unless_val} -> #{expected}" do
          action = build_axn do
            fails_on ArgumentError, if: -> { if_val }, unless: -> { unless_val }
            def call = raise ArgumentError, "boom"
          end

          expect(action.call.outcome.to_sym).to eq(expected)
        end
      end
    end

    describe "condition receivers" do
      it "a 1-arity proc receives the exception positionally" do
        action = build_axn do
          fails_on ArgumentError, if: ->(e) { e.message == "boom" }
          def call = raise ArgumentError, "boom"
        end

        expect(action.call.outcome).to be_failure
      end

      it "a proc with an exception: kwarg receives it as a kwarg" do
        action = build_axn do
          fails_on ArgumentError, if: ->(exception:) { exception.message == "boom" }
          def call = raise ArgumentError, "boom"
        end

        expect(action.call.outcome).to be_failure
      end
    end

    describe "message composition" do
      it "applies the wired message when the gate is open" do
        action = build_axn do
          fails_on ArgumentError, "Unable to submit", if: -> { true }
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        expect(result.outcome).to be_failure
        expect(result.error).to eq("Unable to submit")
      end

      # The ticket's headline footgun: before if:, a condition INSIDE the message proc looked like it
      # gated reclassification too -- it never did. Now if: gates both together: a closed gate means
      # the exception stays unreclassified AND the message never surfaces.
      it "does not apply the wired message when the gate is closed" do
        action = build_axn do
          fails_on ArgumentError, "Unable to submit", if: -> { false }
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        expect(result.outcome).to be_exception
        expect(result.error).to eq("Something went wrong")
        expect(Axn.config).to have_received(:on_exception)
      end

      it "composes standalone: true with an open if: gate" do
        action = build_axn do
          error "Couldn't save widget"
          fails_on ArgumentError, "Unable to submit", standalone: true, if: -> { true }
          def call = raise ArgumentError, "boom"
        end

        expect(action.call.error).to eq("Unable to submit")
      end
    end

    describe "multiple entries OR" do
      it "an unconditional declaration still reclassifies even when a later conditional one on the same class is closed" do
        action = build_axn do
          fails_on ArgumentError
          fails_on ArgumentError, if: -> { false }
          def call = raise ArgumentError, "boom"
        end

        expect(action.call.outcome).to be_failure
      end

      # Self-review finding (not from Codex): `_fails_on?` originally short-circuited on the first
      # matching entry (`.any? { ... }`). Classification stayed correct either way (an OR is an OR),
      # but a LATER entry sharing the same class never got its own condition evaluated at all when
      # an earlier entry already matched -- so its `FailsOnVerdicts` cache stayed empty, and its own
      # message_gate read that as "no match" (the safe default for a genuine miss) even when the
      # later entry's condition was genuinely true. Fixed by evaluating every matching-class entry
      # (never short-circuiting), so each one's condition still runs exactly once and its message
      # can still apply regardless of which entry actually caused the reclassification.
      it "a later entry's own message still applies even though an earlier entry on the same class already matched" do
        action = build_axn do
          fails_on ArgumentError # no message, unconditional -- matches (and would short-circuit) first
          fails_on ArgumentError, "second entry message", if: -> { true }
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        expect(result.outcome).to be_failure
        expect(result.error).to eq("second entry message")
      end
    end

    # Regression coverage for the executor reorder: the verdict is recorded BEFORE presentation
    # resolution and the :error callback dispatch, so both windows read the finished answer rather
    # than re-deriving (or worse, running) the condition themselves.
    describe "the declaring action's own settlement windows read the recorded verdict" do
      it "reads outcome as failure inside its own on_error" do
        observed = nil
        action = build_axn do
          fails_on ArgumentError, if: -> { true }
          on_error { observed = result.outcome.to_s }
          def call = raise ArgumentError, "boom"
        end

        action.call
        expect(observed).to eq("failure")
      end

      it "reads outcome as failure inside message resolution (presentation stamping), for any declared handler" do
        observed = nil
        action = build_axn do
          fails_on ArgumentError, if: -> { true }
          error do |e|
            observed = result.outcome.to_s
            "handled: #{e.message}"
          end
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        expect(observed).to eq("failure")
        expect(result.error).to eq("handled: boom")
      end
    end

    # Codex review finding (PR #261): a condition that reads `result.outcome` reentrant -- DURING its
    # own evaluation, not from a later callback -- used to see `finalized?` already true (set by
    # `__record_exception` before classification ran) and memoize whatever `outcome` resolved to at
    # that moment, permanently, even after classification then decided the opposite. Fixed by
    # deferring `Context#__finalize!` until classification is fully decided and recorded.
    describe "a condition that reads result.outcome reentrant, during its own evaluation" do
      it "does not permanently freeze in the pre-classification answer" do
        action = build_axn do
          fails_on ArgumentError, if: lambda {
            result.outcome # reentrant read, mid-classification
            true
          }
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        expect(result.outcome).to be_failure
        expect(result.outcome.to_s).to eq("failure")
      end
    end

    # Codex review finding (PR #261): a condition that reads `result.error`/`.message`/`.inspect`
    # reentrant -- during its own evaluation -- resolves LIVE (finalized? is still false at that
    # point), which walks every declared `error` handler including this entry's own wired message,
    # mid-classification: a cache miss on `FailsOnVerdicts` used to fall back to invoking the
    # condition AGAIN, unbounded (measured: 254 nested calls before this fix). Fixed in two parts:
    # (1) a cache miss now reads as a plain "not a match yet" rather than re-invoking the condition,
    # and (2) `Result#_error_resolver` (which memoizes `MessageResolver#matched_reason` -- "a
    # resolver is single-use") now defers that memoization until finalized, so the reentrant read's
    # premature "no match" can't get permanently baked in and outlive the real, later verdict.
    describe "a condition that reads result.error / .message / .inspect reentrant, during its own evaluation" do
      {
        "result.error" => :error.to_proc,
        "result.message" => :message.to_proc,
        "result.inspect" => :inspect.to_proc,
      }.each do |label, reentrant_read|
        it "runs the condition exactly once and resolves the real message, for a reentrant #{label} read" do
          calls = 0
          read = reentrant_read
          action = build_axn do
            fails_on ArgumentError, "gated message", if: lambda {
              calls += 1
              read.call(result)
              true
            }
            def call = raise ArgumentError, "boom"
          end

          result = action.call
          expect(calls).to eq(1)
          expect(result.outcome).to be_failure
          expect(result.error).to eq("gated message")
        end
      end
    end

    # Codex review finding (PR #261): before FailsOnVerdicts, `fails_on X, "msg", if: cond` evaluated
    # `cond` independently for classification (in `_fails_on?`) and for the wired message (via the
    # generic error/success Matcher pipeline) -- so a `cond` that wasn't perfectly pure could
    # classify one way and present the other. Fixed by caching the first evaluation's verdict and
    # reusing it for the message gate, so the condition runs at most once per exception.
    describe "classification and the message it gates can never disagree" do
      it "a condition returning a different answer on a hypothetical second call still gets ONE consistent verdict" do
        calls = 0
        action = build_axn do
          fails_on ArgumentError, "Unable to submit", if: lambda {
            calls += 1
            calls == 1
          }
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        expect(calls).to eq(1)
        expect(result.outcome).to be_failure
        expect(result.error).to eq("Unable to submit")
      end
    end

    describe "evaluation count" do
      it "evaluates the condition exactly once per call with no message, and adds nothing on later reads" do
        counter = []
        action = build_axn do
          fails_on ArgumentError, if: lambda {
            counter << 1
            true
          }
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        expect(counter.size).to eq(1)

        3.times { result.error }
        3.times { result.outcome }
        result.inspect
        expect(counter.size).to eq(1)
      end

      # The message gate reuses the SAME verdict classification already computed (FailsOnVerdicts),
      # rather than re-invoking the condition -- so a message changes nothing about the count. This
      # also means classification and the message it gates can never disagree, even for a condition
      # that isn't perfectly pure (a counter, a clock): there is only ever one answer to disagree with.
      it "evaluates the condition exactly once per call EVEN WITH a message declared -- classification and the message share one verdict" do
        counter = []
        action = build_axn do
          fails_on ArgumentError, "Unable to submit", if: lambda {
            counter << 1
            true
          }
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        expect(counter.size).to eq(1)
        expect(result.error).to eq("Unable to submit")

        3.times { result.error }
        3.times { result.outcome }
        result.inspect
        expect(counter.size).to eq(1)
      end

      it "reading outcome repeatedly after a CLOSED gate adds zero further evaluations" do
        counter = []
        action = build_axn do
          fails_on ArgumentError, if: lambda {
            counter << 1
            false
          }
          def call = raise ArgumentError, "boom"
        end

        result = action.call
        after_call = counter.size

        10.times { result.outcome }
        result.inspect

        expect(counter.size).to eq(after_call)
      end
    end

    describe "stickiness" do
      it "an inner action whose gate is closed does not classify, and the report still fires" do
        stub_const("InnerClosedGate", build_axn do
          fails_on(ArgumentError, if: -> { false })
          def call = raise(ArgumentError, "boom")
        end)
        stub_const("OuterOfClosedGate", build_axn { def call = InnerClosedGate.call! })

        result = OuterOfClosedGate.call
        expect(result.outcome).to be_exception
        expect(Axn.config).to have_received(:on_exception)
      end

      it "an inner action's open-gate classification is sticky to an ancestor with no fails_on of its own" do
        stub_const("InnerOpenGate", build_axn do
          fails_on(ArgumentError, if: -> { true })
          def call = raise(ArgumentError, "boom")
        end)
        stub_const("OuterOfOpenGate", build_axn { def call = InnerOpenGate.call! })

        result = OuterOfOpenGate.call
        expect(result.outcome).to be_failure
      end

      it "an ancestor's own condition is never consulted for an exception already classified by an inner action" do
        ancestor_evaluations = []
        stub_const("InnerAlreadyClassified", build_axn do
          fails_on(ArgumentError, if: -> { true })
          def call = raise(ArgumentError, "boom")
        end)
        stub_const("OuterWithOwnGate", build_axn do
          recorder = ancestor_evaluations
          fails_on(ArgumentError, if: lambda {
            recorder << 1
            true
          })
          define_method(:call) { InnerAlreadyClassified.call! }
        end)

        result = OuterWithOwnGate.call
        expect(result.outcome).to be_failure
        expect(ancestor_evaluations).to be_empty
      end

      # Codex review finding (PR #261), round 6: `_fails_on_entries` is a `class_attribute`, so a
      # subclass INHERITS the same `Entry` object its base declared. When the inner (subclassed)
      # action's OWN evaluation of that shared entry is false (no sticky classification recorded),
      # the exception bubbles to an outer action that ALSO shares the entry -- and its condition
      # must be evaluated again, against the OUTER's own `self`, not silently reuse the inner
      # action's (different instance, different verdict) answer. `FailsOnVerdicts` is keyed by
      # `(exception, action, entry)`, not just `(exception, entry)`, precisely so the two levels get
      # independent cache slots and neither the classification nor the message one level resolves
      # can be corrupted by what a DIFFERENT action instance answered for the same entry.
      it "an inherited entry's condition is evaluated independently at each settlement level, against each level's own self" do
        calls = []
        base = build_axn do
          fails_on ArgumentError, "gated", if: lambda {
            calls << self
            instance_of?(OuterLevel)
          }
        end
        stub_const("InnerLevel", Class.new(base) { def call = raise(ArgumentError, "boom") })
        stub_const("OuterLevel", Class.new(base) { define_method(:call) { InnerLevel.call! } })

        result = OuterLevel.call
        expect(calls.map(&:class)).to eq([InnerLevel, OuterLevel])
        expect(result.outcome).to be_failure
        expect(result.error).to eq("gated")
        expect(Axn.config).to have_received(:on_exception) # the inner level already reported it as a bug
      end
    end

    describe "declaration guards" do
      describe "rejected forms" do
        it "rejects if: false (would mean always reclassify)" do
          expect { build_axn { fails_on ArgumentError, if: false } }
            .to raise_error(ArgumentError, /not a boolean/)
        end

        it "rejects if: true (would mean never reclassify)" do
          expect { build_axn { fails_on ArgumentError, if: true } }
            .to raise_error(ArgumentError, /not a boolean/)
        end

        it "rejects unless: false" do
          expect { build_axn { fails_on ArgumentError, unless: false } }
            .to raise_error(ArgumentError, /not a boolean/)
        end

        it "rejects unless: true" do
          expect { build_axn { fails_on ArgumentError, unless: true } }
            .to raise_error(ArgumentError, /not a boolean/)
        end

        it "treats if: nil as not given (no error, unconditional)" do
          expect { build_axn { fails_on ArgumentError, if: nil } }.not_to raise_error
        end

        it "rejects if: [] (empty condition)" do
          expect { build_axn { fails_on ArgumentError, if: [] } }
            .to raise_error(ArgumentError, /cannot be an empty condition/)
        end

        it "rejects an unusable rule shape (a plain Integer)" do
          expect { build_axn { fails_on ArgumentError, if: 42 } }
            .to raise_error(ArgumentError, /cannot apply 42/)
        end

        it "rejects an unusable rule shape (a Regexp)" do
          expect { build_axn { fails_on ArgumentError, if: /re/ } }
            .to raise_error(ArgumentError, /cannot apply/)
        end

        it "rejects a #call-only object (not invokable by Invoker)" do
          call_only = Object.new
          def call_only.call = true

          expect { build_axn { fails_on ArgumentError, if: call_only } }
            .to raise_error(ArgumentError, /cannot apply/)
        end

        # Codex review finding (PR #261), round 8: the mirror case -- an object with `to_proc`/
        # `arity` but no `#call` used to pass `applicable?` (it satisfies `Invoker.callable?`) yet
        # was never actually routed to `apply_callable` at runtime (`#matches?`'s own dispatch checks
        # `respond_to?(:call)` first), so the declaration was silently accepted and the gate silently
        # never matched -- the opposite of "fail at declaration." See matcher_spec.rb for the
        # shared-layer fix and both directions of this asymmetry.
        it "rejects a to_proc+arity-only object that has no #call (would never be routed to apply_callable)" do
          to_proc_and_arity_only = Object.new
          def to_proc_and_arity_only.to_proc = -> { true }
          def to_proc_and_arity_only.arity = 0

          expect { build_axn { fails_on ArgumentError, if: to_proc_and_arity_only } }
            .to raise_error(ArgumentError, /cannot apply/)
        end

        it "rejects a boolean nested inside an array" do
          expect { build_axn { fails_on ArgumentError, if: [:some_method, false] } }
            .to raise_error(ArgumentError, /not a boolean/)
        end
      end

      describe "accepted forms" do
        it "accepts a Proc" do
          expect { build_axn { fails_on ArgumentError, if: -> { true } } }.not_to raise_error
        end

        it "accepts a Symbol" do
          expect { build_axn { fails_on ArgumentError, if: :some_method } }.not_to raise_error
        end

        it "accepts a String naming a constant" do
          expect { build_axn { fails_on ArgumentError, if: "ArgumentError" } }.not_to raise_error
        end

        it "accepts an Exception class" do
          expect { build_axn { fails_on ArgumentError, if: TypeError } }.not_to raise_error
        end

        it "accepts an array of valid rules" do
          expect { build_axn { fails_on ArgumentError, if: [:some_method, -> { true }] } }.not_to raise_error
        end
      end
    end

    describe "if:/unless: with no message (deliberately not rejected -- the opposite of standalone:)" do
      it "is fully meaningful alone" do
        action = build_axn do
          fails_on ArgumentError, if: -> { true }
          def call = raise ArgumentError, "boom"
        end

        expect(action.call.outcome).to be_failure
      end
    end
  end
end
