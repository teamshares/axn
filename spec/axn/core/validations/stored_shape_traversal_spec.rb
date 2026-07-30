# frozen_string_literal: true

# A STORED shape graph can be untraversable even though no DECLARED one is. A member axn cannot rebuild —
# anything that is not a `Data` — is stored as the caller's own object (the documented residue), so the nested
# shape it carries is theirs to change after the class is declared.
#
# There are two ways to do that, and they need different answers. Pointing the nested shape back at itself makes
# an identity repeat, which `CycleGuard` sees. Making it mint a FRESH nested shape on every read repeats nothing
# at all, so no identity guard can see it — the graph is endless rather than cyclic, and only a depth bound stops
# it. The size budget is no defense either: depth costs one property per level, so the stack runs out thousands
# of levels before 25,000 does.
#
# Every walk of a stored graph needs both bounds, because `SystemStackError` is outside `StandardError` and
# escapes the rescue meant to settle a result — from a projection it reaches the caller, and from a log line it
# takes down the call it was only observing.
#
# Its own file rather than `property_name_collision_spec.rb`: this is about whether a graph axn holds can be
# WALKED, not about the property names it emits, and that file is already two thousand lines.
RSpec.describe "a stored shape graph that becomes untraversable" do
  # A duck-typed member (so axn stores this very object) whose nested shape follows `mode`:
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

  # Declared while the graph is honest, and projected once so the "before" state is real rather than assumed.
  def declared_with(member)
    build_axn do
      expects :payload, type: Hash, shape: { members: [member], container: Hash }
      exposes :out, type: Hash, shape: { members: [member], container: Hash }
      define_method(:call) { expose(out: {}) } # define_method, not `def`: this is inside a method body
    end
  end

  def declared_and_projected
    member = mutable_member
    klass = declared_with(member)
    expect(klass.input_schema.dig(:properties, :payload, :properties, :outer, :properties).keys).to eq([:inner])
    [member, klass]
  end

  describe "the projection walks" do
    %i[input_schema output_schema].each do |projection|
      it "reports a bounded error on #{projection} for a self-referential graph" do
        member, klass = declared_and_projected
        member.mode = :cycle

        expect { klass.public_send(projection) }
          .to raise_error(ArgumentError, /shape member of class.*contains itself.*after the class is declared/m)
      end

      it "reports a bounded error on #{projection} for a generative graph" do
        member, klass = declared_and_projected
        member.mode = :generative

        expect { klass.public_send(projection) }
          .to raise_error(ArgumentError, /nests more than 64 levels deep.*after the class is declared/m)
      end
    end

    # The two are distinguished rather than reported as one defect: a cycle is fixed by not nesting a shape
    # inside itself, an endless graph by returning the same nested shape each read.
    it "does not report a generative graph as a cycle" do
      member, klass = declared_and_projected
      member.mode = :generative

      expect { klass.input_schema }.to raise_error(ArgumentError, /fresh nested shape on every read is endless/)
    end

    # Naming the member by CLASS: reading its `field` here would run the caller's code while the failure is
    # being reported, which is what every one of these error paths refuses to do.
    it "names the member by class rather than reading its name" do
      member, klass = declared_and_projected
      stub_const("UntraversableMember", member.class)
      member.mode = :generative

      expect { klass.input_schema }.to raise_error(ArgumentError, /shape member of class UntraversableMember/)
    end
  end

  # These read the stored graph on every logged call, so a side channel must not be able to take down the call
  # it observes — and must not answer in a way that leaks.
  describe "the redaction walks" do
    it "keeps the sensitive-member predicate exact for a self-referential graph" do
      member, klass = declared_and_projected
      member.mode = :cycle

      # False is EXACT here, not defensive: a cyclic branch re-reaches the very members the enclosing frame is
      # already testing, so no `sensitive:` member can hide in one.
      expect(klass.send(:_shape_has_sensitive_member?, { members: [member], container: Hash }, nil)).to be(false)
    end

    it "answers true past the depth bound, so a generative graph is masked wholesale" do
      member, klass = declared_and_projected
      member.mode = :generative

      # Nothing can enumerate a graph that mints its members on demand, and the fail-safe answer for redaction
      # is "assume a secret" — which masks the value rather than logging it in the clear.
      expect(klass.send(:_shape_has_sensitive_member?, { members: [member], container: Hash }, nil)).to be(true)
    end

    %i[cycle generative].each do |mode|
      it "keeps the candidate walk bounded for a #{mode} graph" do
        member, klass = declared_and_projected
        member.mode = mode

        configs = klass.send(:_sensitive_candidate_configs)
        expect(configs.size).to be_between(1, 500)
        expect(configs.map { |c| Axn::Internal::ShapeGraph.read(c, :field) }).to include(:payload)
      end
    end

    # `inspect` is reachable directly, not only from a side channel, so an unbounded walk there raises at the
    # caller rather than degrading a log line.
    it "keeps inspect's own redaction walk bounded" do
      member, klass = declared_and_projected
      member.mode = :generative
      inspector = Axn::Core::ContextFacadeInspector.allocate

      # It RETURNS — no member here claims to be sensitive, so a bare inspector never needs its `action`, and
      # what this pins is that the walk terminates at all. Unbounded, it raised SystemStackError instead.
      expect(inspector.send(:collect_sensitive_member_names, klass.internal_field_configs.first)).to eq([])
    end

    it "still settles a logged call as an ordinary result" do
      member, klass = declared_and_projected
      member.mode = :generative

      result = klass.call(payload: { outer: { inner: 1 } })

      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::InboundValidationError)
    end
  end

  # Declaring a LATER ambient subfield rebuilds the tree over every ambient config, so a graph mutated since its
  # own declaration is re-walked there. That walk carried neither bound until it was enumerated for.
  describe "the ambient placement check" do
    def ambient_klass(member)
      build_axn do
        expects :request, on: :ambient_context, type: Hash, shape: { members: [member], container: Hash }
      end
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
  end
end
