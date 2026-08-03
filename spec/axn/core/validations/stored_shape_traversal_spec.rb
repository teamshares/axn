# frozen_string_literal: true

# A shape graph a class HOLDS can be untraversable even though no DECLARED one is. Declaring through
# `expects`/`exposes` cannot produce one — the declaration walk rejects an untraversable graph and snapshots what
# it accepts into axn's own Hashes and `ShapeConfig`s — but `internal_field_configs`/`subfield_configs` are
# writable, so a config array assigned onto a class directly carries whatever shape its author built, unwalked.
#
# There are two ways such a graph is untraversable, and they need different answers. Pointing a nested shape back
# at itself makes an identity repeat, which `CycleGuard` sees. Making it mint a FRESH nested shape on every read
# repeats nothing at all, so no identity guard can see it — the graph is endless rather than cyclic, and only a
# depth bound stops it. The size budget is no defense either: depth costs one property per level, so the stack
# runs out thousands of levels before 25,000 does.
#
# Every walk of a held graph needs both bounds, because `SystemStackError` is outside `StandardError` and
# escapes the rescue meant to settle a result — from a projection it reaches the caller, and from a log line it
# takes down the call it was only observing.
#
# Its own file rather than `property_name_collision_spec.rb`: this is about whether a graph axn holds can be
# WALKED, not about the property names it emits, and that file is already two thousand lines.
RSpec.describe "a shape graph a class holds that cannot be traversed" do
  # A member whose nested shape follows `mode`:
  #   :fixed      — an ordinary nested shape, walked once
  #   :cycle      — the same Hash every read, containing this member: an identity repeats
  #   :generative — a fresh Hash every read: nothing repeats, and the graph is endless
  def mutable_member
    Class.new do
      attr_accessor :mode

      def initialize
        @mode = :fixed
        @fixed = { members: [Axn::Core::Contract::ShapeConfig.new(field: :inner, validations: {})], container: Hash }
      end

      def field = :outer

      def validations
        shape = case @mode
                when :fixed then @fixed
                when :cycle then (@cyclic ||= { members: [self], container: Hash })
                else { members: [self], container: Hash }
                end
        { type: { klass: Hash }, shape: }
      end
    end.new
  end

  # A field config carrying the member's shape, ASSIGNED onto the class rather than declared — the one route by
  # which a graph the declaration walk never saw becomes the contract a class holds.
  def config_for(field, member)
    Axn::Core::Contract::FieldConfig.new(
      field:, reader_as: field, validations: { type: { klass: Hash }, shape: { members: [member], container: Hash } },
    )
  end

  def held_by(member)
    klass = build_axn { define_method(:call) { expose(out: {}) } } # define_method: this is inside a method body
    klass.internal_field_configs = [config_for(:payload, member)].freeze
    klass.external_field_configs = [config_for(:out, member)].freeze
    klass
  end

  # Assigned while the graph is honest, and projected once so the "before" state is real rather than assumed.
  def held_and_projected
    member = mutable_member
    klass = held_by(member)
    expect(klass.input_schema.dig(:properties, :payload, :properties, :outer, :properties).keys).to eq([:inner])
    [member, klass]
  end

  describe "the projection walks" do
    %i[input_schema output_schema].each do |projection|
      it "reports a bounded error on #{projection} for a self-referential graph" do
        member, klass = held_and_projected
        member.mode = :cycle

        expect { klass.public_send(projection) }
          .to raise_error(ArgumentError, %r{shape member of class.*contains itself.*without being declared through `expects`/`exposes`}m)
      end

      it "reports a bounded error on #{projection} for a generative graph" do
        member, klass = held_and_projected
        member.mode = :generative

        expect { klass.public_send(projection) }
          .to raise_error(ArgumentError, %r{nests more than 64 levels deep.*without being declared through `expects`/`exposes`}m)
      end
    end

    # The two are distinguished rather than reported as one defect: a cycle is fixed by not nesting a shape
    # inside itself, an endless graph by returning the same nested shape each read.
    it "does not report a generative graph as a cycle" do
      member, klass = held_and_projected
      member.mode = :generative

      expect { klass.input_schema }.to raise_error(ArgumentError, /fresh nested shape on every read is endless/)
    end

    # Naming the member by CLASS: reading its `field` here would run the caller's code while the failure is
    # being reported, which is what every one of these error paths refuses to do.
    it "names the member by class rather than reading its name" do
      member, klass = held_and_projected
      stub_const("UntraversableMember", member.class)
      member.mode = :generative

      expect { klass.input_schema }.to raise_error(ArgumentError, /shape member of class UntraversableMember/)
    end
  end

  # These read the stored graph on every logged call, so a side channel must not be able to take down the call
  # it observes — and must not answer in a way that leaks.
  describe "the redaction walks" do
    it "keeps the sensitive-member predicate exact for a self-referential graph" do
      member, klass = held_and_projected
      member.mode = :cycle

      # False is EXACT here, not defensive: a cyclic branch re-reaches the very members the enclosing frame is
      # already testing, so no `sensitive:` member can hide in one.
      expect(klass.send(:_shape_has_sensitive_member?, { members: [member], container: Hash }, nil)).to be(false)
    end

    it "answers true past the depth bound, so a generative graph is masked wholesale" do
      member, klass = held_and_projected
      member.mode = :generative

      # Nothing can enumerate a graph that mints its members on demand, and the fail-safe answer for redaction
      # is "assume a secret" — which masks the value rather than logging it in the clear.
      expect(klass.send(:_shape_has_sensitive_member?, { members: [member], container: Hash }, nil)).to be(true)
    end

    %i[cycle generative].each do |mode|
      it "keeps the candidate walk bounded for a #{mode} graph" do
        member, klass = held_and_projected
        member.mode = mode

        configs = klass.send(:_sensitive_candidate_configs)
        expect(configs.size).to be_between(1, 500)
        expect(configs.map { |c| Axn::Internal::ShapeGraph.read(c, :field) }).to include(:payload)
      end
    end

    # `inspect` is reachable directly, not only from a side channel, so an unbounded walk there raises at the
    # caller rather than degrading a log line.
    it "keeps inspect's own redaction walk bounded" do
      member, klass = held_and_projected
      member.mode = :generative

      # It RETURNS — no member here claims to be sensitive, so the walk never needs an instance, and what this
      # pins is that it terminates at all. Unbounded, it raised SystemStackError instead.
      expect(klass._sensitive_member_names(klass.internal_field_configs.first, nil)).to eq([])
    end

    it "still settles a logged call as an ordinary result" do
      member, klass = held_and_projected
      member.mode = :generative

      result = klass.call(payload: { outer: { inner: 1 } })

      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
    end
  end

  # The walks above answer questions ABOUT the graph, and a bound on the graph is enough for them. The mask
  # that redacts a value descends the graph and the VALUE in lockstep, so what recurses there is the value: a
  # held cyclic graph walks a self-referential value forever, while an acyclic value stops the walk at its own
  # leaves however the graph is built. Both halves are pinned here, because guarding the graph instead would
  # stop a legitimately repeated shape from descending a value that still has members to redact.
  describe "the mask that descends a shaped value" do
    # `nxt`'s nested shape IS the shape it lives in, beside a `sensitive:` sibling — which is what makes the
    # mask descend at all (see `_sensitive_nested_members`).
    def cyclic_sensitive_shape
      shape = { container: Hash, members: [] }
      shape[:members] << Axn::Core::Contract::ShapeConfig.new(field: :secret, validations: {}, sensitive: true)
      shape[:members] << Axn::Core::Contract::ShapeConfig.new(field: :nxt, validations: { type: { klass: Hash }, shape: })
      shape
    end

    # The same nested shape reached by two members — SHARED but acyclic. A guard that mistook sharing for a
    # cycle would mask `right` wholesale and lose the sibling beside the secret.
    def diamond_shape
      leaf = { container: Hash,
               members: [Axn::Core::Contract::ShapeConfig.new(field: :secret, validations: {}, sensitive: true),
                         Axn::Core::Contract::ShapeConfig.new(field: :keep, validations: {})] }
      { container: Hash,
        members: [Axn::Core::Contract::ShapeConfig.new(field: :left, validations: { type: { klass: Hash }, shape: leaf }),
                  Axn::Core::Contract::ShapeConfig.new(field: :right, validations: { type: { klass: Hash }, shape: leaf })] }
    end

    def shaped_config(field, shape)
      Axn::Core::Contract::FieldConfig.new(field:, reader_as: field, validations: { type: { klass: Hash }, shape: })
    end

    def held_masking(shape)
      klass = build_axn
      klass.internal_field_configs = [shaped_config(:payload, shape)].freeze
      klass
    end

    def cyclic_value
      value = { secret: "hunter2", other: "keepme" }
      value[:nxt] = value
      value
    end

    it "masks a self-referential value wholesale where it repeats, instead of recursing" do
      klass = held_masking(cyclic_sensitive_shape)

      masked = klass.send(:_context_slice, data: { payload: cyclic_value }, direction: :inbound)

      # Over-redacted rather than under-redacted: the repeat cannot be descended into, so it is replaced whole
      # — the sensitive member is still filtered, and the ordinary sibling beside it still survives.
      expect(masked).to eq({ payload: { secret: "[FILTERED]", other: "keepme", nxt: "[FILTERED]" } })
    end

    # The side channels that read the mask on a live call. `_context_slice` above is the seam; these are where
    # a SystemStackError would actually land — one takes down the call it observes, the other the caller.
    it "keeps inputs_for_logging bounded on a self-referential value" do
      klass = held_masking(cyclic_sensitive_shape)

      logged = klass.send(:new, payload: cyclic_value).send(:inputs_for_logging)

      expect(logged).to eq({ payload: { secret: "[FILTERED]", other: "keepme", nxt: "[FILTERED]" } })
    end

    it "keeps the facade's inspect bounded on a self-referential value" do
      # The exposure's contract is ordinary while the call runs and the held graph is assigned afterwards, so
      # what this exercises is the mask `inspect` reaches rather than any other walk over the same graph.
      value = cyclic_value
      klass = build_axn { exposes(:out) }
      klass.send(:define_method, :call) { expose(out: value) }
      result = klass.call
      klass.external_field_configs = [shaped_config(:out, cyclic_sensitive_shape)].freeze

      # Asserted by content, not by rendering: Ruby 3.4 changed how a Hash inspects.
      rendered = result.inspect
      expect(rendered).to include("[FILTERED]").and include("keepme")
      expect(rendered).not_to include("hunter2")
    end

    # The other half: the graph repeats but the value does not, so the walk must follow the value all the way
    # down rather than stopping at the shape it has seen before.
    it "descends a cyclic graph as far as an acyclic value goes" do
      klass = held_masking(cyclic_sensitive_shape)
      value = { secret: "s0", nxt: { secret: "s1", nxt: { secret: "s2", other: "kept" } } }

      masked = klass.send(:_context_slice, data: { payload: value }, direction: :inbound)

      expect(masked).to eq({ payload: { secret: "[FILTERED]",
                                        nxt: { secret: "[FILTERED]", nxt: { secret: "[FILTERED]", other: "kept" } } } })
    end

    it "masks every position of a shared but acyclic graph" do
      klass = held_masking(diamond_shape)

      masked = klass.send(:_context_slice, data: { payload: { left: { secret: "a", keep: "l" }, right: { secret: "b", keep: "r" } } },
                                           direction: :inbound)

      expect(masked).to eq({ payload: { left: { secret: "[FILTERED]", keep: "l" }, right: { secret: "[FILTERED]", keep: "r" } } })
    end

    # A container repeated among SIBLINGS is not ancestry, and must not read as a cycle — the second position
    # is masked in full, not replaced (CycleGuard pops on the way out).
    it "masks a value repeated among siblings in full at both positions" do
      klass = held_masking(diamond_shape)
      shared = { secret: "shared", keep: "kept" }

      masked = klass.send(:_context_slice, data: { payload: { left: shared, right: shared } }, direction: :inbound)

      expect(masked).to eq({ payload: { left: { secret: "[FILTERED]", keep: "kept" },
                                        right: { secret: "[FILTERED]", keep: "kept" } } })
    end

    # A cycle that closes through an Array as well as a Hash: an Array element only recurses by being a Hash,
    # so every cyclic path repeats a Hash — which is why the guard sits on the Hash rather than on both.
    it "masks a cycle that closes through an array" do
      shape = { container: Hash, members: [] }
      shape[:members] << Axn::Core::Contract::ShapeConfig.new(field: :secret, validations: {}, sensitive: true)
      shape[:members] << Axn::Core::Contract::ShapeConfig.new(
        field: :list, validations: { type: { klass: Array }, shape: { container: Array, members: shape[:members] } },
      )
      klass = held_masking(shape)
      value = { secret: "s", keep: "k" }
      value[:list] = [value]

      masked = klass.send(:_context_slice, data: { payload: value }, direction: :inbound)

      expect(masked).to eq({ payload: { secret: "[FILTERED]", keep: "k", list: ["[FILTERED]"] } })
    end
  end

  # Runtime shape VALIDATION descends the graph and the value in lockstep too, and was the last walk in the
  # library carrying neither bound (PRO-3026). It differs from the mask above in where an unbounded walk lands:
  # `SystemStackError` here is raised INSIDE the execution path, so the executor settles it onto a failed result
  # rather than letting it escape a side channel — a result whose "exception" is a stack overflow naming none of
  # the contract, which is why it still had to be closed.
  #
  # What a REVISIT means is the whole design, and it is the PAIR of value and shape node. Both single-key
  # alternatives were measured and both are wrong, in opposite directions: see the two regression examples below.
  describe "the validation walk that descends a shaped value" do
    def member(field, validations) = Axn::Core::Contract::ShapeConfig.new(field:, validations:)

    def validating(shape)
      klass = build_axn
      klass.internal_field_configs = [
        Axn::Core::Contract::FieldConfig.new(field: :p, reader_as: :p, validations: { type: { klass: Hash }, shape: }),
      ].freeze
      klass
    end

    def self_referential_value
      value = {}
      value[:nxt] = value
      value
    end

    # The reported repro. `nxt`'s nested shape IS the shape it lives in, so the graph is cyclic; the value
    # follows the same cycle, so the two recursed together.
    it "settles a cyclic graph over a self-referential value as an ordinary result" do
      shape = { container: Hash }
      shape[:members] = [member(:tok, { presence: true }), member(:nxt, { shape: })]

      result = validating(shape).call(p: self_referential_value)

      # The verdict the contract actually has, rather than a stack overflow: `tok` is missing from the value.
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to include("P tok can't be blank")
    end

    it "closes the same cycle when it runs through an Array container" do
      members = [member(:tok, { presence: true })]
      shape = { container: Hash, members: }
      members << member(:list, { type: { klass: Array }, shape: { container: Array, members: } })
      value = {}
      value[:list] = [value]

      result = validating(shape).call(p: value)

      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to include("P tok can't be blank")
    end

    # Why the value alone cannot be the key. This declaration is ORDINARY — two levels, acyclic, no assigned
    # config anywhere — and it terminates on its own however self-referential the value is, because the graph
    # runs out. Keying on the value would see the same Hash one level down and skip it, silently dropping a
    # verdict a legal contract has always produced. The guard has to stay invisible here.
    it "still validates every level a legal declared shape reaches into a self-referential value" do
      klass = build_axn do
        expects :p, type: Hash do
          field :nxt, type: Hash do
            field :leaf, presence: true
          end
        end
      end

      result = klass.call(p: self_referential_value)

      expect(result.exception.message).to include("P nxt leaf can't be blank")
    end

    # Why the SHAPE alone cannot be the key either — the same reason the mask above guards the value. The graph
    # is cyclic while the value is finite, so every level has real members left to check.
    it "descends a cyclic graph as far as an acyclic value goes" do
      shape = { container: Hash }
      shape[:members] = [member(:tok, { presence: true }), member(:nxt, { type: { klass: Hash }, shape: })]

      result = validating(shape).call(p: { tok: "t0", nxt: { tok: "t1", nxt: { nxt: {} } } })

      # The third level's `tok` is missing and reported; a shape-keyed guard stopped at the second.
      expect(result.exception.message).to include("P nxt nxt tok can't be blank")
    end

    # The case that decides value-vs-pair, and the one the reported repro does not reach. ONE value is reached
    # under TWO shape nodes, each with its own required member. Value-keyed ancestry skips the second node
    # entirely and `inner_req` is never checked — a violation masked rather than a walk bounded.
    it "reports the required member of every distinct shape node one value is reached under" do
      outer = { container: Hash }
      inner = { container: Hash }
      outer[:members] = [member(:outer_req, { presence: true }), member(:nxt, { shape: inner })]
      inner[:members] = [member(:inner_req, { presence: true }), member(:nxt, { shape: outer })]

      result = validating(outer).call(p: self_referential_value)

      expect(result.exception.message).to include("P outer_req can't be blank").and include("P nxt inner_req can't be blank")
    end

    # Ancestry, not sightings: the pair is popped on the way out, so one value at two SIBLING positions is
    # validated in full at both.
    it "validates a value repeated among siblings at both positions" do
      leaf = { container: Hash, members: [member(:need, { presence: true })] }
      shape = { container: Hash, members: [member(:left, { shape: leaf }), member(:right, { shape: leaf })] }
      shared = {}

      result = validating(shape).call(p: { left: shared, right: shared })

      expect(result.exception.message).to include("P left need can't be blank").and include("P right need can't be blank")
    end

    # The other half of untraversability, which no identity guard can see: a member minting a FRESH nested shape
    # on every read repeats no pair at all, so only the depth bound stops it. Reached with a self-referential
    # value, since an acyclic one ends the walk at its own leaves whatever the graph does.
    it "reports a bounded error for a generative graph over a self-referential value" do
      generative = Class.new do
        def field = :nxt
        def validations = { type: { klass: Hash }, shape: { members: [self], container: Hash } }
      end.new

      result = validating({ members: [generative], container: Hash }).call(p: self_referential_value)

      expect(result).not_to be_ok
      expect(result.exception).to be_a(ArgumentError)
      expect(result.exception.message).to match(/nests more than 64 levels deep/)
    end

    # An ordinary shaped call is unchanged — the bound is on the descent, not on the members.
    it "leaves an ordinary nested shape validating exactly as before" do
      klass = build_axn do
        expects :p, type: Hash do
          field :name, presence: true
          field :meta, type: Hash do
            field :id, presence: true
          end
        end
      end

      expect(klass.call(p: { name: "n", meta: { id: 1 } })).to be_ok
      expect(klass.call(p: { name: "n", meta: {} }).exception.message).to include("P meta id can't be blank")
    end
  end

  # Declaring a LATER ambient subfield rebuilds the tree over every ambient config, so a graph the class was
  # handed rather than declared is re-walked there. That walk carried neither bound until it was enumerated for.
  describe "the ambient placement check" do
    def ambient_klass(member)
      klass = build_axn { expects :request, on: :ambient_context, type: Hash }
      config = Axn::Core::Contract::FieldConfig.new(
        field: :request, reader_as: :request, on: :ambient_context,
        validations: { type: { klass: Hash }, shape: { members: [member], container: Hash } }
      )
      klass.subfield_configs = [config].freeze
      klass
    end

    # Each mode asserts ITS OWN message, not merely that something raised: with the two bounds collapsed into
    # one, a cyclic graph would be caught 64 levels later by the depth bound and reported as the wrong defect.
    {
      cycle: /shape member of class.*contains itself/m,
      generative: /shape member of class.*nests more than 64 levels deep/m,
    }.each do |mode, message|
      it "is bounded when a later ambient subfield is declared over a #{mode} graph" do
        member = mutable_member
        klass = ambient_klass(member)
        member.mode = mode

        expect { klass.class_eval { expects :other, on: :ambient_context, type: Hash } }
          .to raise_error(ArgumentError, message)
      end
    end
  end

  # One cap, read from one place (`ShapeGraph::MAX_NESTING`), so the declaration walk and every re-walk cannot
  # drift into disagreeing about what is traversable. Asserted through behavior rather than by reading the
  # constant: the same depth that declares must also project.
  describe "the bound itself" do
    def linear_shape(depth)
      shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: {})], container: Hash }
      depth.times do
        shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :n, validations: { type: { klass: Hash }, shape: })],
                  container: Hash }
      end
      shape
    end

    it "accepts an honest graph at the cap, for declaration AND projection" do
      shape = linear_shape(63)
      klass = build_axn { expects :p, type: Hash, shape: }

      expect { klass.input_schema }.not_to raise_error
      expect { klass.output_schema }.not_to raise_error
    end

    it "rejects one level past it at declaration" do
      shape = linear_shape(65)

      expect { build_axn { expects :p, type: Hash, shape: } }
        .to raise_error(ArgumentError, /nested more than 64 levels deep/)
    end

    # A DAG whose tails are SHARED, arranged so the declaration walk meets every one of them shallow before
    # anything reuses it deep: `shapes[i]` is a chain of `i + 1` nested shapes, and every `shapes[i]` is also a
    # direct member of the root, so each is first walked one level down and then reused one level under the next
    # chain. The deepest node of the graph the class STORES therefore sits `chains` levels below the root, while
    # no walk of it ever descends past two — which is exactly the distinction the depth bound has to survive,
    # since depth belongs to a shape's POSITION and the walk remembers shapes rather than positions.
    def shared_tail_shape(chains)
      shapes = [{ members: [Axn::Core::Contract::ShapeConfig.new(field: :leaf, validations: {})], container: Hash }]
      (chains - 1).times do |i|
        shapes << { members: [Axn::Core::Contract::ShapeConfig.new(field: :"n#{i}", validations: { type: { klass: Hash }, shape: shapes[i] })],
                    container: Hash }
      end
      members = shapes.each_with_index.map do |shape, i|
        Axn::Core::Contract::ShapeConfig.new(field: :"m#{i}", validations: { type: { klass: Hash }, shape: })
      end
      { members:, container: Hash }
    end

    it "accepts a shared-tail graph at the cap, for declaration AND projection" do
      shape = shared_tail_shape(64)
      klass = build_axn { expects :p, type: Hash, shape: }

      expect { klass.input_schema }.not_to raise_error
      expect { klass.output_schema }.not_to raise_error
    end

    # The user-visible half of the same cap. Redaction's answer past the bound is TRUE, deliberately: nothing can
    # enumerate a graph that mints its members on demand, so the value is masked wholesale rather than logged in
    # the clear. That fail-safe is only ever an answer about an UNDECLARABLE graph while a declared one cannot be
    # that deep — a stored graph past the bound would mask values in a contract with no `sensitive:` in it at all.
    it "logs a shared-tail graph at the cap in the clear, with no `sensitive:` declared" do
      shape = shared_tail_shape(64)
      klass = build_axn { expects :p, type: Hash, shape: }

      logged = klass.send(:new, p: { m63: { n62: "visible" } }).send(:inputs_for_logging)

      expect(logged).to eq({ p: { m63: { n62: "visible" } } })
    end

    # The counterexample a subtree memo admits unless the bound is re-judged at each reference: every level of
    # this chain is a subtree already verified shallower, so nothing on the way down sees a depth past two while
    # the graph the class would store is 71 levels deep. Such a contract has no honest projection (that walk
    # judges positions, and refuses it), and redaction's fail-safe past the bound masks values with no
    # `sensitive:` anywhere in it — so declaration is where it has to be answered, with the author standing there.
    it "rejects a graph whose depth is reached only through subtrees already verified shallower" do
      shape = shared_tail_shape(71)

      expect { build_axn { expects :p, type: Hash, shape: } }
        .to raise_error(ArgumentError, /nested more than 64 levels deep/)
    end
  end
end
