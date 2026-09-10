# frozen_string_literal: true

# A `model:` finder has two ways of saying "no such record" — returning nil, or raising its own not-found
# error — and until PRO-3369 they meant different things. The raising spelling went through
# `Extensions.best_effort`, so an ordinary bad id was warned about and handed to
# `on_ignored_exception` (which defaults to `on_exception`, i.e. the app's pager), while the nil-returning
# spelling was silent. Both then degraded to the same misleading "X is not a Y and X can't be blank".
#
# The rule pinned here: the two spellings are one outcome. A miss is a statement about the caller's id, and
# a bad argument is not an app bug — the policy `Axn::Tools::Invoker` already applies to every other inbound
# violation. Anything ELSE the finder raises is still a fault and still reports.
RSpec.describe "a model: finder that finds no record" do
  let(:reported) { [] }

  around do |example|
    Axn.config.on_exception = ->(exception, action:, context:) { reported << [exception, context] } # rubocop:disable Lint/UnusedBlockArgument
    example.run
  ensure
    Axn.config.on_exception = nil
  end

  # A PORO registry, so this lane exercises the whole feature with no ActiveRecord in the process — the
  # default not-found set resolves to empty here, which is exactly what a non-Rails host gets.
  let(:missing_error) { Class.new(StandardError) }

  let(:registry) do
    miss = missing_error
    Class.new do
      define_singleton_method(:find_by_id) { |_id| nil }
      define_singleton_method(:fetch!) { |id| raise miss, "no widget #{id}" }
      define_singleton_method(:explode) { |_id| raise ArgumentError, "the registry is down" }
    end
  end

  def tool_call(klass, **inputs)
    Axn::Tools::Invoker.new(adapter: :mcp, user_facing_input_errors: true).call(klass, inputs)
  end

  describe "a finder that returns nil" do
    subject(:action) { klass = registry and build_axn { expects :widget, model: { klass:, finder: :find_by_id } } }

    it "fails the contract as a not-found rather than a blank field" do
      result = action.call(widget_id: 7)

      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to eq("Widget not found")
    end

    it "still reads as blank when the caller named no record at all" do
      expect(action.call.exception.message).to eq("Widget can't be blank")
    end

    it "reports once for a direct call — a dangling reference is still a bug worth seeing" do
      action.call(widget_id: 7)

      expect(reported.map { |(e, _ctx)| e.class }).to eq([Axn::InboundValidationError])
    end

    it "reports nothing for a tool call, where a bad argument is the caller's mistake" do
      result = tool_call(action, widget_id: 7)

      expect(reported).to be_empty
      expect(result.error).to eq("Widget not found")
      expect(Axn::Tools::Invoker.input_invalid?(result)).to be true
    end
  end

  describe "a finder that raises its declared not_found_on: class" do
    subject(:action) do
      klass = registry
      miss = missing_error
      build_axn { expects :widget, model: { klass:, finder: :fetch!, not_found_on: miss } }
    end

    it "is indistinguishable from the nil-returning spelling" do
      result = tool_call(action, widget_id: 7)

      expect(result.error).to eq("Widget not found")
      expect(reported).to be_empty
    end

    it "accepts a list of classes" do
      klass = registry
      miss = missing_error
      action = build_axn { expects :widget, model: { klass:, finder: :fetch!, not_found_on: [KeyError, miss] } }

      expect(tool_call(action, widget_id: 7).error).to eq("Widget not found")
      expect(reported).to be_empty
    end

    # Membership is decided by the raised class's ANCESTRY, so a subclass of a declared miss is one too —
    # the same undispatched reading `Extensions.swallowable?` uses to decide what axn may absorb.
    it "covers a subclass of a declared class" do
      klass = registry
      subclass = Class.new(missing_error)
      klass.define_singleton_method(:fetch!) { |_id| raise subclass, "gone" }
      miss = missing_error
      action = build_axn { expects :widget, model: { klass:, finder: :fetch!, not_found_on: miss } }

      expect(tool_call(action, widget_id: 7).error).to eq("Widget not found")
      expect(reported).to be_empty
    end

    it "opts out entirely for `not_found_on: []`, leaving every finder exception a reported fault" do
      klass = registry
      miss = missing_error
      action = build_axn { expects :widget, model: { klass:, finder: :fetch!, not_found_on: [] } }
      allow(Axn.config.logger).to receive(:warn)

      tool_call(action, widget_id: 7)

      expect(reported.map { |(e, _ctx)| e.class }).to eq([miss])
    end
  end

  describe "a finder that is simply broken" do
    subject(:action) { klass = registry and build_axn { expects :widget, model: { klass:, finder: :explode } } }

    before { allow(Axn.config.logger).to receive(:warn) }

    it "still reports through on_ignored_exception, even on a tool call" do
      tool_call(action, widget_id: 7)

      expect(reported.map { |(e, _ctx)| e.class }).to eq([ArgumentError])
      expect(reported.first.last[:axn_ignored][:while]).to eq("finding widget with explode")
    end

    # The one non-StandardError escape the guard deliberately allows is untouched: nothing is committed
    # during validation, so a runaway finder settles as the real exception naming the real stack.
    it "does not absorb a non-StandardError" do
      klass = registry
      klass.define_singleton_method(:explode) { |_id| raise SystemStackError }
      action = build_axn { expects :widget, model: { klass:, finder: :explode } }

      expect(action.call(widget_id: 7).exception).to be_a(SystemStackError)
    end
  end

  # Requiredness is `optional?`, which `presence: false` does not touch — the field is still required and
  # the emitted schema still says so, so the runtime has to keep rejecting an omitted record. With no
  # presence check to carry the message, the model validator reports it itself rather than going quiet.
  describe "a required field whose presence check was declared away" do
    subject(:action) { klass = registry and build_axn { expects :widget, model: { klass:, finder: :find_by_id }, presence: false } }

    it "still rejects an omitted record, with the same wording" do
      expect(action.call.exception.message).to eq("Widget can't be blank")
    end

    it "still rejects a miss as a miss" do
      expect(action.call(widget_id: 7).exception.message).to eq("Widget not found")
    end

    it "reports exactly one error either way" do
      expect(action.call.exception.errors.count).to eq(1)
      expect(action.call(widget_id: 7).exception.errors.count).to eq(1)
    end
  end

  # The message rides on whatever presence check the field carries, so the same contract cannot say two
  # different things about the same miss depending on whether the author spelled the check out.
  describe "the wording is the same however the presence check was written" do
    # Every spelling, including the four where ActiveModel SKIPS the presence check — it reports nothing
    # then, so deferring to its mere existence let a required model field resolve to nil and the action
    # succeed. Whichever check ends up reporting, the field is rejected and the wording is the same.
    {
      "inferred" => {},
      "declared true" => { presence: true },
      "declared with an open gate" => { presence: { if: -> { true } } },
      "declared false" => { presence: false },
      "gated off with if:" => { presence: { if: -> { false } } },
      "gated off with unless:" => { presence: { unless: -> { true } } },
      "nil-tolerant" => { presence: { allow_nil: true } },
      "blank-tolerant" => { presence: { allow_blank: true } },
    }.each do |label, opts|
      it "reads the same for a #{label} presence check" do
        klass = registry
        action = build_axn { expects :widget, model: { klass:, finder: :find_by_id }, **opts }

        expect(action.call(widget_id: 7).exception.message).to eq("Widget not found")
        expect(action.call.exception.message).to eq("Widget can't be blank")
      end

      it "reports exactly one error for a #{label} presence check" do
        klass = registry
        action = build_axn { expects :widget, model: { klass:, finder: :find_by_id }, **opts }

        expect(action.call(widget_id: 7).exception.errors.count).to eq(1)
      end
    end

    it "leaves an author's own message: alone" do
      klass = registry
      action = build_axn { expects :widget, model: { klass:, finder: :find_by_id }, presence: { message: "pick a widget" } }

      expect(action.call(widget_id: 7).exception.message).to eq("Widget pick a widget")
    end

    it "says nothing at all when the field declared that no record is acceptable" do
      klass = registry
      action = build_axn { expects :widget, model: { klass:, finder: :find_by_id }, allow_nil: true }

      expect(action.call(widget_id: 7)).to be_ok
    end
  end

  # "The finder was asked" has to be decided by the SAME blankness the resolver gates the finder on
  # (`id_value.blank?`), or the message describes a lookup that never happened. Every value here is blank
  # to Ruby while rendering non-empty, which is what a `to_s`-based predicate got wrong.
  describe "a token the resolver treats as blank" do
    subject(:action) { klass = registry and build_axn { expects :widget, model: { klass:, finder: :find_by_id } } }

    [false, [], {}, "", "  "].each do |token|
      it "reads as blank, not as a failed lookup, for #{token.inspect}" do
        expect(action.call(widget_id: token).exception.message).to eq("Widget can't be blank")
      end
    end

    # The complement: not blank, so the finder really did run.
    [0, "0"].each do |token|
      it "reads as a failed lookup for #{token.inspect}, which is not blank" do
        expect(action.call(widget_id: token).exception.message).to eq("Widget not found")
      end
    end
  end

  # A finder only ever runs for an INBOUND field (`_model_fields` is built from `internal_field_configs`),
  # so an outbound `model:` field resolving to nil means "you did not expose it". One field name can be
  # declared on both sides, so without the direction an outbound failure borrowed the inbound token and
  # reported a lookup that had actually SUCCEEDED.
  describe "an outbound model: field" do
    # A finder that always HITS, so the inbound lookup succeeds and only the outbound half can fail.
    let(:hitting_registry) do
      Class.new do
        attr_reader :id

        define_method(:initialize) { |id| @id = id }
        define_singleton_method(:hit) { |id| new(id) }
      end
    end

    let(:both_ways) do
      lambda do |**exposes_opts|
        klass = hitting_registry
        build_axn do
          expects :widget, model: { klass:, finder: :hit }
          exposes :widget, model: { klass:, finder: :hit }, **exposes_opts
          define_method(:call) { expose(widget: nil) }
        end
      end
    end

    it "never describes the inbound lookup" do
      result = both_ways.call.call(widget_id: 7)

      expect(result.exception).to be_a(Axn::OutboundValidationError)
      expect(result.exception.message).to eq("Widget can't be blank")
    end

    # The same borrowing reaches a second door: with no presence check, the model validator reports the
    # absence itself. One gate covers both.
    it "never describes it through the no-presence-check path either" do
      result = both_ways.call(presence: false).call(widget_id: 7)

      expect(result.exception.message).to eq("Widget can't be blank")
    end
  end

  # THE invariant behind every wording rule above, stated once and checked by instrumenting the finder
  # rather than by asserting a message per case: the message says "not found" if and only if the finder was
  # actually called. Every round of review on this feature found the same shape of bug — the message
  # inferring what the resolver did from some parallel signal instead of the authoritative one — so this
  # derives the answer from the runtime at each position where the token can be read differently.
  describe "the message agrees with whether the finder actually ran" do
    let(:asked) { [] }

    let(:recording_registry) do
      log = asked
      Class.new { define_singleton_method(:find) { |id| log << id and nil } }
    end

    def assert_agreement(action, **inputs)
      asked.clear
      result = action.call(**inputs)
      message = result.ok? ? "" : result.exception.message

      expect(message.include?("not found")).to eq(asked.any?),
                                               "finder ran: #{asked.any?}, but message was #{message.inspect}"
    end

    it "agrees at the top level, with and without a token" do
      klass = recording_registry
      action = build_axn { expects :v, model: { klass: } }

      assert_agreement(action, v_id: 7)
      assert_agreement(action)
    end

    # The token a declared sibling `<field>_id` resolves to is not the raw wire value: a `default:` supplies
    # one the caller never sent, and a `preprocess:` can map a sent one to nil. Both move the "was it asked"
    # answer, so both are checked against the finder rather than against the input.
    it "agrees when a sibling <field>_id supplies the token by default:" do
      klass = recording_registry
      action = build_axn do
        expects :v, model: { klass: }
        expects :v_id, default: 7
      end

      assert_agreement(action)
    end

    it "agrees when a sibling <field>_id preprocesses the token away" do
      klass = recording_registry
      action = build_axn do
        expects :v, model: { klass: }
        expects :v_id, preprocess: ->(_x) {}, allow_nil: true
      end

      assert_agreement(action, v_id: 7)
    end

    it "agrees for an aliased reader" do
      klass = recording_registry
      action = build_axn { expects :v, model: { klass: }, as: :thing }

      assert_agreement(action, v_id: 7)
      assert_agreement(action)
    end

    it "agrees for a subfield" do
      klass = recording_registry
      action = build_axn do
        expects :data
        expects :v, model: { klass: }, on: :data
      end

      assert_agreement(action, data: { v_id: 7 })
      assert_agreement(action, data: { other: 1 })
    end

    it "agrees for a deep dotted subfield" do
      klass = recording_registry
      action = build_axn do
        expects :a
        expects :v, model: { klass: }, on: "a.b"
      end

      assert_agreement(action, a: { b: { v_id: 7 } })
      assert_agreement(action, a: { b: { other: 1 } })
    end

    # The hard case for "ask the authority, don't re-read": with `method_call:` and no declared `<field>_id`,
    # reading the token DISPATCHES a method on caller data. A one-shot getter answers a second reader
    # differently, so any consumer taking its own read can contradict what the finder actually did. One
    # memoized derivation now serves all of them — the finder, the absence wording, and the executor's
    # record/id consistency check, which had been taking a second raw read of its own.
    it "agrees for a method_call: subfield whose id getter answers only once" do
      klass = recording_registry
      parent = Object.new
      parent.define_singleton_method(:v_id) do
        @dispatches = (@dispatches || 0) + 1
        @dispatches == 1 ? 7 : nil
      end

      action = build_axn do
        expects :data
        expects :v, model: { klass: }, on: :data, method_call: true
      end

      assert_agreement(action, data: parent)
      expect(parent.instance_variable_get(:@dispatches)).to eq(1)
    end

    it "agrees for an ambient subfield" do
      klass = recording_registry
      action = build_axn { expects :v, model: { klass: }, on: :ambient_context }

      assert_agreement(action, ambient_context: { v_id: 7 })
      assert_agreement(action, ambient_context: { other: 1 })
    end
  end

  describe "declaration-time validation of not_found_on:" do
    it "refuses a value that is not an exception class" do
      klass = registry

      expect { build_axn { expects :widget, model: { klass:, not_found_on: :nope } } }
        .to raise_error(ArgumentError, /not_found_on: must name StandardError subclasses/)
    end

    it "refuses a non-exception class" do
      klass = registry

      expect { build_axn { expects :widget, model: { klass:, not_found_on: String } } }
        .to raise_error(ArgumentError, /not_found_on: must name StandardError subclasses/)
    end

    # The resolver rescues StandardError, and widening that is not an option — what axn may absorb beyond
    # it is a deliberate two-member allowlist. So a miss declared outside the boundary was accepted and
    # then never caught: it escaped the resolver, the guard, and `.call` itself.
    it "refuses a class outside the rescuable boundary, which would escape .call entirely" do
      klass = registry
      not_standard = Class.new(Exception) # rubocop:disable Lint/InheritException -- the point of the test

      expect { build_axn { expects :widget, model: { klass:, not_found_on: not_standard } } }
        .to raise_error(ArgumentError, /Only StandardError is rescuable there/)
    end

    it "refuses nil, which reads as `none` but would silently restore the default set" do
      klass = registry

      expect { build_axn { expects :widget, model: { klass:, not_found_on: nil } } }
        .to raise_error(ArgumentError, /Pass `not_found_on: \[\]` to opt out/)
    end

    # Undispatched ancestry: `entry <= StandardError` asks the class being judged about itself, and a class
    # answering in the true direction passed the guard and then escaped `.call`, since the resolver's rescue
    # reads the real ancestry.
    it "is not fooled by a class that lies about its own ancestry" do
      klass = registry
      liar = Class.new(Exception) # rubocop:disable Lint/InheritException -- the point of the test
      def liar.<=(_other) = true

      expect { build_axn { expects :widget, model: { klass:, not_found_on: liar } } }
        .to raise_error(ArgumentError, /must name StandardError subclasses/)
    end

    it "names every offending entry in one message" do
      klass = registry

      expect { build_axn { expects :widget, model: { klass:, not_found_on: [String, :nope] } } }
        .to raise_error(ArgumentError, /String.*:nope/m)
    end
  end
end
