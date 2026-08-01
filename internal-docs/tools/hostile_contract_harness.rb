# frozen_string_literal: true

# A DEVELOPMENT TOOL, not part of the test suite: a regression harness for axn's contract guards under
# deliberately hostile caller-supplied objects.
#
#   ruby internal-docs/tools/hostile_contract_harness.rb
#
# One row per hostile shape, member, option container or name that has ever slipped past a guard, plus the
# false-positive set that must keep declaring cleanly, plus cost rows and a few rows that merely RECORD a
# documented residue. Every row asserts an OUTCOME — a verdict string, a schema, a validation result — never
# merely "something raised". Run the whole thing after every change to a guard: the failure mode it exists to
# catch is a fix that closes one row and flips another.
#
# WHY IT IS NOT A SPEC. Its value is the A/B: run the SAME file against an older commit and read which rows
# behaved differently. That is what caught three regressions this branch (an absent members list becoming
# silently inert, a raw member's option bags staying aliased, a projection walk inheriting only half of the
# untraversability bounds) — a spec suite can only tell you the current tree is self-consistent.
#
# WHAT THE SUITE ALREADY COVERS, established by mutation rather than by matching row labels against example
# names (which measures the matcher, not the coverage): for each guard these rows exercise, the guard was removed
# or inverted and the suite re-run. 22 of the 25 guards have a spec that fails when the guard goes; the three
# that did not — the projection walk's depth bound, the redaction walks' bounds, and the ambient placement
# check's bounds — became `spec/axn/core/validations/stored_shape_traversal_spec.rb`. Rows that remain
# harness-only on purpose: the COST rows (a timing assertion belongs nowhere near CI) and the rows that record a
# documented residue rather than a guarantee — today two, a non-Array membership container staying the caller's
# own object, and an ASSIGNED config's member `sensitive:` going unchecked (every read of it is a redaction walk
# inside a side channel, where raising loses the log line instead of telling the author). (Two others were residue
# rows until the member snapshot closed them: a duck-typed member's
# nested shape staying aliased, and a non-idempotent reader splitting a guard from its consumer. They kept their
# fixtures and now assert the closure, which is exactly the A/B this file exists for.) The residue rows do have
# specs where the behaviour is observable, which is how a later "fix" of half of one gets noticed.
#
# When you add a row here, ask the same question: mutate the guard it exercises, and if the suite stays green,
# the row is knowledge that dies with this file. Convert it. The rows added since — the three OWNERSHIP guards
# (`Internal::NativeMethods`: which containers axn will copy, which contract failures it will rename, and which
# declared names render through Ruby's own code) and the emission gate on the projection size cap — are each
# covered by a mutation-verified example in `property_name_collision_spec.rb` / `validate_tool_contracts_spec.rb`;
# they stay here for the A/B, which is where their counterexamples came from. The name-rendering rows are the
# clearest case for the A/B this file exists for: at the commit before, two of them printed
# `{"properties":{"dup":{},"dup":{}}}` and one printed a `required` entry for a property the same schema does not
# define — output no assertion about the current tree can show you.
#
#   # 1. put the older commit in a detached worktree, with this harness copied in
#   git worktree add -f --detach /tmp/axn-ab <OLDER_SHA>
#   cp internal-docs/tools/hostile_contract_harness.rb /tmp/axn-ab/harness.rb
#   # 2. run it there (its own bundle, so the older lib/ is what answers)
#   (cd /tmp/axn-ab && bundle exec ruby harness.rb)
#   # 3. every row that fails THERE and passes here is a behaviour this change moved. Read them one by one:
#   #    an unexpected one is a regression, and a row that fails in BOTH is a fixture bug, not a finding.
#   git worktree remove --force /tmp/axn-ab
#
# Deliberately not wired into CI. It costs about a second, but CI's job is the spec suite; this is for the
# person changing a guard, and its output is meant to be read rather than reduced to green/red.
#
# NOTE: every row passes the shape as `shape: raw`, never the `shape:` shorthand. Inside a `Class.new do
# … end` body the shorthand does not close over an enclosing local across a newline — Ruby parses the NEXT
# expression as the value (`shape:` followed by `def call; end` passes `:call`), and the guards then see no
# shape at all and every row silently passes. Naming the local something else makes that unrepresentable.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "axn"
require "json"
require "benchmark"

SC = Axn::Core::Contract::ShapeConfig

UTF8_NAME = :café
LATIN1_NAME = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym

$failures = []
$rows = 0

def check(label, expectation)
  $rows += 1
  actual = begin
    yield
  rescue Exception => e # rubocop:disable Lint/RescueException
    "#{e.class}: #{e.message.to_s[0, 200]}"
  end
  ok = expectation.is_a?(Regexp) ? actual.to_s.match?(expectation) : actual == expectation
  $failures << [label, expectation, actual] unless ok
  puts format("%-4s %-60s %s", ok ? "ok" : "FAIL", label, actual.to_s[0, 92])
end

# The two property-name rules are judged on the JSON projection a name would appear in, so a row that asserts
# one must DECLARE and then demand a projection. Both are demanded, so a row does not have to know which side
# its fixture lands on. Rules that are not projection-gated raise inside the declaration and surface anyway.
def project(&block)
  klass = Class.new do
    include Axn
    class_eval(&block)
    def call; end
  end
  klass.input_schema
  klass.output_schema
  "declared"
end

def expects_axn(raw, **kwargs)
  Class.new do
    include Axn
    expects :payload, shape: raw, **kwargs
    def call; end
  end
end

def exposes_axn(raw, **kwargs)
  Class.new do
    include Axn
    exposes :payload, shape: raw, **kwargs
    def call; end
  end
end

# Declare and report what reflection then emits, so "the guard skipped it but reflection emits it" is
# visible as data rather than inferred.
def declare_and_reflect(raw, **kwargs)
  props = expects_axn(raw, **kwargs).input_schema.dig(:properties, :payload, :properties) || {}
  "declared props=#{props.keys.inspect} json=#{JSON.generate(props)}"
end

def stored_shape(raw, **kwargs) = expects_axn(raw, **kwargs).internal_field_configs.first.validations[:shape]

# ---------------------------------------------------------------------------------------------------
# Hostile fixtures
# ---------------------------------------------------------------------------------------------------

# Denies being a Hash. A type test that dispatches `is_a?` skips the walk while reflection consumes it.
LYING_IS_A = Class.new(Hash) do
  def is_a?(klass) = klass == Hash ? false : super
end

# Claims it already carries a `:container`, so derivation is skipped and every call raises
# `TypeError: class or module required`.
LYING_KEY = Class.new(Hash) do
  def key?(name) = name == :container ? true : super
end

# `[]` hides the members its real entries carry. Every guard reads members through `[]`; anything that
# reads them another way (an `each`-copy) promotes members no guard ever saw.
LYING_INDEX = Class.new(Hash) do
  def [](key)
    return [] if key == :members
    return nil if key == :container

    super
  end
end

# `[](:container)` answers with an object whose `nil?` raises, hijacking the "already has one?" test.
RAISING_NIL = Class.new do
  def nil? = raise(NotImplementedError, "hijacked from nil?")
end
LYING_NIL = Class.new(Hash) do
  def [](key) = key == :container ? RAISING_NIL.new : super
end

# `[](:members)` answers with a list whose `nil?` claims absence, hiding the members from the walk.
NIL_CLAIMING_LIST = Class.new(Array) do
  def nil? = true
end

# `merge` returns something that is not a Hash at all.
HOSTILE_MERGE = Class.new(Hash) do
  def merge(*) = "not a hash at all"
end

# Denies the `field` reader it defines.
LYING_RESPOND_TO = Class.new(SC) do
  def respond_to?(name, include_all = false) = name == :field ? false : super # rubocop:disable Style/OptionalBooleanParameter
end

# Served entirely by `method_missing`, with NO `respond_to_missing?` — invisible to a method-table lookup,
# perfectly visible to the plain dispatch reflection makes.
GHOST = Class.new do
  def initialize(name = :status, user_facing: false)
    @name = name
    @user_facing = user_facing
  end

  def method_missing(reader, *_args) # rubocop:disable Style/MissingRespondToMissing
    case reader
    when :field then @name
    when :user_facing then @user_facing
    when :validations, :metadata then {}
    end
  end
end

# A NoMethodError whose `name` hijacks the comparison that decides whether it means "no such reader".
HOSTILE_NAME = Class.new do
  def ==(_other) = raise(NotImplementedError, "hijacked from ==")
end
EVIL_NME = Class.new(NoMethodError) do
  define_method(:name) { HOSTILE_NAME.new }
end
EVIL_GHOST = Class.new do
  def method_missing(_reader, *_args) = raise(EVIL_NME.new("boom")) # rubocop:disable Style/MissingRespondToMissing
end

# A member that is NOT a ShapeConfig: the deliberate duck-typing tolerance, and therefore the one route by
# which an unnormalized name still reaches the guards.
DUCK_MEMBER = Class.new do
  def initialize(name) = @name = name
  def field = @name
  def validations = {}
  def metadata = {}
  def description = nil
  def optional? = true
end

# A name whose `==` raises, so choosing between the two duplicate messages must not dispatch it.
HOSTILE_EQ_NAME = Class.new(String) do
  def ==(_other) = raise(NotImplementedError, "hijacked from ==")
end

# Yields its members to `each` but hides them from `select`/`map`.
HIDING_LIST = Class.new(Array) do
  def select(*) = []
  def map(*) = []
end

# A reader that answers once and then raises — the second read is the one an error path would make.
ONCE_ONLY = Class.new do
  def initialize(name)
    @name = name
    @reads = 0
  end

  def field
    @reads += 1
    raise(NotImplementedError, "hijacked from a second read of #field") if @reads > 1

    @name
  end

  def validations = @validations ||= {}
end

# A name that is neither String nor Symbol: its `to_s` renders a perfectly good property, so it reaches the
# collision and unrenderable-name checks, but its `inspect` raises. Nothing on an error path may dispatch it.
EXOTIC_NAME = Class.new do
  def initialize(rendering) = @rendering = rendering
  def to_s = @rendering
  def inspect = raise(NotImplementedError, "hijacked from #inspect")
end

# A NoMethodError subclass carrying the REAL missing name, whose `name` reader raises. Reading the stored
# name must bypass the override entirely — `NameError#name` is where it is defined.
RAISING_NAME_NME = Class.new(NoMethodError) do
  def name = raise(NotImplementedError, "hijacked from #name")
end
RAISING_NAME_GHOST = Class.new do
  # No respond_to_missing?, so the fallback dispatch is the path reached; the raised error stores :field as
  # the missing name, exactly as an implicit NoMethodError would.
  def method_missing(reader, *_args) = raise(RAISING_NAME_NME.new("boom", reader)) # rubocop:disable Style/MissingRespondToMissing
end

# Reports a DIFFERENT name on each read. The member snapshot is what makes the first read the contract, so this
# fixture now pins agreement by construction rather than recording its absence.
DRIFTING = Class.new do
  def initialize = @reads = 0

  def field
    @reads += 1
    @reads == 1 ? :"unique#{object_id}" : :collide
  end

  def validations = {}
  def metadata = {}
  def description = nil
  def optional? = true
end

# A name that is READ once and stably, but CONVERTS differently each time — the complement of DRIFTING, and the
# form the member snapshot did not close on its own: `to_sym` is a second dispatch on the same object.
DRIFTING_NAME = Class.new(String) do
  def initialize(*) = super("alpha")

  def to_sym
    @reads = (@reads || 0) + 1
    @reads == 1 ? :alpha : :collide
  end
end

# The same drift on an `on:` ROUTE: renders "q" first and "p" afterwards. Both conversions flip together, so the
# fixture does not depend on which one a layer reaches for.
DRIFTING_ROUTE = Class.new(String) do
  def initialize(*) = super("ignored")

  def to_s
    @reads = (@reads || 0) + 1
    @reads == 1 ? "q" : "p"
  end

  def to_sym = to_s.to_sym
end

# Builds a FRESH nested shape on every read: never repeats an object, so no identity guard can see it;
# endless rather than cyclic.
GENERATIVE = Class.new(Hash) do
  def [](key)
    return [SC.new(field: :a, validations: { shape: self.class.new })] if key == :members
    return Hash if key == :container

    super
  end
end

def cyclic_member
  member = SC.new(field: :a, validations: {})
  member.validations[:shape] = { members: [member], container: Hash }
  member
end

def colliding_members = [SC.new(field: UTF8_NAME, validations: {}), SC.new(field: LATIN1_NAME, validations: {})]

# `depth` nested levels, each level's two sibling members sharing ONE nested shape object. A legitimate,
# supported declaration (the diamond case) — and the shape that makes a naive walk exponential.
def shared_diamond_shape(depth)
  shape = { members: [SC.new(field: :leaf, validations: {})], container: Hash }
  depth.times do
    shape = { members: [SC.new(field: :a, validations: { shape: }), SC.new(field: :b, validations: { shape: })], container: Hash }
  end
  shape
end

def linear_nested_shape(depth)
  shape = { members: [SC.new(field: :leaf, validations: {})], container: Hash }
  depth.times { shape = { members: [SC.new(field: :a, validations: { shape: })], container: Hash } }
  shape
end

# ---------------------------------------------------------------------------------------------------
puts "\n== hostile: must be caught, and caught as the defect it is =============================="
# ---------------------------------------------------------------------------------------------------

check "lying is_a?: collision guard fires", /DuplicateFieldError.*JSON property "café"/ do
  raw = LYING_IS_A.new
  raw[:members] = colliding_members
  raw[:container] = Hash
  declare_and_reflect(raw, type: Hash)
end

check "lying is_a?: outbound user_facing guard fires", /ArgumentError.*`status` does not support user_facing/ do
  raw = LYING_IS_A.new
  raw[:members] = [SC.new(field: :status, validations: {}, user_facing: true)]
  raw[:container] = Hash
  exposes_axn(raw, type: Hash) && "declared"
end

check "lying is_a?: container still derived (no per-call TypeError)", Hash do
  raw = LYING_IS_A.new
  raw[:members] = [SC.new(field: :a, validations: {})]
  stored_shape(raw, type: Hash)[:container]
end

check "lying key?: container still derived", Hash do
  raw = LYING_KEY.new
  raw[:members] = [SC.new(field: :a, validations: {})]
  stored_shape(raw, type: Hash)[:container]
end

# `nil?` is a type test, so nothing the caller's value defines gets to decide whether derivation runs — and the
# container it supplied is now itself held to being a class, so this reports the declaration defect rather than
# either hijacking or carrying a junk container through to a per-call TypeError.
check "lying nil? on :container: reports the declaration defect, not a hijack", /ArgumentError.*`container:` must be a class \(got a name of class RAISING_NIL\)/ do
  raw = LYING_NIL.new
  raw.store(:members, [SC.new(field: :a, validations: {})])
  "declared container=#{Axn::Internal::ClassName.of(stored_shape(raw, type: Hash)[:container])}"
end

check "lying nil? on :members: members still walked", /DuplicateFieldError.*JSON property "café"/ do
  raw = {}
  raw[:members] = NIL_CLAIMING_LIST.new.push(*colliding_members)
  raw[:container] = Hash
  declare_and_reflect(raw, type: Hash)
end

# The three `[]`-hiding rows. `[]` is the read every guard AND reflection makes, so a lie there hides the
# members from BOTH — that is the "changes what both decide" invariant. What must never happen is members
# reaching reflection that no guard saw.
check "lying []: hidden members do not reach reflection", "declared props=[] json={}" do
  raw = LYING_INDEX.new
  raw.store(:members, colliding_members)
  declare_and_reflect(raw, type: Hash)
end

check "lying []: hidden user_facing member is not promoted live", [] do
  raw = LYING_INDEX.new
  raw.store(:members, [SC.new(field: :status, validations: {}, user_facing: true)])
  shape = exposes_axn(raw, type: Hash).external_field_configs.first.validations[:shape]
  shape[:members]
end

check "lying []: hidden cyclic member cannot reach reflection", "declared props=[] json={}" do
  raw = LYING_INDEX.new
  raw.store(:members, [cyclic_member])
  declare_and_reflect(raw, type: Hash)
end

check "hostile merge: derived shape is a plain Hash", [Hash, Hash, 1] do
  raw = HOSTILE_MERGE.new
  raw[:members] = [SC.new(field: :a, validations: {})]
  derived = stored_shape(raw, type: Hash)
  [derived.class, derived[:container], derived[:members].size]
end

check "lying respond_to?(:field): collision guard fires", /DuplicateFieldError.*JSON property "café"/ do
  members = [LYING_RESPOND_TO.new(field: UTF8_NAME, validations: {}), LYING_RESPOND_TO.new(field: LATIN1_NAME, validations: {})]
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

check "method_missing without respond_to_missing?: collision guard fires", /DuplicateFieldError.*JSON property "café"/ do
  declare_and_reflect({ members: [GHOST.new(UTF8_NAME), GHOST.new(LATIN1_NAME)], container: Hash }, type: Hash)
end

check "method_missing without respond_to_missing?: user_facing guard fires", /ArgumentError.*`status` does not support user_facing/ do
  exposes_axn({ members: [GHOST.new(:status, user_facing: true)], container: Hash }, type: Hash) && "declared"
end

# EVIL_NME is a NoMethodError subclass, so propagating it is the honest outcome: a bug inside the member.
# What must NOT happen is its `name`'s `==` running and replacing that with NotImplementedError, which is a
# ScriptError and escapes every rescue in the framework.
check "hostile NoMethodError#name: propagates inside StandardError", "NoMethodError, StandardError=true: boom" do
  declare_and_reflect({ members: [EVIL_GHOST.new], container: Hash }, type: Hash)
rescue ::NoMethodError => e
  "NoMethodError, StandardError=#{e.is_a?(StandardError)}: #{e.message}"
end

# A ShapeConfig normalizes its name to a Symbol at construction, so a hostile String subclass cannot even be
# STORED as one — the hazard is gone at its root and the pair reports as the plain duplicate it now is.
check "hostile == on a ShapeConfig name: normalized away, reported as a duplicate", /DuplicateFieldError: Duplicate shape member declared: :dup/ do
  members = [SC.new(field: HOSTILE_EQ_NAME.new("dup"), validations: {}), SC.new(field: HOSTILE_EQ_NAME.new("dup"), validations: {})]
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

# A DUCK-TYPED member's reader is not ours to normalize, so this is where a caller-supplied String name still
# reaches the spelling comparison — and where deciding "same spelling" must still not dispatch the name's own
# `==`. Keeps that guard covered now that the ShapeConfig route no longer exercises it.
check "hostile == on a duck-typed member's name: still reports the duplicate", /DuplicateFieldError: Duplicate shape member declared: "dup"/ do
  members = [DUCK_MEMBER.new(HOSTILE_EQ_NAME.new("dup")), DUCK_MEMBER.new(HOSTILE_EQ_NAME.new("dup"))]
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

check "Array-subclass members hiding select/map: collision guard fires", /DuplicateFieldError.*JSON property "café"/ do
  members = HIDING_LIST.new.push(*colliding_members)
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

check "self-referential graph: rejected at declaration", /ArgumentError.*cannot contain itself.*shape member `a`/ do
  declare_and_reflect({ members: [cyclic_member], container: Hash }, type: Hash)
end

check "self-referential graph on exposes: rejected at declaration", /ArgumentError.*cannot contain itself/ do
  exposes_axn({ members: [cyclic_member], container: Hash }, type: Hash) && "declared"
end

check "generative graph: rejected at the depth cap", /ArgumentError.*nested more than 64 levels deep/ do
  declare_and_reflect(GENERATIVE.new, type: Hash)
end

# The member appears exactly ONCE in the graph, so the walk reads its name once; the only remaining reader
# dispatch would be the error path building the cycle message. If that path re-reads, the caller's
# NotImplementedError replaces the ArgumentError being reported.
check "reader raising on a SECOND read: the declaration error survives", /ArgumentError.*cannot contain itself.*shape member `a`/ do
  member = ONCE_ONLY.new(:a)
  raw = { members: [member], container: Hash }
  member.validations[:shape] = raw
  declare_and_reflect(raw, type: Hash)
end

# A member reached from TWO shapes is read once per shape — inherent to walking the graph at all, not an
# error-path re-read. The raise is then the member's own bug surfacing during the walk, and it is honest.
check "reader raising on a second read, reached from two shapes: the read is the walk's", /NotImplementedError.*second read/ do
  member = ONCE_ONLY.new(:a)
  member.validations[:shape] = { members: [member], container: Hash }
  declare_and_reflect({ members: [member], container: Hash }, type: Hash)
end

# `to_s` and `to_sym` disagreeing: the guard canonicalizes one, the schema keys the other, so the two compare
# different things about the same object.
DIVERGENT_NAME = Class.new do
  def to_s = "safe"
  def to_sym = :duplicate
end

check "name whose to_s and to_sym diverge, alone", /ArgumentError.*must be a String or a Symbol \(got a name of class DIVERGENT_NAME\)/ do
  declare_and_reflect({ members: [SC.new(field: DIVERGENT_NAME.new, validations: {})], container: Hash }, type: Hash)
end

check "name whose to_s and to_sym diverge, beside a normal member", /ArgumentError.*must be a String or a Symbol \(got a name of class DIVERGENT_NAME\)/ do
  members = [SC.new(field: DIVERGENT_NAME.new, validations: {}), SC.new(field: :duplicate, validations: { type: Integer })]
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

# These two used to reach the collision and unrenderable-name checks, where the hazard was the error path
# dispatching `inspect`. The type rule now rejects such a name outright, ahead of both — a strictly earlier
# and simpler answer. `_inspect_field_name`'s class-naming branch stays live and covered via the block-form
# option message below, which runs before a ShapeConfig is constructed.
check "exotic name whose inspect raises: rejected on type, ahead of the collision check", /ArgumentError.*must be a String or a Symbol \(got a name of class EXOTIC_NAME\)/ do
  members = [SC.new(field: EXOTIC_NAME.new("dup"), validations: {}), SC.new(field: EXOTIC_NAME.new("dup"), validations: {})]
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

check "exotic unrenderable name whose inspect raises: rejected on type", /ArgumentError.*must be a String or a Symbol \(got a name of class EXOTIC_NAME\)/ do
  bad = EXOTIC_NAME.new("bad\xFF".dup.force_encoding("ASCII-8BIT"))
  declare_and_reflect({ members: [SC.new(field: bad, validations: {})], container: Hash }, type: Hash)
end

# The field path (`expects`/`exposes`) symbolizes every declared name before any guard runs, so an exotic
# name cannot reach these helpers there at all. Asserted so the claim stays true rather than assumed.
check "field path cannot carry an exotic name at all", "NoMethodError" do
  project do
  expects EXOTIC_NAME.new("dup")
  end
rescue ::NoMethodError
  "NoMethodError"
end

# The BLOCK form's own option-rejection messages name the member through the same helper, so they carry the
# same hazard — a third route to it, found by auditing the helper's callers rather than the flagged line.
check "block-form option error with an exotic name: named by class", /ArgumentError.*shape member `a name of class EXOTIC_NAME` does not support model:/ do
  bad = EXOTIC_NAME.new("bad\xFF".dup.force_encoding("ASCII-8BIT"))
  project do
  expects(:payload, type: Hash) { field bad, model: true }
  end
end

# The mechanism this pins is unchanged: the ghost's stored name is read through NameError's own `name`, so the
# member reads as ABSENT rather than the subclass's NotImplementedError escaping. Absence is now a rejection.
check "raising NoMethodError#name: the stored name is read, so the member is nameless", /ArgumentError: a shape member must answer to `field`/ do
  members = [RAISING_NAME_GHOST.new, *colliding_members]
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

check "lying is_a? with no structured type:: declaration error still reported", /ArgumentError.*a shape block requires a single structured type/ do
  raw = LYING_IS_A.new
  raw[:members] = [SC.new(field: :a, validations: {})]
  declare_and_reflect(raw)
end

# ---------------------------------------------------------------------------------------------------
puts "\n== ordinary declarations that converge on one property =================================="
# ---------------------------------------------------------------------------------------------------
#
# No hostile objects here. These are supported spellings that resolve to the same wire slot, so the
# syntactic `[on, field]` key compared two different strings while the tree attached both under one parent.

class HarnessWidget
  def self.find(_id) = new
end

CAFE_ID_ISO = "caf\xE9_id".dup.force_encoding("ISO-8859-1").to_sym

def input_props(&block)
  klass = Class.new do
    include Axn
    class_eval(&block)
    def call; end
  end
  klass.input_schema[:properties] || {}
end

def output_props(&block)
  klass = Class.new do
    include Axn
    class_eval(&block)
    def call; end
  end
  klass.output_schema[:properties] || {}
end

check "dotted on: vs subfield-reader on:, names differing in encoding", /DuplicateFieldError/ do
  utf8 = UTF8_NAME
  iso = LATIN1_NAME
  props = input_props do
    expects :foo, type: Hash
    expects :bar, on: :foo, type: Hash
    expects utf8, on: "foo.bar", optional: true
    expects iso, on: :bar, optional: true
  end
  "declared #{JSON.generate(props)}"
end

check "aliased parent reader as the second route", /DuplicateFieldError/ do
  utf8 = UTF8_NAME
  iso = LATIN1_NAME
  props = input_props do
    expects :foo, type: Hash
    expects :bar, on: :foo, type: Hash, as: :aliased
    expects utf8, on: "foo.bar", optional: true
    expects iso, on: :aliased, optional: true
  end
  "declared #{JSON.generate(props)}"
end

check "model:-generated _id vs an explicit _id in another encoding", /DuplicateFieldError/ do
  utf8 = UTF8_NAME
  iso_id = CAFE_ID_ISO
  props = input_props do
    expects utf8, model: HarnessWidget, optional: true
    expects iso_id, optional: true
  end
  "declared #{JSON.generate(props)}"
end

check "two model: fields whose generated _ids collide", /DuplicateFieldError/ do
  utf8 = UTF8_NAME
  iso = LATIN1_NAME
  props = input_props do
    expects utf8, model: HarnessWidget, optional: true
    expects iso, model: HarnessWidget, optional: true
  end
  "declared #{JSON.generate(props)}"
end

check "subfield model:-generated _id vs an explicit sibling in another encoding", /DuplicateFieldError/ do
  utf8 = UTF8_NAME
  iso_id = CAFE_ID_ISO
  props = input_props do
    expects :p, type: Hash
    expects utf8, on: :p, model: HarnessWidget, optional: true
    expects iso_id, on: :p, optional: true
  end
  "declared #{JSON.generate(props)}"
end

# Checked mirror that does NOT apply: an outbound `model:` field emits its own name as the property and no
# generated `<field>_id` at all, so there is no generated name for an explicit one to collide with. Asserted
# rather than assumed, so the asymmetry with the inbound path is on the record.
check "exposes model: emits no generated _id, so nothing collides", %i[café café_id] do
  utf8 = UTF8_NAME
  iso_id = CAFE_ID_ISO
  output_props do
    exposes utf8, model: HarnessWidget, optional: true
    exposes iso_id, optional: true
  end.keys.map { |k| k.to_s.encode("UTF-8", invalid: :replace).to_sym }
end

# ---------------------------------------------------------------------------------------------------
puts "\n== the property-claim matrix: every mechanism pair, both encodings ======================"
# ---------------------------------------------------------------------------------------------------
#
# Five rounds each surfaced a different PAIR of mechanisms that can contribute a property name at one node
# without sharing a claim space. This section is the cross-product instead: one row per pair in the
# encoding-DISTINCT form (must be rejected) and one in the SAME-SPELLING form (a legal merge, must declare and
# emit exactly one property). Anything that can name a property at a node belongs here.

WIDGET = Class.new do
  def self.name = "Widget"
  def self.find(_id) = new
end
CAFE_DATA = Data.define(:café)
UTF8_ID = :café_id

# Every node in a reflected schema whose property names collapse onto one JSON property, at any depth.
def collapsed_nodes(props, path = [], out = [])
  return out unless props.is_a?(::Hash)

  dupes = props.keys.map { |k| Axn::Reflection::Values.canonical_wire_key(k) }.tally.select { |_c, n| n > 1 }.keys
  out << [path.join("."), dupes] unless dupes.empty?
  props.each do |k, v|
    next unless v.is_a?(::Hash)

    child = path + [Axn::Reflection::Values.canonical_wire_key(k)]
    collapsed_nodes(v[:properties], child, out)
    # An array's ELEMENT properties are their own node, seeded by `of:` and merged with the shape's members.
    collapsed_nodes(v.dig(:items, :properties), child + ["[]"], out)
    # A multi-class `type:`/`of:` reflects as alternative branches, each with its own properties.
    %i[anyOf allOf].each do |key|
      [v[key], v.dig(:items, key)].each do |branches|
        next unless branches.is_a?(::Array)

        branches.each_with_index { |b, i| collapsed_nodes(b[:properties], child + ["#{key}[#{i}]"], out) if b.is_a?(::Hash) }
      end
    end
  end
  out
end

# A DISTINCT-encoding row: the declaration must be rejected. Reports the collapse it would have emitted, so a
# failure shows the defect rather than just "no error".
def rejects_collapse(&block)
  klass = Class.new do
    include Axn
    class_eval(&block)
    def call; end
  end
  collapsed = collapsed_nodes(klass.input_schema[:properties]) + collapsed_nodes(klass.output_schema[:properties])
  collapsed.empty? ? "declared, no collapse" : "declared, COLLAPSED #{collapsed.inspect}"
rescue ::Axn::DuplicateFieldError => e
  "rejected: #{e.message[0, 60]}"
end

# A SAME-SPELLING row: one wire slot named twice by one spelling is a MERGE. Must declare, and must emit
# exactly one property at every node.
def merges_cleanly(&block)
  klass = Class.new do
    include Axn
    class_eval(&block)
    def call; end
  end
  collapsed = collapsed_nodes(klass.input_schema[:properties]) + collapsed_nodes(klass.output_schema[:properties])
  collapsed.empty? ? "merged, one property" : "COLLAPSED #{collapsed.inspect}"
rescue ::Exception => e
  "#{e.class}: #{e.message.to_s[0, 70]}"
end

REJECTED = /\Arejected: /
MERGED = "merged, one property"

utf8 = UTF8_NAME
iso = LATIN1_NAME
iso_id = CAFE_ID_ISO

check "1x1 top-level vs top-level", REJECTED do
  rejects_collapse { expects utf8, iso }
end

check "1x4 top-level vs model:-generated id", REJECTED do
  rejects_collapse do
    expects utf8, model: WIDGET, optional: true
    expects iso_id, optional: true
  end
end

check "1x4 CONTROL same spelling merges", MERGED do
  merges_cleanly do
    expects utf8, model: WIDGET, optional: true
    expects UTF8_ID, optional: true
  end
end

check "2x2 subfield vs subfield, two routes to one parent", REJECTED do
  rejects_collapse do
    expects :foo, type: Hash
    expects :bar, on: :foo, type: Hash
    expects utf8, on: "foo.bar", optional: true
    expects iso, on: :bar, optional: true
  end
end

check "2x2 CONTROL same spelling merges", MERGED do
  merges_cleanly do
    expects :foo, type: Hash
    expects :bar, on: :foo, type: Hash
    expects utf8, on: "foo.bar", as: :a, optional: true
    expects utf8, on: :bar, as: :b, optional: true
  end
end

check "2x3 subfield vs shape member", REJECTED do
  rejects_collapse do
    expects(:payload, type: Hash) { field utf8, type: String }
    expects iso, on: :payload, optional: true
  end
end

check "2x3 CONTROL same spelling merges", MERGED do
  merges_cleanly do
    expects(:payload, type: Hash) { field utf8, type: String }
    expects utf8, on: :payload, optional: true
  end
end

check "2x3 at depth 2: nested member vs deep subfield", REJECTED do
  rejects_collapse do
    expects(:payload, type: Hash) { field(:mid, type: Hash) { field utf8, type: String } }
    expects iso, on: "payload.mid", optional: true
  end
end

check "2x4 subfield vs generated id under one parent", REJECTED do
  rejects_collapse do
    expects :p, type: Hash
    expects utf8, on: :p, model: WIDGET, optional: true
    expects iso_id, on: :p, optional: true
  end
end

check "2x5 subfield leaf vs implicit intermediate", REJECTED do
  rejects_collapse do
    expects :payload, type: Hash
    expects :leaf, on: "payload.#{utf8}", optional: true
    expects iso, on: :payload, type: Hash, optional: true
  end
end

check "2x5 CONTROL same spelling merges", MERGED do
  merges_cleanly do
    expects :payload, type: Hash
    expects :leaf, on: "payload.#{utf8}", optional: true
    expects utf8, on: :payload, type: Hash, optional: true
  end
end

check "3x3 shape member vs shape member in one block", REJECTED do
  rejects_collapse do
    expects(:payload, type: Hash) do
      field utf8, type: String
      field iso, type: Integer
    end
  end
end

check "3x4 shape member vs generated id", REJECTED do
  rejects_collapse do
    expects(:payload, type: Hash) { field UTF8_ID, type: String }
    expects iso, on: :payload, model: WIDGET, optional: true
  end
end

check "3x4 CONTROL same spelling merges", MERGED do
  merges_cleanly do
    expects(:payload, type: Hash) { field UTF8_ID, type: String }
    expects utf8, on: :payload, model: WIDGET, optional: true
  end
end

check "3x5 shape member vs implicit intermediate", REJECTED do
  rejects_collapse do
    expects(:payload, type: Hash) { field utf8, type: Hash }
    expects :leaf, on: "payload.#{iso}", optional: true
  end
end

check "3x5 CONTROL same spelling merges", MERGED do
  merges_cleanly do
    expects(:payload, type: Hash) { field utf8, type: Hash }
    expects :leaf, on: "payload.#{utf8}", optional: true
  end
end

check "4x5 generated id vs implicit intermediate", REJECTED do
  rejects_collapse do
    expects :payload, type: Hash
    expects utf8, on: :payload, model: WIDGET, optional: true
    expects :leaf, on: "payload.#{iso_id}", optional: true
  end
end

check "5x5 two implicit intermediates", REJECTED do
  rejects_collapse do
    expects :payload, type: Hash
    expects :a, on: "payload.#{utf8}", optional: true
    expects :b, on: "payload.#{iso}", optional: true
  end
end

check "6x3 Data type member vs shape member", REJECTED do
  rejects_collapse { expects(:payload, type: CAFE_DATA) { field iso, type: String } }
end

check "6x3 CONTROL same spelling merges", MERGED do
  merges_cleanly { expects(:payload, type: CAFE_DATA) { field utf8, type: String } }
end

check "OUT 3x3 exposed shape member vs shape member", REJECTED do
  rejects_collapse do
    exposes(:payload, type: Hash) do
      field utf8, type: String
      field iso, type: Integer
    end
  end
end

check "OUT 6x3 exposed Data type member vs shape member", REJECTED do
  rejects_collapse { exposes(:payload, type: CAFE_DATA) { field iso, type: String } }
end

# Mechanism 6 must claim exactly what `Schema#apply_structured_schema!` EMITS. Where the schema deliberately
# omits a structured type's properties, a claim there rejects a declaration the author is entitled to write —
# over-rejection, which is worse than any hole. Where the schema seeds properties by a path the guard does not
# look at (`of:` element types), a missing claim lets two names collapse.
CUSTOM_AS_JSON_DATA = Data.define(:café) do
  def as_json(*) = { "totally" => "different" }
end
CUSTOM_TO_H_DATA = Data.define(:café) do
  def to_h = { totally: "different" }
end

check "OUT Data with a custom as_json: no property to collide with, must DECLARE", MERGED do
  merges_cleanly { exposes(:thing, type: CUSTOM_AS_JSON_DATA) { field iso, type: String } }
end

check "OUT Data with a custom to_h: no property to collide with, must DECLARE", MERGED do
  merges_cleanly { exposes(:thing, type: CUSTOM_TO_H_DATA) { field iso, type: String } }
end

check "OUT plain Data (the control): still rejected", REJECTED do
  rejects_collapse { exposes(:thing, type: CAFE_DATA) { field iso, type: String } }
end

# The inbound side of the same question: input reflects the shape regardless of how the value SERIALIZES, so a
# custom as_json/to_h changes nothing there and the collision is real.
check "IN Data with a custom as_json: still rejected inbound", REJECTED do
  rejects_collapse { expects(:thing, type: CUSTOM_AS_JSON_DATA) { field iso, type: String } }
end

check "IN Data with a custom to_h: still rejected inbound", REJECTED do
  rejects_collapse { expects(:thing, type: CUSTOM_TO_H_DATA) { field iso, type: String } }
end

check "of: Data element members vs a shape member, inside items", REJECTED do
  rejects_collapse { expects :list, type: Array, of: CAFE_DATA, shape: { members: [SC.new(field: iso, validations: { type: String })], container: Array } }
end

check "of: Data element members CONTROL same spelling merges", MERGED do
  merges_cleanly { expects :list, type: Array, of: CAFE_DATA, shape: { members: [SC.new(field: utf8, validations: { type: String })], container: Array } }
end

# A SCALAR `of:` reads members off the element (String#length); the schema emits no member properties at all,
# so two member names there cannot collapse and must not be rejected.
check "scalar of: with colliding member names emits no properties, must DECLARE", MERGED do
  members = [SC.new(field: utf8, validations: {}), SC.new(field: iso, validations: {})]
  merges_cleanly { expects :list, type: Array, of: String, shape: { members:, container: Array } }
end

# Describing a Data class in a collision message must not dispatch the class's own `to_s`.
HOSTILE_TO_S_DATA = Data.define(:café) do
  def self.to_s = raise(NotImplementedError, "hijacked from Class#to_s")
end

check "hostile Class#to_s on a Data type: reported without dispatching it", REJECTED do
  rejects_collapse { expects(:thing, type: HOSTILE_TO_S_DATA) { field iso, type: String } }
end

# A dotted `on:` segment becomes an implicit property name in the reflected schema on exactly the same terms
# as a declared field or member name, so it carries the same UTF-8 promise. The claim space silently discarded
# claims containing an unrenderable segment, which is what hid this: SubfieldTree still emitted the segment.
BAD_SEGMENT = "bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym

check "unrenderable dotted route segment is rejected at declaration", /ArgumentError.*bytes that have no UTF-8 rendering/ do
  route = "payload.#{BAD_SEGMENT}"
  project do
    expects :payload, type: Hash
    expects :leaf, on: route, optional: true
  end
end

# An unrenderable ROOT segment used to reach the reader-existence check, whose message interpolates `on:` —
# so the caller saw an encoding failure from the reporting instead of the naming defect being reported.
# In the ROOT position the accurate diagnosis is a missing reader — nothing is declared under an unrenderable
# name. What must not happen is the message failing to BUILD: it interpolates `on:`, and raw non-UTF-8 bytes
# there raised Encoding::CompatibilityError from the reporting itself.
check "unrenderable route ROOT reports a missing reader, not an encoding failure", /ArgumentError.*no such reader exists/ do
  bad = BAD_SEGMENT
  project do
  expects :leaf, on: bad, optional: true
  end
end

check "a valid non-ASCII dotted route segment still declares and emits its property", ["café"] do
  route = "payload.#{UTF8_NAME}"
  klass = Class.new do
    include Axn
    expects :payload, type: Hash
    expects :leaf, on: route, optional: true
    def call; end
  end
  klass.input_schema.dig(:properties, :payload, :properties).keys.map { |k| Axn::Reflection::Values.canonical_wire_key(k) }
end

check "a plain ASCII dotted route is unaffected", %w[mid] do
  klass = Class.new do
    include Axn
    expects :payload, type: Hash
    expects :leaf, on: "payload.mid", optional: true
    def call; end
  end
  klass.input_schema.dig(:properties, :payload, :properties).keys.map(&:to_s)
end

# A structured type's own members become property names too, so an unrenderable one is the same defect a
# field name or a shape member name already carries — the third surface for one rule.
BAD_MEMBER_DATA = Data.define("bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym, :ok)

check "unrenderable Data type member name is rejected at declaration", /ArgumentError.*bytes that have no UTF-8 rendering/ do
  project { expects(:t, type: BAD_MEMBER_DATA, optional: true) { field :ok, type: String } }
end

check "unrenderable Data type member name is rejected outbound too", /ArgumentError.*bytes that have no UTF-8 rendering/ do
  project do
  exposes(:t, type: BAD_MEMBER_DATA, optional: true) { field :ok, type: String }
  end
end

check "a renderable non-ASCII Data member name still declares", ["café"] do
  shaped = Data.define(:café)
  klass = Class.new do
    include Axn
    expects(:t, type: shaped, optional: true) { field :other, type: String }
    def call; end
  end
  klass.input_schema.dig(:properties, :t, :properties).keys.map { |k| Axn::Reflection::Values.canonical_wire_key(k) }.sort.first(1)
end

# A raw `shape:` may name its own `container:`, and nothing checked it was a class — so a junk value reached
# ShapeValidator's `value.is_a?(container)` and every call raised a bare TypeError.
check "a non-class container: is rejected at declaration", /ArgumentError.*container:/ do
  members = [SC.new(field: :a, validations: {})]
  klass = Class.new do
    include Axn
    expects :p, type: Hash, shape: { members:, container: :junk }
    def call; end
  end
  r = klass.call(p: { a: 1 })
  "declared; call ok?=#{r.ok?} exception=#{r.exception&.class}"
end

check "a valid container: still declares and validates", true do
  members = [SC.new(field: :a, validations: { presence: true })]
  klass = Class.new do
    include Axn
    expects :p, type: Hash, shape: { members:, container: Hash }
    def call; end
  end
  klass.call(p: { a: 1 }).ok? && !klass.call(p: {}).ok?
end

# Derivation is only as good as the walker's coverage of WHERE properties are emitted. A multi-klass `of:`
# reflects as `items: { anyOf: [...] }`, and each branch carries its own `properties` — a namespace the walker
# has to visit, but branches are ALTERNATIVES, so one name in two different branches is not a collision.
COLLIDING_DATA = Data.define(:café, "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym)
OTHER_DATA = Data.define(:other)
BRANCH_A = Data.define(:shared)
BRANCH_B = Data.define(:shared)

check "collision inside an anyOf branch is rejected", REJECTED do
  rejects_collapse { expects :l, type: Array, of: [COLLIDING_DATA, OTHER_DATA], optional: true }
end

check "the same name in two different anyOf branches still declares", MERGED do
  merges_cleanly { expects :l, type: Array, of: [BRANCH_A, BRANCH_B], optional: true }
end

# Derivation is only as good as the seam's agreement on WHICH members exist. The guard captures members with
# `each`; the emitter must too, or a member list that answers `filter_map` differently makes them disagree.
# Overrides every Enumerable convenience a consumer might reach for, leaving only `each` honest — so any
# consumer not going through the shared seam is visible.
SNEAKY_MEMBER_LIST = Class.new(Array) do
  def filter_map(*) = []
  def map(*) = []
  def select(*) = []
  def flat_map(*) = []
  def any?(*) = false
  def to_a = []
end

check "a member list hiding itself from filter_map: emitter and guard agree", REJECTED do
  members = SNEAKY_MEMBER_LIST.new([SC.new(field: UTF8_NAME, validations: {}), SC.new(field: LATIN1_NAME, validations: {})])
  rejects_collapse { expects :p, type: Hash, shape: { members:, container: Hash } }
end

check "a hidden member is still redacted when sensitive:", "[FILTERED]" do
  members = SNEAKY_MEMBER_LIST.new([SC.new(field: :secret, validations: {}, sensitive: true)])
  klass = Class.new do
    include Axn
    expects :p, type: Hash, shape: { members:, container: Hash }
    def call; end
  end
  klass.send(:_context_slice, data: { p: { secret: "SHH" } }, direction: :inbound).dig(:p, :secret)
end

check "all three walks see the same member count", [2, 2, 2] do
  members = SNEAKY_MEMBER_LIST.new([SC.new(field: :a, validations: {}), SC.new(field: :b, validations: {})])
  klass = Class.new do
    include Axn
    expects :p, type: Hash, shape: { members:, container: Hash }
    def call; end
  end
  stored = klass.internal_field_configs.first.validations[:shape][:members]
  [Axn::Internal::ShapeGraph.capture(stored).size,                       # the guard's seam
   klass.input_schema.dig(:properties, :p, :properties).keys.size,       # the emitter
   stored.each_with_object([]) { |m, acc| acc << m }.size]               # runtime validation
end

# Derivation is only as good as the plan's fidelity to WHETHER properties are emitted. A `Data` used only as
# `type:` — no shape, no `of:` — emits no member properties at all, so its member names name nothing.
BIN_MEMBER_DATA = Data.define("bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym)

check "a Data used only as type: declares, since it emits no member properties", "declared" do
  project do
  expects :payload, type: BIN_MEMBER_DATA, optional: true
  end
end

check "the same Data WITH a shape overlay still rejects", /ArgumentError.*bytes that have no UTF-8 rendering/ do
  project do
  expects(:payload, type: BIN_MEMBER_DATA, optional: true) { field :ok, type: String }
  end
end

# The unrenderable-name rule is judged on the EMITTED property name, so a name the schema never emits names
# nothing and is not a defect. One row per name group, on the surface each actually reaches.
GATED_BAD_DATA = Data.define("bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym, :ok)
BAD_NAME = "bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym

class COR_WIDGET
  def self.name = "Widget"
  def self.find(_id) = new
end

check "type member of an OUTBOUND-GATED type: not emitted, so it declares", "declared" do
  project do
  exposes(:t, type: { klass: GATED_BAD_DATA, if: :flag }) { field :ok, type: String }
  def flag = true
  end
end

check "CONTROL ungated type: still rejects", /ArgumentError.*a member of a declared type/ do
  project do
  exposes(:t, type: GATED_BAD_DATA) { field :ok, type: String }
  end
end

check "dropped subfield leaf: not emitted, so it declares", "declared" do
  bad = BAD_NAME
  project do
  expects :rec, model: COR_WIDGET, optional: true
  expects :mid, on: :rec, type: Hash, optional: true, method_call: true
  expects bad, on: "rec.mid", optional: true
  end
end

check "shape member under a scalar of:: not emitted, so it declares", "declared" do
  members = [SC.new(field: BAD_NAME, validations: {})]
  project do
  expects :list, type: Array, of: String, shape: { members:, container: Array }
  end
end

check "shape member on a custom-as_json exposes: not emitted, so it declares", "declared" do
  members = [SC.new(field: BAD_NAME, validations: { type: String })]
  project do
  exposes :t, type: CUSTOM_AS_JSON_DATA, shape: { members:, container: Hash }
  end
end

# The groups that ARE emitted still reject, each with the wording its source has always had.
check "an EMITTED expects field name still rejects", /ArgumentError.*a field name becomes a JSON property name/ do
  bad = BAD_NAME
  project do
  expects bad, optional: true
  end
end

check "an EMITTED shape member name still rejects", /ArgumentError.*a shape member name becomes a JSON property name/ do
  members = [SC.new(field: BAD_NAME, validations: {})]
  project do
  expects :p, type: Hash, shape: { members:, container: Hash }
  end
end

check "an EMITTED dotted route segment still rejects", /ArgumentError.*a nested key in `on:` becomes a JSON property name/ do
  route = "payload.#{BAD_NAME}"
  project do
  expects :payload, type: Hash
  expects :leaf, on: route, optional: true
  end
end

# An exposes field name reaches the SERIALIZED BODY too (`Values.serialize_exposed`), not only the schema, so
# it is rejected pre-build regardless of what the schema emits.
check "an exposes field name is rejected pre-build, whatever the schema emits", /ArgumentError.*a field name becomes a JSON property name/ do
  bad = BAD_NAME
  project do
  exposes bad, optional: true
  end
end

check "two unrenderable emitted names report one of them, not a false collision", /ArgumentError.*bytes that have no UTF-8 rendering/ do
  members = [SC.new(field: BAD_NAME, validations: {}), SC.new(field: "worse\xFE".dup.force_encoding("ASCII-8BIT").to_sym, validations: {})]
  project do
  expects :p, type: Hash, shape: { members:, container: Hash }
  end
end

# A contract must not change after the class is declared. Storing the caller's own shape object aliases it, so
# the graph is deep-copied at declaration: what these rows pin is that an already-declared contract is immune to
# later mutation, while the legitimate patterns (a builder reused across declarations, one shape shared by two
# axns) keep working — copying is what makes both true, where freezing would break the first.
def declared_props(raw)
  expects_axn(raw, type: Hash).input_schema.dig(:properties, :payload, :properties).keys
end

check "a contract declared earlier does not gain members appended later", [%i[one], %i[one two]] do
  builder = { members: [], container: Hash }
  builder[:members] << SC.new(field: :one, validations: {})
  first = expects_axn(builder, type: Hash)
  builder[:members] << SC.new(field: :two, validations: {})
  second = expects_axn(builder, type: Hash)
  [first, second].map { |k| k.input_schema.dig(:properties, :payload, :properties).keys }
end

check "a nested raw shape mutated after declaration does not change it", [%i[deep], %i[deep]] do
  inner = { members: [SC.new(field: :deep, validations: {})], container: Hash }
  outer = { members: [SC.new(field: :mid, validations: { type: { klass: Hash }, shape: inner })], container: Hash }
  klass = expects_axn(outer, type: Hash)
  before = klass.input_schema.dig(:properties, :payload, :properties, :mid, :properties).keys
  inner[:members] << SC.new(field: :sneaked, validations: {})
  [before, klass.input_schema.dig(:properties, :payload, :properties, :mid, :properties).keys]
end

check "one shape Hash shared by two axns still works", [%i[s], %i[s]] do
  shared = { members: [SC.new(field: :s, validations: {})], container: Hash }
  [declared_props(shared), declared_props(shared)]
end

check "the caller's own shape object is not frozen", false do
  raw = { members: [SC.new(field: :s, validations: {})], container: Hash }
  expects_axn(raw, type: Hash)
  raw[:members] << SC.new(field: :later, validations: {}) # would raise FrozenError if we froze it
  raw.frozen? || raw[:members].frozen?
end

# The same aliasing in the other option containers axn stores.
# No tolerance flag here on purpose: `optional:`/`allow_nil:`/`allow_blank:` push tolerance into each validator,
# which rebuilds the option bags as a side effect and would detach this one incidentally — hiding the aliasing
# rather than testing it.
check "a mutated of: bag does not change a declared element type", true do
  opts = { klass: String }
  klass = Class.new do
    include Axn
    expects :list, type: Array, of: opts
    def call; end
  end
  before = klass.input_schema.dig(:properties, :list, :items)
  opts[:klass] = Integer
  before == klass.input_schema.dig(:properties, :list, :items)
end

check "a mutated validate: bag does not change which validator runs", [false, false] do
  bag = { with: ->(v) { "bad" if v == 1 } }
  klass = Class.new do
    include Axn
    expects :n, validate: bag
    def call; end
  end
  first = klass.call(n: 1).ok?
  bag[:with] = ->(_v) { nil }
  [first, klass.call(n: 1).ok?]
end

check "a mutated inclusion: list does not widen a declared enum", true do
  values = %w[a b]
  klass = Class.new do
    include Axn
    expects :a, inclusion: { in: values }, optional: true
    def call; end
  end
  before = klass.input_schema.dig(:properties, :a, :enum)
  values << "c"
  before == klass.input_schema.dig(:properties, :a, :enum)
end

# A raw MEMBER's options are detached on the same terms as a field's — they were not, because the member path
# skipped the copy whenever no key needed canonicalizing, and those are different questions.
def member_inclusion_axn(validations)
  member = SC.new(field: :choice, validations: validations)
  Class.new do
    include Axn
    expects :payload, type: Hash, shape: { members: [member], container: Hash }
    def call; end
  end
end

def member_accepts_after(validations, mutate)
  klass = member_inclusion_axn(validations)
  before = klass.call(payload: { choice: "c" }).ok?
  mutate.call
  [before, klass.call(payload: { choice: "c" }).ok?]
rescue ::Exception => e
  "#{e.class}: #{e.message[0, 45]}"
end

check "a mutated member inclusion: list cannot widen its enum", [false, false] do
  allowed = %w[a b]
  member_accepts_after({ inclusion: { in: allowed } }, -> { allowed << "c" })
end

check "a mutated member option BAG cannot change what it validates", [false, false] do
  bag = { in: %w[a b] }
  member_accepts_after({ inclusion: bag }, -> { bag[:in] = %w[a b c] })
end

# The control the fix must not break: a member's container is copied and its class kept, so a subclass that adds
# no code of its own decides membership exactly as it declared...
check "a member subclass with no code of its own still decides", [true, false] do
  values = Class.new(Array).new.push("a", "b")
  klass = member_inclusion_axn({ inclusion: { in: values } })
  [klass.call(payload: { choice: "a" }).ok?, klass.call(payload: { choice: "z" }).ok?]
end

# ...one that answers membership ITSELF is refused for a member on the same terms as for a field...
check "a member container answering membership itself is refused", /ArgumentError: the `inclusion: \{ in: … \}` container/ do
  values = Class.new(Array) { def include?(_v) = true }.new.push("a", "b")
  member_accepts_after({ inclusion: { in: values } }, -> {})
end

# ...and so is one that owns a duplication hook.
check "a member container that owns a duplication hook is refused", /ArgumentError: the `inclusion: \{ in: … \}` container/ do
  values = Class.new(Array) do
    def initialize_dup(source)
      super
      clear
    end
  end.new.push("a", "b")
  member_accepts_after({ inclusion: { in: values } }, -> {})
end

# The top-level control, unchanged by this: it was already detached.
check "the top-level field control is unchanged", [false, false] do
  allowed = %w[a b]
  klass = Class.new do
    include Axn
    expects :choice, inclusion: { in: allowed }
    def call; end
  end
  before = klass.call(choice: "c").ok?
  allowed << "c"
  [before, klass.call(choice: "c").ok?]
end

# A container is detached whatever it claims about itself, and one that answers anything with its own code is
# refused instead of copied. The rows below are the counterexamples in the order they arrived — each defeated the
# gate the row above it established — plus the frozen escape hatch and the plain-Array/plain-Hash controls.
def inclusion_axn(values)
  Class.new do
    include Axn
    expects :choice, inclusion: values
    def call; end
  end
end

def accepts_after_mutation(values, mutate)
  klass = inclusion_axn(values)
  before = klass.call(choice: "c").ok?
  mutate.call
  [before, klass.call(choice: "c").ok?]
end

def declaration_verdict(values)
  inclusion_axn({ in: values }) && "declared"
rescue ::Exception => e # rubocop:disable Lint/RescueException
  "#{e.class}: #{e.message}"
end

check "an inclusion set denying its own class is refused", /ArgumentError.*defines methods of its own/ do
  values = Class.new(Array) { def is_a?(other) = ::Array.equal?(other) ? false : super }.new(%w[a b])
  declaration_verdict(values)
end

check "an inclusion set whose dup returns self is refused", /ArgumentError.*defines methods of its own/ do
  values = Class.new(Array) { def dup = self }.new(%w[a b])
  declaration_verdict(values)
end

check "a bag whose transform_values returns self is still detached", [false, false] do
  bag = Class.new(Hash) { def transform_values(&) = self }.new
  bag[:in] = %w[a b]
  accepts_after_mutation(bag, -> { bag[:in] << "c" })
end

# A container that answers ANYTHING with code of its own is refused at declaration, because what that code
# answers in the copy cannot be established without running it. That is a deliberate over-rejection, and it
# replaces two rounds of verifying the copy and one of gating on the duplication hooks — each of which this
# file recorded as closed, and each of which a later row's counterexample defeated.
check "an inclusion set whose dup drops its elements is refused", /ArgumentError.*defines methods of its own/ do
  values = Class.new(Array) do
    def initialize_dup(source)
      super
      clear
    end
  end.new.push("a", "b")
  declaration_verdict(values)
end

# Round one's counterexample: the elements are what a set holds, but its own `include?` is what a declaration
# MEANS, and that can be derived from state the elements do not determine. This copy holds every declared element
# and rejects them all, so comparing ELEMENTS saw nothing wrong.
check "an inclusion set whose dup drops its derived index is refused", /ArgumentError.*defines methods of its own/ do
  values = Class.new(Array) do
    def initialize(*args)
      super
      @index = to_a.map(&:to_s)
    end

    def initialize_dup(source)
      super
      @index = []
    end

    def include?(value) = (@index || []).include?(value.to_s)
  end.new(%w[a b])
  declaration_verdict(values)
end

# Round two's counterexample, and why no probe closes this: membership can accept values that are not ELEMENTS,
# so asking the copy `include?` about each element agreed with the original while the copy had silently stopped
# accepting the aliases the original accepted. The accepted set is whatever arbitrary code says, so it is not
# enumerable from outside.
check "an inclusion set whose dup drops an alias index is refused", /ArgumentError.*defines methods of its own/ do
  values = Class.new(Array) do
    def initialize(*args)
      super
      @aliases = { "alias" => "canon" }
    end

    def initialize_dup(source)
      super
      @aliases = {}
    end

    def include?(value) = to_a.include?(value) || @aliases.key?(value.to_s)
  end.new(%w[canon])
  declaration_verdict(values)
end

# Round three's counterexample, which moved the gate from the duplication HOOKS to everything a container answers
# with: no hook at all, native duplication throughout, and the copy still disagrees — `dup` copies the elements
# but shares the ivars, so a membership derived from IDENTITY reads false in the copy and axn rejected a value the
# caller had declared as accepted. The lesson is that native duplication only buys a faithful copy where the
# copied state (the elements) determines the answers, i.e. where the answers are Ruby's own.
def identity_membership_class
  Class.new(Array) do
    def initialize(*args)
      super
      @me = self
    end

    def include?(value) = @me.equal?(self) && to_a.include?(value)
  end
end

check "an inclusion set whose membership is its own identity is refused", /ArgumentError.*defines methods of its own \(`:include\?`/ do
  declaration_verdict(identity_membership_class.new(%w[ok]))
end

check "that same set FROZEN declares and answers membership as declared", [true, false] do
  klass = inclusion_axn({ in: identity_membership_class.new(%w[ok]).freeze })
  [klass.call(choice: "ok").ok?, klass.call(choice: "z").ok?]
end

# The same defect through the other thing `dup` does not carry: a SINGLETON `include?` (or one from an extended
# module, which lives in the same ancestry) answers on the original and is simply absent from the copy. Only a
# lookup that goes through the object sees either.
check "a plain Array whose singleton answers membership is refused", /ArgumentError.*defines methods of its own \(`:include\?`\)/ do
  values = %w[a b]
  values.define_singleton_method(:include?) { |_v| true }
  declaration_verdict(values)
end

check "a plain Array with an extended membership module is refused", /ArgumentError.*defines methods of its own \(`:include\?`\)/ do
  values = %w[a b]
  values.extend(Module.new { def include?(_v) = true })
  declaration_verdict(values)
end

# And the third: `dup` SHARES the ivars, so a membership reading one is still the caller's to widen after the
# class is declared — the aliasing the copy exists to prevent, reached without any hook.
check "an inclusion set whose membership reads a shared ivar is refused", /ArgumentError.*defines methods of its own/ do
  values = Class.new(Array) do
    def initialize(*args)
      super
      @extra = []
    end

    attr_reader :extra

    def include?(value) = to_a.include?(value) || @extra.include?(value)
  end.new(%w[a])
  declaration_verdict(values)
end

# `include?` is not the only thing a stored option container is asked, which is why the gate is not a list of the
# predicates one consumer dispatches: `type:`/`of:` reach the same copy path and axn reads them with
# `Array(…)`/`any?`, so an identity-dependent `any?` made a declared `type: String` reject a String.
check "a type: container deciding with its own any? is refused", /ArgumentError: the `type:` container.*defines methods of its own/ do
  values = Class.new(Array) do
    def initialize(*args)
      super
      @me = self
    end

    def any?(&) = @me.equal?(self) ? super : false
  end.new([String])
  Class.new do
    include Axn
    expects :choice, type: values
    def call; end
  end && "declared"
rescue ::Exception => e # rubocop:disable Lint/RescueException
  "#{e.class}: #{e.message}"
end

# `exclusion:` is the same copy and the same ActiveModel `include?` with the verdict inverted, so the same
# divergence ADMITS what the declaration excluded.
check "an exclusion: container answering with its own code is refused", /ArgumentError: the `exclusion: \{ in: … \}` container.*defines methods of its own/ do
  values = identity_membership_class.new(%w[bad])
  Class.new do
    include Axn
    expects :choice, exclusion: { in: values }
    def call; end
  end && "declared"
rescue ::Exception => e # rubocop:disable Lint/RescueException
  "#{e.class}: #{e.message}"
end

check "a frozen exclusion: container excludes exactly what it declared", [false, true] do
  values = identity_membership_class.new(%w[bad]).freeze
  klass = Class.new do
    include Axn
    expects :choice, exclusion: { in: values }
    def call; end
  end
  [klass.call(choice: "bad").ok?, klass.call(choice: "fine").ok?]
end

# The bounded escape hatch that keeps the over-rejection honest: the copy exists so a caller's later mutation
# cannot change a declared contract, and a FROZEN container cannot be mutated — so it is stored as-is, hook and
# all, and its own `include?` decides membership. A container that rebuilds its index faithfully stays legal this
# way, at the cost of freezing it.
check "a frozen inclusion set that reindexes on dup still works", [true, false] do
  values = Class.new(Array) do
    def initialize(*args)
      super
      @index = each_with_object({}) { |v, h| h[v] = true }
    end

    def initialize_dup(source)
      super
      @index = {}
    end

    def include?(value) = @index.key?(value)
  end.new(%w[x y]).freeze
  klass = inclusion_axn({ in: values })
  [klass.call(choice: "x").ok?, klass.call(choice: "z").ok?]
end

# A frozen PLAIN Array is stored as-is too, rather than copied: same reasoning, and the stored object IS the
# caller's. (A lying `frozen?` cannot buy this — the flag is read through a bound `Kernel#frozen?`.)
check "a frozen plain inclusion set is stored without copying", [true, true, false] do
  values = %w[x y].freeze
  klass = inclusion_axn({ in: values })
  [klass.internal_field_configs.first.validations.dig(:inclusion, :in).equal?(values),
   klass.call(choice: "x").ok?, klass.call(choice: "z").ok?]
end

check "a container whose frozen? lies is not stored as-is", /ArgumentError.*defines methods of its own/ do
  values = Class.new(Array) do
    def frozen? = true
    def initialize_dup(source) = super
  end.new(%w[x y])
  declaration_verdict(values)
end

# A singleton duplication hook is refused too — not because `dup` can reach it (it cannot: the copy carries no
# singleton) but because the rule asked is whether the container answers anything with its own code, and a
# carve-out for a method nothing dispatches would be one more guarantee about foreign code to get wrong.
check "a SINGLETON duplication hook is refused as well", /ArgumentError.*defines methods of its own \(`:initialize_dup`\)/ do
  values = %w[a b]
  values.define_singleton_method(:initialize_dup) { |_source| clear }
  declaration_verdict(values)
end

# ...and the refusal does not over-reach: a subclass that adds no code of its own is copied exactly as a plain
# Array is, keeping the caller's CLASS (which is why reflection still withholds an enum — it does that for
# anything but an exact Array).
check "a subclass with no code of its own is copied, class and all", ["declared", false, true, nil] do
  subclass = Class.new(Array)
  values = subclass.new(%w[a b])
  klass = inclusion_axn({ in: values })
  stored = klass.internal_field_configs.first.validations.dig(:inclusion, :in)
  ["declared", stored.equal?(values), stored.class.equal?(subclass),
   klass.input_schema.dig(:properties, :choice, :enum)]
end

# A RESIDUE row: freezing freezes the container's own slots, not the objects its ivars point at, so a frozen
# container deriving membership from a mutable index is still the caller's to widen after the class is declared.
# The same one-level depth the copy promises for elements — recorded so the escape hatch does not read as more.
check "a frozen container's ivar-derived membership is still the caller's to widen", [false, true] do
  index = { "a" => true }
  values = Class.new(Array) do
    define_method(:initialize) do |*args, idx|
      super(*args)
      @index = idx
    end

    def include?(value) = @index.key?(value)
  end.new(%w[a], index).freeze
  klass = inclusion_axn({ in: values })
  before = klass.call(choice: "c").ok?
  index["c"] = true
  [before, klass.call(choice: "c").ok?]
end

# A RESIDUE row, not a guarantee: a membership container that is not an Array never reaches the copy at all, so
# nothing of axn's answers membership (no divergence is possible) but nothing detaches it either — a mutable Set
# can still be widened after the class is declared. A Range is frozen by construction.
check "a Set membership container is stored as the caller's own object", [true, false, true] do
  require "set"
  values = Set.new(%w[a])
  klass = inclusion_axn({ in: values })
  stored = klass.internal_field_configs.first.validations.dig(:inclusion, :in).equal?(values)
  before = klass.call(choice: "c").ok?
  values << "c"
  [stored, before, klass.call(choice: "c").ok?]
end

# A member that answers to no `field` cannot be declared: runtime validation reads `member.field` for every
# member, so skipping it in the guard produced a contract that declared, reflected the member as nothing, and
# then raised NoMethodError on the first call.
def nameless_member_verdict(member)
  klass = expects_axn({ members: [member, SC.new(field: :a, validations: {})], container: Hash }, type: Hash)
  "declared: schema=#{klass.input_schema.dig(:properties, :payload, :properties).keys.inspect} " \
    "call=#{begin; klass.call!(payload: { a: 1 }); "ok"; rescue ::Exception => e; e.class; end}"
rescue ::ArgumentError => e
  "ArgumentError: #{e.message[0, 60]}"
rescue ::Exception => e
  "#{e.class}: #{e.message}"
end

check "a member with validations but no field is rejected", /ArgumentError: a shape member must answer to `field`/ do
  nameless_member_verdict(Class.new { def validations = { type: { klass: String } } }.new)
end

check "a member answering to nothing at all is rejected too", /ArgumentError: a shape member must answer to `field`/ do
  nameless_member_verdict(Object.new)
end

# The legal duck-typed member — both documented readers and nothing else — still declares, projects and
# validates. The rejection must not reach it.
check "a member with field + validations works end to end", [[:a], "string", true, false] do
  member = Class.new do
    def field = :a
    def validations = { type: { klass: String } }
  end.new
  klass = expects_axn({ members: [member], container: Hash }, type: Hash)
  props = klass.input_schema.dig(:properties, :payload, :properties)
  [props.keys, props.dig(:a, :type), klass.call(payload: { a: "ok" }).ok?, klass.call(payload: { a: 1 }).ok?]
end

# An option bag is axn's own grammar and every consumer reads it with Symbols, so a String-keyed bag (a
# params-derived Hash, or `.with_indifferent_access`) answered nobody: the declaration succeeded and the field
# then rejected the values it was declared to accept. Six families, each checked BOTH ways round — the declared
# value accepted, an undeclared one still rejected — because "accepts everything" would pass a one-sided row.
def stringify(hash) = hash.to_h { |key, value| [key.to_s, value] }

def declares_and_validates(good, bad, **options)
  klass = Class.new do
    include Axn
    expects :a, **options
    def call; end
  end
  [klass.call(a: good).ok?, klass.call(a: bad).ok?]
rescue ::Exception => e
  "#{e.class}: #{e.message[0, 70]}"
end

check "a String-keyed type: bag validates", [true, false] do
  declares_and_validates("x", 1, type: stringify(klass: String))
end

check "a String-keyed of: bag validates", [true, false] do
  declares_and_validates(%w[x], [1], type: Array, of: stringify(klass: String))
end

check "a String-keyed inclusion: bag validates", [true, false] do
  declares_and_validates("a", "z", inclusion: stringify(in: %w[a b]))
end

check "a String-keyed validate: bag validates", [true, false] do
  declares_and_validates(2, 1, validate: stringify(with: ->(v) { "bad" if v == 1 }))
end

check "a String-keyed length: bag validates (an ActiveModel one)", [true, false] do
  declares_and_validates("abcd", "a", length: stringify(minimum: 3))
end

check "an indifferent-access bag validates", [true, false] do
  declares_and_validates("a", "z", inclusion: { in: %w[a b] }.with_indifferent_access)
end

# `model:` resolved a class inferred from the FIELD NAME while the declared one went unread.
check "a String-keyed model: bag resolves the declared class", true do
  record = Struct.new(:id) { def self.find(id) = new(id) }
  klass = Class.new do
    include Axn
    expects :thing, model: { "klass" => record }
    def call; end
  end
  klass.call(thing_id: 7).ok?
rescue ::Exception => e
  "#{e.class}: #{e.message[0, 70]}"
end

# The control: a Symbol-keyed bag behaves exactly the same, and is not rebuilt on the way through.
check "a Symbol-keyed bag behaves identically", [[true, false], ["a", "b"]] do
  klass = Class.new do
    include Axn
    expects :a, inclusion: { in: %w[a b] }
    def call; end
  end
  [[klass.call(a: "a").ok?, klass.call(a: "z").ok?], klass.input_schema.dig(:properties, :a, :enum)]
end

# Canonicalizing keys must not mask the rejection that already governs an unrecognized key — which lives at the
# declaration level, above the bag, and still decides first.
check "an unrecognized declaration-level String key is still rejected", /Unknown key\(s\) "type"/ do
  Class.new do
    include Axn
    expects :a, "type" => String
    def call; end
  end
  "declared"
rescue ::Exception => e
  "#{e.class}: #{e.message}"
end

# ...and an unrecognized key INSIDE a bag stays exactly as inert as its Symbol spelling (nothing reads either).
check "an unrecognized key inside a bag is as inert as its Symbol form", [[true, false], [true, false]] do
  [declares_and_validates("a", "z", inclusion: { "in" => %w[a b], "bogus" => 1 }),
   declares_and_validates("a", "z", inclusion: { in: %w[a b], bogus: 1 })]
end

check "one option under both spellings is rejected", /ArgumentError.*declares :in twice/ do
  declares_and_validates("a", "z", inclusion: { "in" => %w[a b], :in => %w[c] })
end

# A raw `shape:` member bypasses `expects`' option handling, and the copy turns an indifferent-access Hash into
# a plain one — so its grammar is canonicalized where the copy is taken.
check "a String-keyed member's grammar validates", [[:a], true, false] do
  m = SC.new(field: :a, validations: { "type" => { "klass" => String } })
  klass = expects_axn({ members: [m], container: Hash }, type: Hash)
  [klass.input_schema.dig(:properties, :payload, :properties).keys,
   klass.call(payload: { a: "x" }).ok?, klass.call(payload: { a: 1 }).ok?]
end

check "an indifferent-access member's grammar validates", [true, false] do
  m = SC.new(field: :a, validations: { type: { klass: String } }.with_indifferent_access)
  klass = expects_axn({ members: [m], container: Hash }, type: Hash)
  [klass.call(payload: { a: "x" }).ok?, klass.call(payload: { a: 1 }).ok?]
end

# The same, on a DUCK-TYPED member — which is where the canonical copy used to be computed and then thrown away,
# because the member was stored as the caller's object. The schema omitted the type constraint entirely while
# every call raised `ArgumentError: must supply :klass` from the raw String-keyed bag: two layers, two answers,
# neither the declaration. One snapshot, one canonical form, both layers reading it.
check "a duck-typed member's String-keyed grammar validates too", [["string"], true, false] do
  m = Struct.new(:field, :validations).new(:a, { "type" => { "klass" => String } })
  klass = expects_axn({ members: [m], container: Hash }, type: Hash)
  [Array(klass.input_schema.dig(:properties, :payload, :properties, :a, :type)),
   klass.call(payload: { a: "x" }).ok?, klass.call(payload: { a: 1 }).ok?]
end

# The control it must match: the Symbol-keyed spelling of the same duck-typed member, unchanged throughout.
check "a duck-typed member's Symbol-keyed grammar is identical", [["string"], true, false] do
  m = Struct.new(:field, :validations).new(:a, { type: { klass: String } })
  klass = expects_axn({ members: [m], container: Hash }, type: Hash)
  [Array(klass.input_schema.dig(:properties, :payload, :properties, :a, :type)),
   klass.call(payload: { a: "x" }).ok?, klass.call(payload: { a: 1 }).ok?]
end

# A retained member's `sensitive:` settled nothing consistently: the redaction table keys on the IDENTITY of the
# config arrays, which a member's own state cannot change, so flipping it after declaration took effect or did
# not depending only on whether anything had asked yet. Snapshotted, both directions are inert and the DECLARED
# behaviour is what persists — read first or not.
def sensitive_after_mutation(declared, mutated, read_first:)
  member = Struct.new(:field, :validations, :sensitive).new(:ssn, {}, declared)
  klass = expects_axn({ members: [member], container: Hash }, type: Hash)
  klass.sensitive_fields if read_first
  member.sensitive = mutated
  [klass.sensitive_fields,
   klass.send(:_context_slice, data: { payload: { ssn: "SHH" } }, direction: :inbound).dig(:payload, :ssn)]
end

check "flipping a member's sensitive: ON after declaration changes nothing", [[[], "SHH"], [[], "SHH"]] do
  [sensitive_after_mutation(false, true, read_first: false), sensitive_after_mutation(false, true, read_first: true)]
end

check "...and flipping it OFF leaves the declared redaction in place", [[[:ssn], "[FILTERED]"], [[:ssn], "[FILTERED]"]] do
  [sensitive_after_mutation(true, false, read_first: false), sensitive_after_mutation(true, false, read_first: true)]
end

check "a String-keyed member's metadata is read", "the a" do
  m = SC.new(field: :a, validations: {}, metadata: { "description" => "the a" })
  klass = expects_axn({ members: [m], container: Hash }, type: Hash)
  klass.input_schema.dig(:properties, :payload, :properties, :a, :description)
end

# The snapshot stops at no member: a duck-typed one is read once and rebuilt as axn's own ShapeConfig, so the
# nested shape it carries is copied too and mutating the caller's Hash afterwards changes nothing. This row was
# the recorded residue until the snapshot covered it.
check "a duck-typed member's nested shape is copied too", [%i[deep], %i[deep]] do
  inner = { members: [SC.new(field: :deep, validations: {})], container: Hash }
  duck = Class.new do
    define_method(:initialize) { |v| @validations = v }
    def field = :mid
    attr_reader :validations
    def metadata = {}
    def description = nil
    def optional? = true
  end.new({ type: { klass: Hash }, shape: inner })
  klass = expects_axn({ members: [duck], container: Hash }, type: Hash)
  before = klass.input_schema.dig(:properties, :payload, :properties, :mid, :properties).keys
  inner[:members] << SC.new(field: :sneaked, validations: {})
  [before, klass.input_schema.dig(:properties, :payload, :properties, :mid, :properties).keys]
end

# Attribution enriches a message for a verdict that is ALREADY established, so it must not be able to replace
# it. The deep snapshot closed both halves of this outright: every walk after declaration iterates axn's own
# copy, and every member reader is read once and rebuilt into axn's own ShapeConfig. What these rows now pin is
# that ONE read: a list or a reader that misbehaves on a later one never gets it.
def nth_walk_raiser(nth, *members)
  Class.new(Array) do
    define_method(:initialize) { |a| super(a); @walks = 0 }
    define_method(:each) do |&b|
      @walks += 1
      raise(NotImplementedError, "walk #{nth} explodes") if @walks == nth

      super(&b)
    end
  end.new(members)
end

# Counts its own reads, so a row can name WHICH read would break.
def reader_raising_member(nth)
  Class.new do
    define_method(:initialize) { @reads = 0 }
    define_method(:field) do
      @reads += 1
      raise(NotImplementedError, "read #{nth} explodes") if @reads == nth

      UTF8_NAME
    end
    def validations = {}
    def metadata = {}
    def description = nil
    def optional? = true
  end.new
end

def verdict_when_reader_breaks_on(nth)
  members = [reader_raising_member(nth), SC.new(field: LATIN1_NAME, validations: {})]
  expects_axn({ members:, container: Hash }, type: Hash).input_schema
  "declared"
rescue ::Axn::DuplicateFieldError => e
  "DuplicateFieldError: #{e.message[0, 120]}"
rescue ::Exception => e
  "#{e.class}: #{e.message}"
end

# Checking the graph, bounding it and copying it are ONE walk of the caller's list, at declaration; every later
# walk is over axn's own copy. So a list that would answer a second walk differently never gets one, and the
# verdict is the ordinary one about the members it did give.
check "a list that misbehaves on a second walk never gets one", /DuplicateFieldError: Duplicate shape member declared/ do
  members = nth_walk_raiser(2, SC.new(field: UTF8_NAME, validations: {}), SC.new(field: LATIN1_NAME, validations: {}))
  expects_axn({ members:, container: Hash }, type: Hash).input_schema
  "declared"
rescue ::Exception => e
  "#{e.class}: #{e.message}"
end

# Measured, not asserted: the walk count itself, at two levels of nesting, through declaration and both
# projections.
check "the caller's list is walked exactly once per level", [1, 1] do
  inner = nth_walk_raiser(99, SC.new(field: :deep, validations: {}))
  outer = nth_walk_raiser(99, SC.new(field: :mid, validations: { type: { klass: Hash }, shape: { members: inner, container: Hash } }))
  klass = expects_axn({ members: outer, container: Hash }, type: Hash)
  klass.input_schema
  klass.output_schema
  [outer.instance_variable_get(:@walks), inner.instance_variable_get(:@walks)]
end

# The FIRST read is the one the declaration is not knowable without, so it is the only one taken: the collision
# between the name it gave and its sibling's is the verdict, and no second read can substitute an exception for
# it. Before the member snapshot, read 2 landed in the schema build (which raised NotImplementedError instead of
# reporting the collision) and read 3 in attribution (which degraded the message to the property alone).
check "a reader that would break on a later read is never read twice", [true, true, true] do
  [2, 3, 9].map { |nth| verdict_when_reader_breaks_on(nth).include?("both render as the JSON property") }
end

# ...and the report keeps its full source-naming form, because attribution re-traverses axn's own snapshot.
check "the report keeps its full form", /DuplicateFieldError: Duplicate shape member declared/ do
  verdict_when_reader_breaks_on(3)
end

# Mutating the members Array after declaring cannot introduce a collision at all now — the stored contract is a
# copy, so the second projection emits exactly what the first did.
check "a shape mutated after a projection cannot change what it emits", [%i[ok], %i[ok]] do
  members = [SC.new(field: :ok, validations: {})]
  klass = expects_axn({ members:, container: Hash }, type: Hash)
  first = klass.input_schema.dig(:properties, :payload, :properties).keys
  members << SC.new(field: UTF8_NAME, validations: {}) << SC.new(field: LATIN1_NAME, validations: {})
  [first, klass.input_schema.dig(:properties, :payload, :properties).keys]
end

check "an unmutated contract still projects repeatedly", [%i[ok], %i[ok], %i[ok]] do
  members = [SC.new(field: :ok, validations: {})]
  klass = expects_axn({ members:, container: Hash }, type: Hash)
  Array.new(3) { klass.input_schema.dig(:properties, :payload, :properties).keys }
end

check "inbound and outbound claim spaces stay separate", MERGED do
  merges_cleanly do
    expects utf8, optional: true
    exposes iso, optional: true
  end
end

# ---------------------------------------------------------------------------------------------------
puts "\n== the documented member contract: #field + #validations, nothing more =================="
# ---------------------------------------------------------------------------------------------------
#
# `shape_contracts_spec.rb` documents a shape member as duck-typed: `#field` and `#validations`. Declaration
# honors that; reflection did not, so a member the contract permits declared cleanly and then broke
# `input_schema`. Every attribute beyond the two is optional on the emission path.

# Exactly the documented contract, and nothing else.
CONTRACT_MEMBER = Class.new do
  def field = :ok
  def validations = {}
end

def reflects(which, &block)
  klass = Class.new do
    include Axn
    class_eval(&block)
    def call; end
  end
  props = klass.public_send(which)[:properties] || {}
  "reflected #{JSON.generate(props)[0, 80]}"
rescue ::Exception => e
  "#{e.class}: #{e.message.to_s[0, 70]}"
end

check "a documented-contract member reflects inbound", /\Areflected / do
  member = CONTRACT_MEMBER.new
  reflects(:input_schema) { expects :p, type: Hash, shape: { members: [member] } }
end

check "a documented-contract member reflects outbound", /\Areflected / do
  member = CONTRACT_MEMBER.new
  reflects(:output_schema) { exposes :p, type: Hash, shape: { members: [member] } }
end

check "a documented-contract member with a nested shape reflects", /\Areflected / do
  nested = { members: [SC.new(field: :deep, validations: {})], container: Hash }
  member = Class.new do
    define_method(:field) { :ok }
    define_method(:validations) { { type: { klass: Hash }, shape: nested } }
  end.new
  reflects(:input_schema) { expects :p, type: Hash, shape: { members: [member] } }
end

check "a member that DOES define description still emits it", /"description":"hi"/ do
  member = Class.new do
    def field = :ok
    def validations = {}
    def description = "hi"
  end.new
  reflects(:input_schema) { expects :p, type: Hash, shape: { members: [member] } }
end

# What a member may CARRY, as opposed to what it must answer to. `sensitive:` and `user_facing:` are rules the
# runtime resolves, so a value outside their grammar is not a rule at all — a `sensitive: "yes"` silently drops
# the member from the redaction set and logs the value in the clear. Held by the declaration walk, over every
# member whatever its class, at the point it reads the value into the snapshot — which is what makes the check and
# the stored value one read. A ShapeConfig constructor is not evidence on its own: a member arriving as a `Data`
# of the caller's own, or as a `Data#with` copy on a Ruby where `with` skips a custom `initialize`, ran no such
# constructor, and both stored an unchecked rule before the walk read them.
def member_grammar_verdict(member)
  klass = expects_axn({ members: [member], container: Hash }, type: Hash)
  "declared: sensitive_fields=#{klass.sensitive_fields.inspect} " \
    "logged=#{klass.send(:_context_slice, data: { payload: { ssn: 'SHH' } }, direction: :inbound).inspect}"
rescue ::Exception => e
  "#{e.class}: #{e.message[0, 70]}"
end

check "a duck-typed member's sensitive: is held to the grammar", /ArgumentError: sensitive: must be true, false/ do
  member_grammar_verdict(Struct.new(:field, :validations, :sensitive).new(:ssn, {}, "yes"))
end

check "a member of the caller's own Data class is too", /ArgumentError: sensitive: must be true, false/ do
  member_grammar_verdict(Data.define(:field, :validations, :sensitive).new(field: :ssn, validations: {}, sensitive: "yes"))
end

check "and a ShapeConfig copy, on every Ruby", /ArgumentError: sensitive: must be true, false/ do
  member_grammar_verdict(SC.new(field: :ssn, validations: {}, sensitive: true).with(sensitive: "yes"))
end

check "a raw member's user_facing: is held to its grammar at declaration", /ArgumentError: user_facing: must be true/ do
  member_grammar_verdict(Struct.new(:field, :validations, :user_facing).new(:ssn, { type: { klass: String } }, 123))
end

# The tolerance runs one way: a member carrying no such reader at all declares cleanly (the documented duck-typed
# contract is `#field` + `#validations`), and one carrying a value the grammar allows still redacts.
check "a member with neither reader still declares", /declared: sensitive_fields=\[\]/ do
  member_grammar_verdict(Struct.new(:field, :validations).new(:ssn, {}))
end

check "a copy carrying a value the grammar allows still redacts", /logged=.*FILTERED/ do
  member_grammar_verdict(SC.new(field: :ssn, validations: {}, sensitive: false).with(sensitive: true))
end

# ---------------------------------------------------------------------------------------------------
puts "\n== false positives: must keep declaring cleanly ========================================"
# ---------------------------------------------------------------------------------------------------

# THE control. A model: field and an explicitly-declared `<field>_id` in the SAME spelling is a supported
# pattern: schema reflection merges them (`properties[id_field] ||= id_prop`) and emits ONE property. It
# must keep declaring and keep emitting one — a guard that added generated ids to the claimed set wholesale
# would reject this.
check "model: plus an explicit same-spelling _id still declares, one property", [:café_id] do
  utf8 = UTF8_NAME
  input_props do
    expects utf8, model: HarnessWidget, optional: true
    expects :café_id, optional: true
  end.keys
end

# Two ROUTES to one wire path is legitimate — a merged node, gated on reader-name uniqueness instead.
check "one leaf reached by a dotted route and a reader route still declares", %i[billing zip_a zip_b] do
  klass = Class.new do
    include Axn
    expects :address, type: Hash
    expects :billing, on: :address, type: Hash
    expects :zip, on: "address.billing", as: :zip_a, optional: true
    expects :zip, on: :billing, as: :zip_b, optional: true
    def call; end
  end
  klass.subfield_configs.map(&:reader_as)
end

# Two DISTINCT nested fields that happen to share a leaf key under different parents stay distinct.
check "one leaf key under two different parents still declares", %i[from_zip to_zip] do
  klass = Class.new do
    include Axn
    expects :from, type: Hash
    expects :to, type: Hash
    expects :zip, on: :from, as: :from_zip, optional: true
    expects :zip, on: :to, as: :to_zip, optional: true
    def call; end
  end
  klass.subfield_configs.map(&:reader_as)
end


check "an ordinary shape block", %i[a b] do
  klass = Class.new do
    include Axn
    expects :payload, type: Hash do
      field :a, type: String
      field :b, type: Integer
    end
    def call; end
  end
  klass.input_schema.dig(:properties, :payload, :properties).keys
end

check "diamond: one nested shape reused by two sibling members", %i[a b] do
  nested = { members: [SC.new(field: :leaf, validations: {})], container: Hash }
  members = [SC.new(field: :a, validations: { shape: nested }), SC.new(field: :b, validations: { shape: nested })]
  props = expects_axn({ members:, container: Hash }, type: Hash).input_schema.dig(:properties, :payload, :properties)
  raise "nested members lost" unless props.dig(:a, :properties)&.keys == [:leaf] && props.dig(:b, :properties)&.keys == [:leaf]

  props.keys
end

check "one ShapeConfig object reused under two sibling blocks", %i[from to] do
  reused = SC.new(field: :zip, validations: {})
  nested = { members: [reused], container: Hash }
  members = [SC.new(field: :from, validations: { shape: nested }), SC.new(field: :to, validations: { shape: nested })]
  expects_axn({ members:, container: Hash }, type: Hash).input_schema.dig(:properties, :payload, :properties).keys
end

check "Object.new as a member: rejected, not skipped", /ArgumentError: a shape member must answer to `field`/ do
  nameless_member_verdict(Object.new)
end

check "honest linear nesting one level inside the cap", "declared" do
  expects_axn(linear_nested_shape(63), type: Hash) && "declared"
end

check "one level past the cap is rejected", /ArgumentError.*nested more than 64 levels deep/ do
  declare_and_reflect(linear_nested_shape(65), type: Hash)
end

# The cap over a graph whose depth is assembled out of SHARED tails, each first reached shallow. Depth belongs
# to a shape's position, not to the shape, so a walk that remembers shapes it has verified has to re-judge a
# reused subtree by its height: every tail here is a sibling of the root one level down before the next chain
# nests it one level lower, so no walk descends past two while the stored graph is `chains` levels deep. At the
# cap it must still declare AND project; past it, declaration is the only honest place to say so — the
# projection has no walk of the stored graph, and redaction's fail-safe past the bound masks a value with no
# `sensitive:` anywhere in the contract.
def shared_tail_shape(chains)
  shapes = [{ members: [SC.new(field: :leaf, validations: {})], container: Hash }]
  (chains - 1).times { |i| shapes << { members: [SC.new(field: :"n#{i}", validations: { shape: shapes[i] })], container: Hash } }
  members = shapes.each_with_index.map { |shape, i| SC.new(field: :"m#{i}", validations: { shape: }) }
  { members:, container: Hash }
end

check "shared tails reaching the cap declare and project", "declared and projected" do
  expects_axn(shared_tail_shape(64), type: Hash).input_schema && "declared and projected"
end

# Declaration ONLY, deliberately: what this row is about is WHICH layer says no, and the two layers say it in
# different words — the declaration walk's "nested more than 64 levels deep" against `ShapeGraph`'s "nests more
# than", which every re-walk of an already-held graph reports. Reflecting here would satisfy the row either way.
check "shared tails past the cap are rejected at declaration", /ArgumentError.*nested more than 64 levels deep/ do
  expects_axn(shared_tail_shape(71), type: Hash) && "declared"
end

# The other half of the same row, and the user-visible one: past the depth bound `_shape_has_sensitive_member?`
# answers TRUE (nothing can enumerate a graph that mints its members on demand, so the value is masked wholesale
# rather than logged in the clear), which is only ever an answer about an UNDECLARABLE graph. A contract with no
# `sensitive:` in it logs its values.
check "a shape at the cap with no sensitive: logs in the clear", { m63: { n62: "visible" } } do
  klass = expects_axn(shared_tail_shape(64), type: Hash)
  klass.send(:new, payload: { m63: { n62: "visible" } }).send(:inputs_for_logging)[:payload]
end

check "a declared shape still validates its members at runtime", false do
  expects_axn({ members: [SC.new(field: :a, validations: { presence: true })], container: Hash }, type: Hash).call(payload: {}).ok?
end

# A String member name and a Symbol one are the same property and must both keep working — normalizing the
# stored name must not change which property is emitted, nor how many.
check "a String member name still declares and emits one property", [:stringy] do
  klass = Class.new do
    include Axn
    expects :payload, type: Hash do
      field "stringy", type: String
    end
    def call; end
  end
  klass.input_schema.dig(:properties, :payload, :properties).keys
end

check "a Symbol member name still declares and emits one property", [:stringy] do
  klass = Class.new do
    include Axn
    expects :payload, type: Hash do
      field :stringy, type: String
    end
    def call; end
  end
  klass.input_schema.dig(:properties, :payload, :properties).keys
end

check "a String member name is stored as a Symbol, as a top-level field's is", [Symbol, :stringy] do
  member = SC.new(field: "stringy", validations: {})
  [member.field.class, member.field]
end

check "a raw String member name still emits one property", [:stringy] do
  props = expects_axn({ members: [SC.new(field: "stringy", validations: {})], container: Hash }, type: Hash)
          .input_schema.dig(:properties, :payload, :properties)
  props.keys
end

check "a String and a Symbol spelling of one member name still collide", /DuplicateFieldError: Duplicate shape member declared: :a/ do
  project do
  expects :payload, type: Hash do
    field :a, type: String
    field "a", type: Integer
  end
  end
end

# ---------------------------------------------------------------------------------------------------
puts "\n== the invariant: rejected exactly when the emitted schema collapses ===================="
# ---------------------------------------------------------------------------------------------------
#
# The guard reads the property names reflection emits, so "rejected" and "the schema collapses" are the same
# fact rather than two that must be kept in agreement. This row asserts that equivalence over a battery of
# contracts — including the ones whose PREDICTED and EMITTED property sets diverged (a nested-gated `type:`
# that `build_property` strips, a subtree the tree drops beneath a `model:` ancestor). Those cases needed no
# fix; there is no predictor left to disagree.
GATED_DATA = Data.define(:café)

class INV_WIDGET
  def self.name = "Widget"
  def self.find(_id) = new
end

INVARIANT_CONTRACTS = {
  "plain colliding members" => proc { expects(:p, type: Hash) { field UTF8_NAME, type: String; field LATIN1_NAME, type: Integer } },
  "nested-gated type: on exposes" => proc {
    exposes :thing, type: { klass: GATED_DATA, if: -> { true } },
            shape: { members: [SC.new(field: LATIN1_NAME, validations: {})], container: Hash }
  },
  "dropped subtree beneath model:" => proc {
    expects :rec, model: INV_WIDGET, optional: true
    expects :mid, on: :rec, type: Hash, optional: true, method_call: true
    expects UTF8_NAME, on: "rec.mid", optional: true
    expects LATIN1_NAME, on: :mid, optional: true
  },
  "custom as_json on exposes" => proc {
    exposes(:thing, type: CUSTOM_AS_JSON_DATA) { field LATIN1_NAME, type: String }
  },
  "scalar of: with colliding members" => proc {
    expects :list, type: Array, of: String,
            shape: { members: [SC.new(field: UTF8_NAME, validations: {}), SC.new(field: LATIN1_NAME, validations: {})], container: Array }
  },
  "of: Data element vs member" => proc {
    expects :list, type: Array, of: CAFE_DATA,
            shape: { members: [SC.new(field: LATIN1_NAME, validations: { type: String })], container: Array }
  },
  "subfield vs shape member" => proc {
    expects(:payload, type: Hash) { field UTF8_NAME, type: String }
    expects LATIN1_NAME, on: :payload, optional: true
  },
  "legal merge: member + same-named subfield" => proc {
    expects(:payload, type: Hash) { field UTF8_NAME, type: String }
    expects UTF8_NAME, on: :payload, optional: true
  },
}

check "rejected exactly when the emitted schema would collapse", [] do
  INVARIANT_CONTRACTS.filter_map do |label, decl|
    rejected = false
    collapses = begin
      klass = Class.new do
        include Axn
        class_eval(&decl)
        def call; end
      end
      collapsed_nodes(klass.input_schema[:properties]) + collapsed_nodes(klass.output_schema[:properties])
    rescue ::Axn::DuplicateFieldError
      rejected = true
      []
    end
    # A violation is either shape: rejected with nothing to reject, or accepted with a collapse emitted.
    label unless rejected == !collapses.empty? || (rejected && collapses.empty?)
  end
end

check "and every accepted contract above emits no collapse", [] do
  INVARIANT_CONTRACTS.filter_map do |label, decl|
    collapses = begin
      klass = Class.new do
        include Axn
        class_eval(&decl)
        def call; end
      end
      collapsed_nodes(klass.input_schema[:properties]) + collapsed_nodes(klass.output_schema[:properties])
    rescue ::Axn::DuplicateFieldError
      next
    end
    label unless collapses.empty?
  end
end

# ---------------------------------------------------------------------------------------------------
puts "\n== cost: an honest shape must not hang at class definition =============================="
# ---------------------------------------------------------------------------------------------------

# Sharing a nested shape between SIBLING members multiplies the distinct property paths beneath it: N levels
# of two-way sharing name 2^N properties. Shallow sharing — what anyone actually writes — stays cheap and
# legal. Deep sharing is rejected, because such a contract has no reflectable schema either: `input_schema`
# walks the same paths (measured: 786k nodes and 2.7s at eighteen levels), so declaring it and hanging on the
# first reflection is the worse of the two outcomes.
[6, 10].each do |depth|
  check "shared sub-shape reused by siblings, #{depth} deep, declares fast", true do
    raw = shared_diamond_shape(depth)
    elapsed = Benchmark.realtime { expects_axn(raw, type: Hash) }
    puts format("       (%.3fs)", elapsed)
    elapsed < 1.0
  end
end

# The two shapes that stress the walk in opposite directions, since a bound re-judged at every REFERENCE has to
# be answerable from what the memo already carries rather than by walking again. Deep and unshared: one walk per
# level, and the cap is the most levels there can be. Shallow and heavily shared: thirteen levels of two-way
# sharing is the deepest the path bound admits (24,574 paths), and remembering its 14 distinct shapes is what
# keeps 27 references from expanding into 16,382 walks (measured: 0.002s memoized, 0.216s not, growing as 2^N).
check "a linear chain at the cap declares fast", true do
  raw = linear_nested_shape(64)
  elapsed = Benchmark.realtime { expects_axn(raw, type: Hash) }
  puts format("       (%.3fs)", elapsed)
  elapsed < 1.0
end

check "the most heavily shared DAG the path bound admits declares fast", true do
  raw = shared_diamond_shape(13)
  elapsed = Benchmark.realtime { expects_axn(raw, type: Hash) }
  puts format("       (%.3fs)", elapsed)
  elapsed < 1.0
end

# The two bounds are DIFFERENT limits: one on the stored graph (paths, at declaration, because the walks that
# read a contract per logged call pay a step per path), one on what a schema EMITS (at projection, derived from
# the emitter's own plan). Conflating them over-rejected a contract whose schema names nothing.
check "a scalar of: shape emits nothing, so it costs nothing", '{type: "array", items: {type: "string"}}' do
  members = Array.new(1_000) { |i| SC.new(field: :"m#{i}", validations: {}) }
  klass = Class.new do
    include Axn
    expects :items, type: Array, of: String, shape: { members: members, container: Array }
    def call; end
  end
  prop = klass.input_schema.dig(:properties, :items)
  "{type: #{prop[:type].inspect}, items: {type: #{prop.dig(:items, :type).inspect}}}"
end

check "...even 26 fields of them, past the emitted bound in total", "declared and projected" do
  members = Array.new(1_000) { |i| SC.new(field: :"m#{i}", validations: {}) }
  klass = Class.new do
    include Axn
    26.times { |f| expects :"f#{f}", type: Array, of: String, shape: { members: members, container: Array } }
    def call; end
  end
  klass.input_schema && "declared and projected"
rescue ::Exception => e
  "#{e.class}: #{e.message[0, 50]}"
end

check "the same width of EMITTING members is still capped", /names more than 25000 JSON properties/ do
  members = Array.new(1_000) { |i| SC.new(field: :"m#{i}", validations: {}) }
  klass = Class.new do
    include Axn
    26.times { |f| expects :"f#{f}", type: Hash, shape: { members: members, container: Hash } }
    def call; end
  end
  begin
    klass.input_schema && "projected"
  rescue ::Exception => e
    "#{e.class}: #{e.message}"
  end
end

# The `of:` element type's own members DO reach `items`, so they are still counted — the earlier of: finding
# proved they reach the schema.
check "an of: element type's own members are still counted", /names more than 25000 JSON properties/ do
  wide = Data.define(*Array.new(26_000) { |i| :"m#{i}" })
  klass = Class.new do
    include Axn
    expects :items, type: Array, of: wide
    def call; end
  end
  begin
    klass.input_schema && "projected"
  rescue ::Exception => e
    "#{e.class}: #{e.message}"
  end
end

# ...and they reach it through as many `anyOf` BRANCHES as the `of:` has element types, each branch carrying
# its own `properties`. A charge that read the node's own `properties` counted none of those, so 26 classes of
# 1,000 members — 26,000 emitted properties — declared and projected straight past the cap.
check "an of: with MANY element types counts every branch", /names more than 25000 JSON properties/ do
  wides = Array.new(26) { |b| Data.define(*Array.new(1_000) { |i| :"b#{b}m#{i}" }) }
  klass = Class.new do
    include Axn
    expects :items, type: Array, of: wides, optional: true
    def call; end
  end
  begin
    klass.input_schema && "projected"
  rescue ::Exception => e
    "#{e.class}: #{e.message}"
  end
end

# Whether a config emits ANY property is the same question one level up, and SubfieldTree owns the answer, so
# the charge asks it rather than assuming every declaration names something. Each of these was charged one
# property per config plus every member/type name under it, and rejected a contract whose schema names them
# nowhere at all.
def projected_input(&block)
  klass = Class.new do
    include Axn
    class_eval(&block)
    def call; end
  end
  JSON.generate(klass.input_schema)
rescue ::Exception => e # rubocop:disable Lint/RescueException
  "#{e.class}: #{e.message[0, 60]}"
end

WIDE_TYPE = Data.define(*Array.new(26_000) { |i| :"m#{i}" })

check "an ambient-rooted config costs nothing and emits nothing", '{"type":"object","properties":{}}' do
  projected_input { expects :items, on: :ambient_context, type: Array, of: WIDE_TYPE, optional: true }
end

check "...and neither does an ambient-rooted shape", '{"type":"object","properties":{}}' do
  members = Array.new(1_000) { |i| SC.new(field: :"m#{i}", validations: {}) }
  projected_input do
    26.times { |f| expects :"f#{f}", on: :ambient_context, type: Hash, shape: { members: members, container: Hash }, optional: true }
  end
end

# A subfield under a parent that cannot hold object properties is omitted at that parent, with its whole
# subtree — at ANY depth. `dropped` records only the deep ones it reports to the author, so the charge asks the
# blocking predicate instead.
check "a dropped DEEP subfield costs nothing", /\A\{"type":"object","properties":\{"payload"/ do
  projected_input do
    expects :payload, type: Hash do
      field :bar, type: [Hash, Array]
    end
    expects :baz, on: "payload.bar", type: Array, of: WIDE_TYPE, optional: true
  end
end

check "a depth-1 subfield under a model: parent costs nothing", /\A\{"type":"object","properties":\{"thing_id"/ do
  projected_input do
    expects :thing, model: Struct.new(:id), optional: true
    expects :leaf, on: :thing, type: Array, of: WIDE_TYPE, optional: true
  end
end

# An INPUT model route emits `<field>_id` INSTEAD of the field, so its own declared type names nothing either.
check "a model: route's own type costs nothing on input", /\A\{"type":"object","properties":\{"thing_id"/ do
  projected_input { expects :thing, model: Struct.new(:id), type: Array, of: WIDE_TYPE, optional: true }
end

# ...and the control in the other direction: OUTPUT emits the field itself, so the same type is charged.
check "a model: route's type is still charged on output", /names more than 25000 JSON properties/ do
  klass = Class.new do
    include Axn
    exposes :thing, model: Struct.new(:id), type: Array, of: WIDE_TYPE, optional: true
    def call; end
  end
  begin
    klass.output_schema && "projected"
  rescue ::Exception => e
    "#{e.class}: #{e.message}"
  end
end

# WHICH CONFIG the emitter builds a property from is the other half of "ask the emitter", and reading its plan is
# exact only when the plan is given the config the emitter uses. On OUTPUT it is not the declared one:
# `build_property` first drops every validator entry a per-validator (nested) gate could skip, because a gated
# constraint cannot be promised outbound, and derives the plan from THAT. So a gated `type:`/`of:`/`shape:` names
# no property, and charging its members rejected a contract whose schema names none of them. The reduction now
# lives inside `shape_property_plan` itself (`Schema.effective_validations`), so nothing can ask for a plan from
# a config the emitter would have reduced first.
def projected_output(&block)
  klass = Class.new do
    include Axn
    class_eval(&block)
    def call; end
  end
  JSON.generate(klass.output_schema)
rescue ::Exception => e # rubocop:disable Lint/RescueException
  "#{e.class}: #{e.message[0, 60]}"
end

GATED_SHAPE = { members: [SC.new(field: :keep, validations: {})], container: Hash }.freeze

check "a per-validator-gated type: costs nothing on output", '{"type":"object","properties":{"x":{"type":["object","null"],"properties":{"keep":{}}}},"required":["x"]}' do
  projected_output { exposes :x, optional: true, shape: GATED_SHAPE, type: { klass: WIDE_TYPE, if: :flag } }
end

check "...while the UNGATED type of the same width is still charged", /names more than 25000 JSON properties/ do
  projected_output { exposes :x, optional: true, shape: GATED_SHAPE, type: { klass: WIDE_TYPE } }
end

# INPUT is static-maximal — a gate can only relax enforcement at runtime, so the schema still advertises the
# type — which is why the same declaration is still charged inbound, where those members really are emitted.
check "...and the gated type is still charged on INPUT, where it is emitted", /names more than 25000 JSON properties/ do
  projected_input { expects :x, optional: true, shape: GATED_SHAPE, type: { klass: WIDE_TYPE, if: :flag } }
end

check "a gated of: costs nothing on output", '{"type":"object","properties":{"items":{"type":["array","null"]}},"required":["items"]}' do
  projected_output { exposes :items, optional: true, type: Array, of: { klass: WIDE_TYPE, if: :flag } }
end

# A gated `type:` can also move WHERE members land: with the array type gated off the value is no longer an
# array, so `items` is never emitted and the `of:` element type names nothing at all.
check "an of: whose array type is gated off costs nothing", '{"type":"object","properties":{"items":{}},"required":["items"]}' do
  projected_output { exposes :items, optional: true, type: { klass: Array, if: :flag }, of: WIDE_TYPE }
end

# The `shape:` entry is gated the same way (it is an entry of the same validations Hash), and two fields sharing
# one 13,000-member shape is past the emitted bound in total while each graph stays well inside the graph bound.
check "a gated shape: costs nothing on output", '{"type":"object","properties":{"x":{"type":["object","null"]},"y":{"type":["object","null"]}},"required":["x","y"]}' do
  members = Array.new(13_000) { |i| SC.new(field: :"m#{i}", validations: {}) }
  raw = { members: members, container: Hash, if: :flag }
  projected_output do
    exposes :x, optional: true, type: Hash, shape: raw
    exposes :y, optional: true, type: Hash, shape: raw
  end
end

check "...while the same two shapes UNGATED are still charged", /names more than 25000 JSON properties/ do
  members = Array.new(13_000) { |i| SC.new(field: :"m#{i}", validations: {}) }
  raw = { members: members, container: Hash }
  projected_output do
    exposes :x, optional: true, type: Hash, shape: raw
    exposes :y, optional: true, type: Hash, shape: raw
  end
end

# The case where reading the PLAN's shape (rather than the config's) is the whole of it: a gated `shape:` beside
# an ungated object `of:` leaves the plan EMITTED — the element type is an object, so an overlay would have
# applied — while the shape it was derived from is gone. Charging the config's own members here charges an
# overlay `apply_structured_schema!` never merges.
def gated_overlay(raw_extra)
  members = Array.new(13_000) { |i| SC.new(field: :"m#{i}", validations: {}) }
  raw = { members: members, container: Array }.merge(raw_extra)
  projected_output do
    exposes :x, optional: true, type: Array, of: Hash, shape: raw
    exposes :y, optional: true, type: Array, of: Hash, shape: raw
  end
end

check "a gated shape: beside an ungated of: overlays nothing, and costs nothing", /"x":\{"type":\["array","null"\],"items":\{"type":"object"\}\}/ do
  gated_overlay(if: :flag)
end

check "...while the same overlay UNGATED is still charged", /names more than 25000 JSON properties/ do
  gated_overlay({})
end

# A shape MEMBER is emitted through the same `build_property`, so its own gated type is reduced the same way —
# and the charge recurses through members, so this is the same defect one level down.
check "a gated type on a shape MEMBER costs nothing", /"m":\{"type":"object","properties":\{"keep":\{\}\}\}/ do
  inner = SC.new(field: :m, validations: { type: { klass: WIDE_TYPE, if: :flag }, shape: GATED_SHAPE })
  raw = { members: [inner], container: Hash }
  projected_output { exposes :payload, optional: true, type: Hash, shape: raw }
end

# A wire path declared by TWO routes is one merged node, and the emitter builds its object property from ONE of
# them (`Schema.property_representative`). The other route is enforced at runtime but its `of:`/`shape:` is never
# emitted, so charging it rejected a contract over a schema that does not carry it.
def merged_routes(first_of, second_of)
  projected_input do
    expects :a, type: Hash, optional: true
    expects :b, on: :a, as: :bb, type: Hash, optional: true
    expects :c, on: "a.b", optional: true, type: Array, of: first_of
    expects :c, as: :c2, on: :bb, optional: true, type: Array, of: second_of
  end
end

check "a second route's of: costs nothing, since the property is built from the first", /"c":.*"items":\{"type":"object","properties":\{"sm1":\{\}\}\}/ do
  merged_routes(Data.define(:sm1), WIDE_TYPE)
end

# `projected_input` truncates the message it reports, so the row matches the part that survives.
check "...while the route the property IS built from is still charged", /names more than 25000 JSON/ do
  merged_routes(WIDE_TYPE, Data.define(:sm1))
end

# The two input cases reachable only by ASSIGNING configs onto a class — this file's own subject, and where a
# config carries whatever its author built. `build_input` writes one property per WIRE KEY, so a later config
# sharing one overwrites the earlier property; and a field named in `EXCLUDED_FROM_INPUT_SCHEMA` is skipped
# outright (only an assigned config can carry that name — `ambient_context` is reserved).
def assigned_input(*validations_list)
  klass = Class.new do
    include Axn
    expects :other, optional: true
    def call; end
  end
  configs = validations_list.each_with_index.map do |validations, i|
    Axn::Core::Contract::FieldConfig.new(field: :x, reader_as: :"x#{i}", validations: validations)
  end
  klass.internal_field_configs = (klass.internal_field_configs + configs).freeze
  JSON.generate(klass.input_schema)
rescue ::Exception => e # rubocop:disable Lint/RescueException
  "#{e.class}: #{e.message[0, 60]}"
end

check "an overwritten top-level property costs nothing", /"x":\{"type":"array","items":\{"type":"object","properties":\{"sm1":\{\}\}\}\}/ do
  assigned_input({ type: Array, of: { klass: WIDE_TYPE }, optional: true }, { type: Array, of: { klass: Data.define(:sm1) }, optional: true })
end

check "...while the write that survives is still charged", /names more than 25000 JSON/ do
  assigned_input({ type: Array, of: { klass: Data.define(:sm1) }, optional: true }, { type: Array, of: { klass: WIDE_TYPE }, optional: true })
end

check "a field the input schema excludes by name costs nothing", '{"type":"object","properties":{"other":{}}}' do
  klass = Class.new do
    include Axn
    expects :other, optional: true
    def call; end
  end
  excluded = Axn::Core::Contract::FieldConfig.new(field: :ambient_context, reader_as: :ambient_context,
                                                 validations: { type: Array, of: { klass: WIDE_TYPE }, optional: true })
  klass.internal_field_configs = (klass.internal_field_configs + [excluded]).freeze
  JSON.generate(klass.input_schema)
rescue ::Exception => e # rubocop:disable Lint/RescueException
  "#{e.class}: #{e.message[0, 60]}"
end

# RECORDED RESIDUE, not a guarantee — and the reason it stays one. The size trie is IDENTITY-keyed, because a
# count may not ask a name its own `hash`/`eql?`; the emitter's `properties[config.field] =` is a plain Hash, so
# two byte-equal Strings are ONE property there and two trie nodes here. A contract naming exactly one property is
# therefore rejected for naming 25,001 — an OVER-count, the direction that rejects a legal declaration.
#
# It needs BOTH halves to bite, and neither is reachable by declaring anything: String field names (the DSL
# symbolizes every declared name and dotted route, and two byte-equal declared names are a declared duplicate, so
# only a config ASSIGNED onto a class carries one) AND a contract already at the cap, since the over-count is one
# per duplicate. Below the cap the schema is identical either way, which is why the row asserts the verdict rather
# than a projection: nothing else can see the difference.
check "25,001 byte-equal assigned String names are charged as 25,001 properties", /names more than 25000 JSON/ do
  klass = Class.new do
    include Axn
    def call; end
  end
  configs = Array.new(25_001) do |i|
    Axn::Core::Contract::FieldConfig.new(field: "dup".dup, reader_as: :"x#{i}", validations: { allow_nil: true })
  end
  klass.internal_field_configs = configs.freeze
  begin
    JSON.generate(klass.input_schema)
  rescue ::Exception => e # rubocop:disable Lint/RescueException
    "#{e.class}: #{e.message[0, 60]}"
  end
end

# The control that keeps the residue narrow: the same names DECLARED are one property, and cannot be repeated.
check "the same name declared twice is a declared duplicate", /DuplicateFieldError/ do
  Class.new do
    include Axn
    expects "dup", optional: true
    expects "dup".dup, optional: true
    def call; end
  end
  "declared"
rescue ::Exception => e # rubocop:disable Lint/RescueException
  "#{e.class}: #{e.message[0, 40]}"
end

# Branches are sibling NAMESPACES, so counting them for size must not make a name shared by two of them a
# collision: `of: [A, B]` where both define `:shared` describes one property two ways.
check "two of: branches may share a member name", '[[:shared, :only_a], [:shared, :only_b]]' do
  a = Data.define(:shared, :only_a)
  b = Data.define(:shared, :only_b)
  klass = Class.new do
    include Axn
    expects :items, type: Array, of: [a, b], optional: true
    def call; end
  end
  klass.input_schema.dig(:properties, :items, :items, :anyOf).map { |branch| branch[:properties].keys }.inspect
end

# The graph bound, in its own vocabulary: flat (per-member charge) and shared (subtree charge).
check "one flat shape past the path bound is rejected at declaration", /ArgumentError.*has more than 25000 member paths/ do
  members = Array.new(25_001) { |i| SC.new(field: :"m#{i}", validations: {}) }
  begin
    Class.new do
      include Axn
      expects :payload, type: Hash, shape: { members: members, container: Hash }
      def call; end
    end
    "declared"
  rescue ::Exception => e
    "#{e.class}: #{e.message}"
  end
end

check "shared sub-shape 18 deep is rejected, not left to hang on reflection", /ArgumentError.*has more than 25000 member paths/ do
  raw = shared_diamond_shape(18)
  project { expects :payload, type: Hash, shape: raw }
end

check "the rejection itself is fast", true do
  raw = shared_diamond_shape(22)
  elapsed = Benchmark.realtime do
    project { expects :payload, type: Hash, shape: raw }
  rescue ::ArgumentError
    nil
  end
  puts format("       (%.3fs)", elapsed)
  elapsed < 1.0
end

# The check rebuilds the prospective schema per `expects` CALL, so cost tracks calls rather than fields — a
# contract declared the way contracts are written (a handful of calls, several fields each) stays in
# single-digit milliseconds.
check "20 fields over 4 calls declares in under 10ms", true do
  elapsed = Benchmark.realtime do
    Class.new do
      include Axn
      4.times do |c|
        names = Array.new(5) { |i| :"f#{c}_#{i}" }
        members = Array.new(5) { |j| SC.new(field: :"m#{j}", validations: {}) }
        expects(*names, type: Hash, shape: { members:, container: Hash }, optional: true)
      end
      def call; end
    end
  end
  puts format("       (%.3fs)", elapsed)
  elapsed < 0.010
end

check "100 fields over 10 calls declares in under 100ms", true do
  elapsed = Benchmark.realtime do
    Class.new do
      include Axn
      10.times do |c|
        names = Array.new(10) { |i| :"f#{c}_#{i}" }
        members = Array.new(10) { |j| SC.new(field: :"m#{j}", validations: {}) }
        expects(*names, type: Hash, shape: { members:, container: Hash }, optional: true)
      end
      def call; end
    end
  end
  puts format("       (%.3fs)", elapsed)
  elapsed < 0.100
end

# The pathological end of the same axis: one `expects` per field. Recorded rather than optimized.
check "100 fields over 100 separate calls declares in under 1s", true do
  elapsed = Benchmark.realtime do
    Class.new do
      include Axn
      100.times do |i|
        members = Array.new(10) { |j| SC.new(field: :"m#{j}", validations: {}) }
        expects :"f#{i}", type: Hash, shape: { members:, container: Hash }, optional: true
      end
      def call; end
    end
  end
  puts format("       (%.3fs)", elapsed)
  elapsed < 1.0
end

# ---------------------------------------------------------------------------------------------------
puts "\n== cost: a logged call must not pay for the whole stored graph =========================="
# ---------------------------------------------------------------------------------------------------

# Redaction reads the stored shape graph to decide what to mask. Everything it can decide from the
# DECLARATION is decided once per contract, because a stored graph is a declaration-time snapshot — so the
# per-call cost is independent of the graph's size. It used to be linear in it, and worst for a contract with
# no `sensitive:` at all: concluding "nothing to redact" is what requires visiting every member.
def redaction_cost(members)
  klass = Class.new do
    include Axn
    expects :flag, type: :boolean, optional: true
    expects :payload, type: Hash, shape: { members:, container: Hash }, optional: true
    def call; end
  end
  instance = klass.send(:new, flag: true)
  data = { payload: { m0: "secret", m1: "other" } }
  3.times { klass._context_slice(data:, direction: :inbound, action_instance: instance) }
  t = Benchmark.realtime { 10.times { klass._context_slice(data:, direction: :inbound, action_instance: instance) } }
  t / 10
end

{ "no sensitive: anywhere" => nil, "one static sensitive member" => true }.each do |label, sensitive|
  check "24k members, #{label}: under 1ms per logged call", true do
    elapsed = redaction_cost(Array.new(24_000) { |i| SC.new(field: :"m#{i}", validations: {}, sensitive: i.zero? && !sensitive.nil?) })
    puts format("       (%.4fs)", elapsed)
    elapsed < 0.001
  end
end

# A dynamic `sensitive:` is the one case that cannot be decided once — it resolves against the action — so it
# still walks per call. RECORDED rather than fixed: the alternative is a memo that ignores the instance, which
# would over-redact a `sensitive: :flag` whose flag is false.
check "24k members, dynamic sensitive: still walks per call", true do
  elapsed = redaction_cost(Array.new(24_000) { |i| SC.new(field: :"m#{i}", validations: {}, sensitive: i.zero? ? :flag : false) })
  puts format("       (%.4fs)", elapsed)
  elapsed > 0.001
end

# ---------------------------------------------------------------------------------------------------
puts "\n== a raw shape must supply members: (absent/nil vs explicitly empty) ===================="
# ---------------------------------------------------------------------------------------------------

# A shape describes what is inside a container, so one naming no members list is malformed. It used to fail on
# the first CALL (ShapeValidator refuses a nil members list); capturing an absent list as `[]` in the snapshot
# erased the distinction that guard depends on, so it became silently inert. Rejected at declaration now —
# strictly earlier than the behaviour that regressed.
def raw_shape_verdict(shape)
  klass = Class.new do
    include Axn
    expects :payload, type: Hash, shape: shape
    def call; end
  end
  r = klass.call(payload: { anything: 1 })
  "declared; call ok=#{r.ok?}#{r.ok? ? '' : " (#{r.exception&.class})"}"
rescue ::Exception => e
  "#{e.class}: #{e.message[0, 45]}"
end

check "an absent members: list is rejected at declaration", /ArgumentError: a raw `shape:` must supply `members:`/ do
  raw_shape_verdict({ container: Hash })
end

check "an explicit `members: nil` is rejected on the same terms", /ArgumentError: a raw `shape:` must supply `members:`/ do
  raw_shape_verdict({ members: nil, container: Hash })
end

check "a malformed NESTED shape names the member carrying it", /ArgumentError: a raw `shape:` at shape member `a` must/ do
  raw_shape_verdict({ members: [SC.new(field: :a, validations: { type: { klass: Hash }, shape: { container: Hash } })], container: Hash })
end

# The control: an explicitly empty list is a real (if pointless) declaration — legal at every commit on this
# branch, and still legal. Only the container type constrains the value.
check "an explicitly empty members: list stays legal", "declared; call ok=true" do
  raw_shape_verdict({ members: [], container: Hash })
end

check "...and the declared type still constrains the value", "declared; call ok=false (Axn::InboundValidationError)" do
  klass = Class.new do
    include Axn
    expects :payload, type: Hash, shape: { members: [], container: Hash }
    def call; end
  end
  r = klass.call(payload: "not a hash")
  "declared; call ok=#{r.ok?}#{r.ok? ? '' : " (#{r.exception&.class})"}"
end

# The other half of the documented member contract, found by the same sweep: runtime validation dispatches
# `member.validations` directly, so a member answering to `field` only died on the first call.
check "a member answering to field but not validations is rejected", /ArgumentError: a shape member must answer to `validations`/ do
  raw_shape_verdict({ members: [Class.new { def field = :a }.new], container: Hash })
end

# Axn's own validators accept a direct value in place of an options bag (`type: Hash`, `of: Hash`), and the DSL
# expands it into that bag. A raw member's bag was canonicalized at the KEY level only, so the bare spelling —
# the only one anyone writes by hand — reached the validators and the projection as a Class, which both read as
# `[:klass]`: the member validated nothing (`ArgumentError: must supply :klass` on every call) while the
# projection asked a Class for `#dig`/`#[]`. The member snapshot now applies the same expansion from the same
# seam, so these rows assert the CLOSURE: one declaration, one bag, whichever way it was spelled.
def bare_member_axn(validations)
  member = SC.new(field: :m, validations:)
  Class.new do
    include Axn
    expects :payload, type: Hash, shape: { members: [member], container: Hash }
    def call; end
  end
end

# Both halves of one row, because either alone was the defect: what the projection SAYS and what a call DOES.
def bare_member_verdict(validations, value)
  klass = bare_member_axn(validations)
  projected = JSON.generate(klass.input_schema.dig(:properties, :payload, :properties, :m))
  r = klass.call(payload: { m: value })
  "#{projected} call=#{r.ok? ? 'ok' : "#{r.exception.class}: #{r.exception.message}"}"
end

def bare_vs_canonical(bare, canonical, value)
  bare_verdict = bare_member_verdict(bare, value)
  "#{bare_verdict} #{bare_verdict == bare_member_verdict(canonical, value) ? '==' : '!='} canonical"
end

INNER_SHAPE = { members: [SC.new(field: :x, validations: {})], container: Hash }

check "a member's bare `type:` validates and projects as the `{ klass: }` bag does",
      '{"type":"object","properties":{"x":{}}} call=ok == canonical' do
  bare_vs_canonical({ type: Hash, shape: INNER_SHAPE }, { type: { klass: Hash }, shape: INNER_SHAPE }, { x: 1 })
end

# The type's OWN members come from the same read, so the bare spelling has to reach them too — otherwise it
# would project a strictly smaller property set than the canonical bag under the same declaration.
BARE_DATA = Data.define(:a, :b)
check "...including a bare Data type's own members",
      '{"type":"object","properties":{"a":{},"b":{},"x":{}}} call=ok == canonical' do
  bare_vs_canonical({ type: BARE_DATA, shape: INNER_SHAPE }, { type: { klass: BARE_DATA }, shape: INNER_SHAPE },
                    BARE_DATA.new(a: 1, b: 2))
end

# `of:` is the same option one layer down, and it was worse off: the projection reads it as a bag in three
# places, so a bare one raised `ArgumentError: odd number of arguments for Hash` from `input_schema` — before
# any call could reach the "must supply :klass" the runtime had waiting for it.
check "a member's bare `of:` validates and projects as the `{ klass: }` bag does",
      '{"type":"array","items":{"type":"object"}} call=ok == canonical' do
  bare_vs_canonical({ type: Array, of: Hash }, { type: { klass: Array }, of: { klass: Hash } }, [{ a: 1 }])
end

# The one shorthand a member has no meaning for is refused rather than expanded: `model:` resolves a record and
# exposes a companion reader, neither of which a reader-less member has, so expanding it would have made the
# option silently type-check the element in place. The block form has always refused it; the raw route used to
# declare cleanly and fail every call with `must supply :klass`.
check "a member's `model:` is refused rather than expanded",
      /ArgumentError: shape member `m` does not support model:/ do
  raw_shape_verdict({ members: [SC.new(field: :m, validations: { model: Hash })], container: Hash })
end

# Expanding a shorthand is only HALF of what canonicalizing a bag is for: the compatibility guards that read
# what the expansion produced run in the same seam, so a member is rejected for exactly what a field is
# rejected for. Extracting the expansion alone left a member expanding like a field and validating like
# nothing. Each row declares the SAME options both ways and compares the two verdicts, which is the property
# the seam exists to hold — not merely that something raised.
def member_field_parity(validations, value)
  member = SC.new(field: :m, validations:)
  field = declaration_verdict(m: value) do
    Class.new do
      include Axn
      expects :m, **validations
      def call; end
    end
  end
  raw = declaration_verdict(payload: { m: value }) do
    Class.new do
      include Axn
      expects :payload, type: Hash, shape: { members: [member], container: Hash }
      def call; end
    end
  end
  "#{raw} #{raw == field ? '==' : '!='} field"
end

# The verdict of a declaration, and — when it declares — of a call against it, since an option that is merely
# INERT declares perfectly well: that is the whole shape of this defect.
def declaration_verdict(inputs)
  r = yield.call(**inputs)
  "declared; call ok=#{r.ok?}#{r.ok? ? '' : " (#{r.exception.class})"}"
rescue ::Exception => e # rubocop:disable Lint/RescueException
  "#{e.class}: #{e.message}"
end

# `OfValidator` returns before it inspects a value that is not an Array, so beside a non-Array `type:` the
# element constraint never applies to any value the member accepts — a contradiction with no runtime signal
# at all, which is why it has to be a declaration error.
check "a member's `of:` beside a non-Array `type:` is refused, as a field's is",
      "ArgumentError: of: requires type: Array (got [Hash]) == field" do
  member_field_parity({ type: Hash, of: String }, {})
end

# The same mistake spelled without a `type:`: the member constrained an Array's elements and accepted every
# non-Array value silently.
check "...and a bare `of:` naming no type at all",
      "ArgumentError: of: requires type: Array (got []) == field" do
  member_field_parity({ of: String }, "nope")
end

# The required-option half, reached THROUGH the expansion (`of: nil` expands to `{ klass: nil }`): it used to
# declare and then raise the same message from `check_validity!` on every call — the right diagnosis at the
# wrong time, delivered to whoever called rather than whoever declared.
check "...and an `of:` naming nothing", "ArgumentError: of: must supply :klass == field" do
  member_field_parity({ type: Array, of: nil }, [])
end

check "CONTROL: a legitimate `of:` still declares and validates on both routes",
      "declared; call ok=true == field" do
  member_field_parity({ type: Array, of: Hash }, [{ a: 1 }])
end

# RECORDED RESIDUE, and a field-path one rather than a member's: `of: false` is not `of: nil`, so the
# required-option check passes it through and `TypeValidator.value_matches?(el, klass: false)` raises
# `TypeError: class or module required` on the first call carrying a non-empty Array. It is recorded here
# because it is the boundary of what the shared guard covers, and because the two routes agreeing about it —
# both of them wrong, identically — is what "the member reaches the field's own guards" means.
check "an `of: false` is inert on BOTH routes (residue)", "declared; call ok=false (TypeError) == field" do
  member_field_parity({ type: Array, of: false }, [1])
end

# The same parity one level down: a member's NESTED `shape:` is a shape declared by hand exactly as a field's
# is, and the declaration walk recursed past both the field path's container derivation and its container
# check. So a hand-written nested shape — needing no hostile object, and the natural spelling for a raw member
# — declared cleanly and failed EVERY call with a bare `TypeError: class or module required`, naming neither
# the member nor the option, while the block form derived a container and worked.
NESTED_LEAF = [SC.new(field: :leaf, validations: { type: String })].freeze

check "a member's nested `shape:` gets the container derived, as a field's does",
      "declared; call ok=true == field" do
  member_field_parity({ type: Hash, shape: { members: NESTED_LEAF } }, { leaf: "x" })
end

# The guard half of the same seam, and the one that changes a previously-declaring contract into a raise.
check "...and a nested non-class `container:` is refused, as a field's is",
      /ArgumentError: a shape's `container:` must be a class \(got :junk\).* == field/ do
  member_field_parity({ type: Hash, shape: { members: [], container: :junk } }, {})
end

# The walk recurses, so every level is a member of some shape: depth 2 has to behave exactly as depth 1, both
# halves. A row per half, since the derivation and the guard fail differently.
DEEP_DERIVED = [SC.new(field: :deep, validations: { type: Hash, shape: { members: NESTED_LEAF } })].freeze
DEEP_JUNK = [SC.new(field: :deep, validations: { type: Hash, shape: { members: [], container: :junk } })].freeze

check "the derivation reaches a shape nested two levels down", "declared; call ok=true == field" do
  member_field_parity({ type: Hash, shape: { members: DEEP_DERIVED } }, { deep: { leaf: "x" } })
end

check "...and so does the container check", /ArgumentError: a shape's `container:` must be a class \(got :junk\).* == field/ do
  member_field_parity({ type: Hash, shape: { members: DEEP_JUNK } }, { deep: {} })
end

# Deriving needs something structured to derive FROM, and reports the field path's own declaration error when
# there is not — rather than storing a nil container for the first call to trip over.
check "a nested shape with no structured `type:` to derive from is refused",
      /ArgumentError: a shape block requires a single structured type:.* == field/ do
  member_field_parity({ shape: { members: NESTED_LEAF } }, {})
end

check "CONTROL: an explicit nested `container:` still declares and validates on both routes",
      "declared; call ok=true == field" do
  member_field_parity({ type: Hash, shape: { members: NESTED_LEAF, container: Hash } }, { leaf: "x" })
end

# A container comes from the ENCLOSING member's `type:`, so it belongs to the POSITION and not to the node: one
# nested shape object reused by two members with different types needs a different container in each place.
# The walk's memo hands both members ONE copy (which is what keeps a shared sub-shape from costing 2^depth
# walks), so the derivation detaches before it writes — and the caller's own node is never written into.
check "a nested shape shared by two members gets each position's own container", "[Hash, Array] caller=[:members] call ok=true" do
  shared = { members: NESTED_LEAF }
  members = [SC.new(field: :a, validations: { type: Hash, shape: shared }),
             SC.new(field: :b, validations: { type: Array, shape: shared })]
  klass = Class.new do
    include Axn
    expects :payload, type: Hash, shape: { members:, container: Hash }
    def call; end
  end
  stored = klass.internal_field_configs.first.validations[:shape][:members].map { |m| m.validations[:shape][:container] }
  r = klass.call(payload: { a: { leaf: "x" }, b: [{ leaf: "y" }] })
  "#{stored.inspect} caller=#{shared.keys.inspect} call ok=#{r.ok?}"
end

# ---------------------------------------------------------------------------------------------------
puts "\n== the boot guarantee, including a tool that inherits its adapter's readers ============="
# ---------------------------------------------------------------------------------------------------

# An adapter base that already owns the schema readers — the ordinary shape of a real tool
# (`Axn::MCP::Tool < ::MCP::Tool`). axn deliberately does not install its own over them, so setup must
# validate axn's OWN projections rather than reaching through the class methods.
class ADAPTER_BASE
  def self.input_schema = { "transport" => "in" }
  def self.output_schema = { "transport" => "out" }
end

BOOT_SHADOW_NAMES = %w[BootShadowInbound BootShadowOutbound].freeze

def boot_verdict(klass_name, inbound:)
  # The registry is process-global and drops classes whose constant is gone, so the other row's tool is
  # removed first — otherwise whichever declared first raises and the row proves nothing about this one.
  BOOT_SHADOW_NAMES.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  Axn::Tools::Registry.reset_adapters!
  Axn.register_tool_adapter(:probe)
  utf8 = UTF8_NAME
  latin1 = LATIN1_NAME
  klass = Class.new(ADAPTER_BASE) do
    include Axn
    tool
    if inbound
      expects(:payload, type: Hash) do
        field utf8, type: String
        field latin1, type: Integer
      end
    else
      exposes(:payload, type: Hash) do
        field utf8, type: String
        field latin1, type: Integer
      end
    end
    def call = expose(payload: {})
  end
  Object.const_set(klass_name, klass)
  # Asserted structurally, never through Hash#inspect (whose spacing changed in Ruby 3.4).
  shadowed = klass.input_schema == { "transport" => "in" } && klass.output_schema == { "transport" => "out" }
  begin
    Axn.validate_tool_contracts!
    "readers shadowed=#{shadowed}; boot: NO RAISE"
  rescue ::Exception => e
    "readers shadowed=#{shadowed}; boot: #{e.class}: #{e.message[0, 55]}"
  end
ensure
  Axn::Tools::Registry.reset_adapters!
end

# Naming the tool must not cost the error. Reconstructing the exception class (`raise e.class, message`) calls a
# constructor axn did not write, which fails outright for any exception taking more than a message — destroying
# both the contract error and the class it promised to keep. Raising the OBJECT clones it and runs no initializer.
STRUCTURED_BOOT_ERROR = Class.new(ArgumentError) do
  def initialize(path:)
    @path = path
    super(nil)
  end

  def message = "structured at #{@path}"
end

def boot_error_verdict(raiser)
  Axn::Tools::Registry.reset_adapters!
  Axn.register_tool_adapter(:probe)
  Object.send(:remove_const, :BootErrorTool) if Object.const_defined?(:BootErrorTool)
  klass = Class.new do
    include Axn
    tool
    expects :a, optional: true
    def call; end
  end
  Object.const_set(:BootErrorTool, klass)
  raiser.call(klass)
  begin
    Axn.validate_tool_contracts!
    "NO RAISE"
  rescue ::Exception => e
    "#{e.class}: #{e.message[0, 60]} | cause=#{e.cause.class}"
  end
ensure
  # The constant must go, not just the adapters: the registry is process-global and enumerates any named class
  # still defined, so a tool whose `internal_field_configs` raises would hijack every later boot row.
  Object.send(:remove_const, :BootErrorTool) if Object.const_defined?(:BootErrorTool)
  Axn::Tools::Registry.reset_adapters!
end

check "a structured exception reaches setup with its class, message and cause",
      "#{STRUCTURED_BOOT_ERROR}: structured at p | cause=#{STRUCTURED_BOOT_ERROR}" do
  boot_error_verdict(lambda { |klass|
    error = STRUCTURED_BOOT_ERROR
    klass.define_singleton_method(:internal_field_configs) { raise error.new(path: "p") }
  })
end

# ...and the ordinary case still names the tool, since that is what the naming is for.
check "a message-only exception is named for its tool", /BootErrorTool has an invalid tool contract — boom/ do
  boot_error_verdict(->(klass) { klass.define_singleton_method(:internal_field_configs) { raise ArgumentError, "boom" } })
end

# Renaming an exception runs the exception's own code — `#message` to read it, and a duplication hook to copy it —
# so a class that refuses to cooperate could REPLACE the contract failure being reported, at boot, with nothing
# naming the tool. Outside StandardError it escaped the rescue meant to settle it. Each fixture below must degrade
# the MESSAGE and keep the failure, its class included.
#
# Reported through bound `Exception#to_s`, because these fixtures are precisely the classes whose `#message` raises
# — the harness must not lose the verdict the same way the code under test must not.
EXCEPTION_TO_S_FOR_HARNESS = ::Exception.instance_method(:to_s)

def hostile_boot_verdict(error)
  Axn::Tools::Registry.reset_adapters!
  Axn.register_tool_adapter(:probe)
  Object.send(:remove_const, :HostileBootTool) if Object.const_defined?(:HostileBootTool)
  klass = Class.new do
    include Axn
    tool
    expects :a, optional: true
    def call; end
  end
  Object.const_set(:HostileBootTool, klass)
  klass.define_singleton_method(:internal_field_configs) { raise error }
  begin
    Axn.validate_tool_contracts!
    "NO RAISE"
  rescue ::Exception => e
    "#{Axn::Internal::ClassName.of(e)}: #{EXCEPTION_TO_S_FOR_HARNESS.bind_call(e)[0, 70]} " \
      "cause=#{Axn::Internal::ClassName.of(e.cause)}"
  end
ensure
  Object.send(:remove_const, :HostileBootTool) if Object.const_defined?(:HostileBootTool)
  Axn::Tools::Registry.reset_adapters!
end

HOSTILE_MESSAGE_ERROR = Class.new(ArgumentError) do
  def message = raise(NotImplementedError, "hostile message")
end

HOSTILE_RENDERING_ERROR = Class.new(ArgumentError) do
  def message = raise(NotImplementedError, "hostile message")
  def to_s = raise(NotImplementedError, "hostile to_s")
end

# Substitutes only when handed a MESSAGE, and answers the 0-arg call `raise` makes with itself — so it can be
# raised, reach the reporter, and then be swapped for something else by `raise e, message`.
HOSTILE_EXCEPTION_ERROR = Class.new(ArgumentError) do
  def exception(*args) = args.empty? ? self : ::RuntimeError.new("substituted")
end

HOSTILE_COPY_ERROR = Class.new(ArgumentError) do
  def initialize_copy(other) = raise(NotImplementedError, "hostile copy")
end

# Succeeds on its FIRST `#exception` call and raises on the second, which is exactly what "it was raised once, so
# a redispatch is safe" did not cover.
HOSTILE_SECOND_CALL_ERROR = Class.new(ArgumentError) do
  def initialize(*)
    @calls = 0
    super
  end

  def exception(*_args)
    @calls += 1
    raise NotImplementedError, "second call" if @calls > 1

    self
  end
end

HOSTILE_MESSAGE_OBJECT_ERROR = Class.new(ArgumentError) do
  RUDE_TO_S = Class.new { def to_s = raise(NotImplementedError, "hostile to_s") }
  def message = RUDE_TO_S.new
end

# The cause of whatever boot reports, by class name.
def boot_cause_class(error)
  verdict = hostile_boot_verdict(error)
  verdict.is_a?(::String) ? verdict.split("cause=").last : verdict
end

check "an exception whose #message raises is reported by its stored message",
      "#{HOSTILE_MESSAGE_ERROR}: HostileBootTool has an invalid tool contract — the real defect cause=#{HOSTILE_MESSAGE_ERROR}" do
  hostile_boot_verdict(HOSTILE_MESSAGE_ERROR.new("the real defect"))
end

check "one whose #message and #to_s both raise is reported by its class",
      "#{HOSTILE_RENDERING_ERROR}: HostileBootTool has an invalid tool contract — #{HOSTILE_RENDERING_ERROR} " \
      "cause=#{HOSTILE_RENDERING_ERROR}" do
  hostile_boot_verdict(HOSTILE_RENDERING_ERROR.new)
end

# The two cases axn will not rename AT ALL, decided by OWNERSHIP rather than by observing behaviour: renaming
# ends in `raise`, which dispatches the 0-arg `#exception` on the object it is handed, and no guard can wrap that.
# Reported as axn's own error, which keeps the tool name and the message and carries the original as `cause`.
check "an #exception override is reported as axn's own error",
      /\AAxn::InvalidToolContract: HostileBootTool has an invalid tool contract — the real defect/ do
  hostile_boot_verdict(HOSTILE_EXCEPTION_ERROR.new("the real defect"))
end

# Being raised once says NOTHING about the second call — the argument this row retired. `Exception#exception`
# clones, so `raise` asks the CLONE, and an override that answers itself once and raises after destroyed the
# contract failure at boot.
check "an #exception that raises on its SECOND call cannot escape",
      /\AAxn::InvalidToolContract: HostileBootTool has an invalid tool contract — the real defect/ do
  hostile_boot_verdict(HOSTILE_SECOND_CALL_ERROR.new("the real defect"))
end

check "one that owns a duplication hook is reported as axn's own error, naming the tool",
      /\AAxn::InvalidToolContract: HostileBootTool has an invalid tool contract — the real defect/ do
  hostile_boot_verdict(HOSTILE_COPY_ERROR.new("the real defect"))
end

# A FROZEN exception owns nothing and still cannot be renamed: `clone` preserves frozen state, so storing the new
# message on the copy raises FrozenError from inside the reporting path.
check "a frozen exception is reported as axn's own error",
      /\AAxn::InvalidToolContract: HostileBootTool has an invalid tool contract — the real defect/ do
  hostile_boot_verdict(::ArgumentError.new("the real defect").freeze)
end

# A `#message` that answers with a hostile OBJECT rather than raising: interpolating it into the renamed message
# would dispatch that object's `to_s` outside the guard. The result is type-tested, so a non-String falls back to
# the stored message — and the class is still kept, since `#message` is not what renaming runs.
check "a #message answering with an object whose to_s raises degrades to the stored message",
      "#{HOSTILE_MESSAGE_OBJECT_ERROR}: HostileBootTool has an invalid tool contract — the stored message " \
      "cause=#{HOSTILE_MESSAGE_OBJECT_ERROR}" do
  hostile_boot_verdict(HOSTILE_MESSAGE_OBJECT_ERROR.new("the stored message"))
end

# `cause` is set explicitly, so it survives the DEGRADED paths too: reading a hostile `#message` means rescuing
# inside the boot rescue, and Ruby does not restore `$!` afterwards, so the implicit cause was nil there.
check "every reported boot failure carries the original as cause",
      ["ArgumentError", HOSTILE_MESSAGE_ERROR.to_s, HOSTILE_EXCEPTION_ERROR.to_s, HOSTILE_COPY_ERROR.to_s] do
  [::ArgumentError.new("plain"), HOSTILE_MESSAGE_ERROR.new("stored"), HOSTILE_EXCEPTION_ERROR.new("x"),
   HOSTILE_COPY_ERROR.new("x")].map { |error| boot_cause_class(error) }
end

check "boot validates a shadowing tool's INBOUND contract",
      /readers shadowed=true; boot: Axn::DuplicateFieldError: BootShadowInbound has an invalid tool contract/ do
  boot_verdict("BootShadowInbound", inbound: true)
end

check "boot validates a shadowing tool's OUTBOUND contract too",
      /readers shadowed=true; boot: Axn::DuplicateFieldError: BootShadowOutbound has an invalid tool contract/ do
  boot_verdict("BootShadowOutbound", inbound: false)
end

# ---------------------------------------------------------------------------------------------------
puts "\n== a graph a class HOLDS that was never walked =========================================="
# ---------------------------------------------------------------------------------------------------

# Declaring cannot produce an untraversable stored graph: the declaration walk rejects one and snapshots what it
# accepts into axn's own Hashes and ShapeConfigs, nested shapes included. What remains is the config arrays
# themselves, which are writable — so a shape assigned onto a class rather than declared is held exactly as its
# author built it, and can be pointed back at itself. Every projection walks it, and SystemStackError escapes
# every rescue meant to settle a result, so each walk is bounded and reports the cycle the way the
# declaration-time guard does.
FC = Axn::Core::Contract::FieldConfig

def held_shape_config(field, member, **)
  FC.new(field:, reader_as: field, validations: { type: { klass: Hash }, shape: { members: [member], container: Hash } }, **)
end

def axn_holding(member)
  klass = Class.new do
    include Axn
    def call = expose(out: {})
  end
  klass.internal_field_configs = [held_shape_config(:payload, member)].freeze
  klass.external_field_configs = [held_shape_config(:out, member)].freeze
  klass
end

def cyclic_after_declaration
  member = Class.new do
    attr_accessor :validations

    def initialize = @validations = { type: { klass: Hash }, shape: { members: [], container: Hash } }
    def field = :outer
  end.new
  member.validations[:shape][:members] << SC.new(field: :inner, validations: {})
  [member, axn_holding(member)]
end

def projection_verdict(projection)
  member, klass = cyclic_after_declaration
  before = klass.input_schema.dig(:properties, :payload, :properties, :outer, :properties).keys
  member.validations[:shape] = { members: [member], container: Hash }
  begin
    klass.public_send(projection)
    [before, "NO ERROR"]
  rescue ::Exception => e
    [before, "#{e.class}: #{e.message[0, 39]}"]
  end
end

check "the inbound projection reports a bounded error", [[:inner], "ArgumentError: a `shape:` graph reached from the shape"] do
  projection_verdict(:input_schema)
end

check "the outbound projection reports the same", [[:inner], "ArgumentError: a `shape:` graph reached from the shape"] do
  projection_verdict(:output_schema)
end

# The OTHER half of untraversability, which identity cannot see: a member whose nested shape is minted fresh on
# every read repeats no object, so `CycleGuard` sees nothing and only a depth bound stops it. Same graph shape as
# the cycle rows above, one mutation apart.
def generative_after_declaration
  member = Class.new do
    attr_accessor :gen

    def initialize
      @gen = false
      @fixed = { members: [SC.new(field: :inner, validations: {})], container: Hash }
    end

    def field = :outer
    def validations = { type: { klass: Hash }, shape: @gen ? { members: [self], container: Hash } : @fixed }
  end.new
  [member, axn_holding(member)]
end

def generative_verdict(projection)
  member, klass = generative_after_declaration
  before = klass.input_schema.dig(:properties, :payload, :properties, :outer, :properties).keys
  member.gen = true
  begin
    klass.public_send(projection)
    [before, "NO ERROR"]
  rescue ::Exception => e
    [before, "#{e.class}: #{e.message[0, 39]}"]
  end
end

check "a GENERATIVE graph is bounded on the inbound projection", [[:inner], "ArgumentError: a `shape:` graph reached from the shape"] do
  generative_verdict(:input_schema)
end

check "...and on the outbound projection", [[:inner], "ArgumentError: a `shape:` graph reached from the shape"] do
  generative_verdict(:output_schema)
end

check "the generative message names depth, not a cycle", /nests more than 64 levels deep/ do
  member, klass = generative_after_declaration
  klass.input_schema
  member.gen = true
  begin
    klass.input_schema
    "NO ERROR"
  rescue ::Exception => e
    e.message
  end
end

# The redaction walks read the same stored graph on every logged call, so both halves reach them too. The
# predicate answers TRUE past the depth bound (fail-safe: mask wholesale rather than log a secret in the clear),
# while the candidate walk simply stops — the wholesale mask is what covers what it cannot enumerate.
check "the sensitive-member walk is bounded for a generative graph", true do
  member, klass = generative_after_declaration
  member.gen = true
  klass.send(:_shape_has_sensitive_member?, { members: [member], container: Hash }, nil)
end

check "the candidate walk is bounded for a generative graph", true do
  member, klass = generative_after_declaration
  member.gen = true
  klass.send(:_sensitive_candidate_configs).size.between?(1, 500)
end

# `inspect` is reachable directly rather than only from a side channel, so its own redaction walk is bounded too.
check "the inspect redaction walk is bounded for a generative graph", true do
  member, klass = generative_after_declaration
  member.gen = true
  inspector = Axn::Core::ContextFacadeInspector.allocate
  begin
    inspector.send(:collect_sensitive_member_names, klass.internal_field_configs.first)
    true
  rescue ::NoMethodError
    true # reached `action.class` on a bare inspector: the WALK returned, which is what this row tests
  rescue ::Exception => e
    e.class.to_s
  end
end

# Declaring a LATER ambient subfield re-walks every ambient config's shape, so a graph the class was handed
# rather than declared reaches that walk. Both halves, both bounded.
def ambient_verdict(mode)
  member = Class.new do
    attr_accessor :mode

    def initialize
      @mode = :fixed
      @fixed = { members: [SC.new(field: :inner, validations: {})], container: Hash }
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
  klass = Class.new do
    include Axn
    expects :request, on: :ambient_context, type: Hash
    def call; end
  end
  klass.subfield_configs = [held_shape_config(:request, member, on: :ambient_context)].freeze
  member.mode = mode
  begin
    klass.class_eval { expects :other, on: :ambient_context, type: Hash }
    "declared"
  rescue ::Exception => e
    "#{e.class}: #{e.message[0, 39]}"
  end
end

check "a later ambient declaration is bounded for a cyclic graph", "ArgumentError: a `shape:` graph reached from the shape" do
  ambient_verdict(:cycle)
end

check "...and for a generative one", "ArgumentError: a `shape:` graph reached from the shape" do
  ambient_verdict(:generative)
end

# The bound is ONE number from one place, so the declaration and re-walk paths cannot drift.
check "one nesting cap, shared by every walk", 64 do
  Axn::Internal::ShapeGraph::MAX_NESTING
end

# Honest nesting just under the cap must still declare AND project — the bound only ever fires on a graph
# something generated.
check "honest 60-level nesting still declares and projects", "declared and projected" do
  shape = { members: [SC.new(field: :leaf, validations: {})], container: Hash }
  60.times { shape = { members: [SC.new(field: :n, validations: { type: { klass: Hash }, shape: })], container: Hash } }
  klass = expects_axn(shape, type: Hash)
  klass.input_schema
  klass.output_schema
  "declared and projected"
rescue ::Exception => e
  "#{e.class}: #{e.message[0, 50]}"
end

# The redaction walk reads the same stored graph on every logged call: a side channel must not be able to take
# down the call it observes, and a cyclic branch re-reaches members the enclosing frame already tested.
check "the sensitive-member walk stays bounded", false do
  member, klass = cyclic_after_declaration
  member.validations[:shape] = { members: [member], container: Hash }
  klass.send(:_shape_has_sensitive_member?, { members: [member], container: Hash }, nil)
end

check "a logged call still settles as an ordinary result", "Axn::InboundValidationError" do
  member, klass = cyclic_after_declaration
  member.validations[:shape] = { members: [member], container: Hash }
  klass.call(payload: { outer: { inner: 1 } }).exception&.class.to_s
end

# An unwalked GRAPH is not the only thing an assigned config carries: its members are the caller's objects too, so
# the ATTRIBUTES the declaration walk grammar-checks on the way into a snapshot are unchecked here as well.
# `user_facing:` is the one whose unchecked value is RESOLVED rather than merely stored — it decides the failure's
# classification and then becomes the caller's message — so it is checked where it is read.
def duck_carrying(**readers)
  Class.new { readers.each { |name, value| define_method(name) { value } } }.new
end

def assigned_member_verdict(**readers)
  klass = Class.new do
    include Axn
    def call = nil
  end
  klass.internal_field_configs = [held_shape_config(:payload, duck_carrying(field: :inner, validations: { presence: true }, **readers))].freeze
  result = klass.call(payload: {})
  "#{result.outcome}: #{result.exception.class}: #{result.error}"
rescue ::Exception => e
  "RAISED #{e.class}: #{e.message[0, 60]}"
end

check "an assigned member's malformed user_facing: is refused, not surfaced",
      "exception: ArgumentError: Something went wrong" do
  assigned_member_verdict(user_facing: 123)
end

# The consequence that is worse than the wrong message: a truthy non-rule composed as user-facing, so the failure
# settled as a plain failure and the contract bug was never reported at all.
check "...so the outcome stays reported rather than reclassified", true do
  assigned_member_verdict(user_facing: 123).start_with?("exception:")
end

check "an assigned member carrying a REAL rule still surfaces it", "failure: Axn::InboundValidationError: Needs an inner" do
  assigned_member_verdict(user_facing: "Needs an inner")
end

# Falsy is "not opted in" and has no grammar to meet: `nil` is what a Struct member declaring the attribute
# without setting it answers, so checking it would turn every such member into an ArgumentError.
check "a falsy one is not opted in, and is not checked", "exception: Axn::InboundValidationError: Something went wrong" do
  assigned_member_verdict(user_facing: nil)
end

# The FIELD half of the same route, closed one level earlier: a FieldConfig cannot be CONSTRUCTED with a value
# that is not a resolution rule, so an assigned config carrying one does not exist to be resolved. No runtime
# check ever covered this — a field's `user_facing:` was held only by the `expects`/`exposes` DSL.
check "an assigned FIELD config cannot carry a malformed user_facing: at all",
      /ArgumentError: user_facing: must be true/ do
  FC.new(field: :name, reader_as: :name, validations: { presence: true }, user_facing: 123).inspect
rescue ::Exception => e
  "#{e.class}: #{e.message[0, 40]}"
end

# RECORDED RESIDUE, not a guarantee: the same bypass leaves an assigned member's `sensitive:` unchecked, and an
# invalid rule there is silently "not sensitive" — the value logs in the clear. Deliberately not closed with the
# `user_facing:` half: every read of it is a redaction walk running inside `Extensions.best_effort` on a live
# call, where raising loses the log line rather than telling the author, and paying a grammar check per member
# per logged call is a cost the declared path (where the walk already checked it) would carry for nothing.
# A field's `sensitive:` is held at FieldConfig's constructor, so only a MEMBER is exposed.
# The value is asserted structurally rather than through `Hash#inspect`, whose spacing changed in Ruby 3.4.
check "an assigned member's sensitive: is NOT held to the grammar (residue)", [[], "SHH"] do
  klass = Class.new do
    include Axn
    def call = nil
  end
  klass.internal_field_configs = [held_shape_config(:payload, duck_carrying(field: :ssn, validations: {}, sensitive: "yes"))].freeze
  [klass.sensitive_fields, klass.send(:_context_slice, data: { payload: { ssn: "SHH" } }, direction: :inbound).dig(:payload, :ssn)]
end

# ---------------------------------------------------------------------------------------------------
puts "\n== the last of that: a reader that answers differently each read ========================"
# ---------------------------------------------------------------------------------------------------

# This was the recorded limit — a reader reporting a different name on each read split the guard from its
# consumer whichever single read either made, so the guard saw two distinct names and the schema emitted one
# property twice. The member snapshot closes it: the FIRST read is the declaration, and every consumer reads
# what was stored. A caller's object still decides what its contract SAYS; it no longer gets to say one thing
# to a guard and another to the schema.
check "non-idempotent reader: the first read is the contract", /declared props=\[:unique\d+, :unique\d+\]/ do
  members = [DRIFTING.new, DRIFTING.new]
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

# The complement, and the one the reader row above did not cover: a name read ONCE whose CONVERSION answers
# twice. `to_sym` is a second dispatch on the caller's object, so a member whose name is stable but whose
# conversion is not gave the duplicate check `:alpha` and `ShapeConfig`'s constructor `:collide` — two declared
# members stored under one property, one property emitted, nothing raised. The walk now canonicalizes once,
# beside the check that judges it.
check "non-idempotent name conversion: the judged Symbol is the stored one",
      'declared props=[:alpha, :collide] json={"alpha":{},"collide":{}}' do
  members = [duck_carrying(field: DRIFTING_NAME.new, validations: {}), duck_carrying(field: :collide, validations: {})]
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

# And the other direction of the same property: when the ONE conversion is the colliding one, it is rejected.
# Whichever way the name answers, the verdict and the stored contract are the same fact.
check "non-idempotent name conversion, colliding answer: rejected",
      /DuplicateFieldError: Duplicate shape member declared/ do
  name = DRIFTING_NAME.new
  name.to_sym # spend the :alpha answer, so the declaration's own read is :collide
  members = [duck_carrying(field: name, validations: {}), duck_carrying(field: :collide, validations: {})]
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

# The same defect on the OTHER path a name reaches a node by: `on:`. A route is judged as written (its root must
# name a declared reader; the duplicate check keys a config by it) and then split again by SubfieldTree,
# `resolve_parent`, the ambient checks and the executor's parent memo — so a route whose rendering drifted had
# the guard clearing `:q` while the tree anchored at `:p`, landing two subfields on ONE node where the honest
# spelling is a duplicate. Canonicalized once, at declaration, exactly as a field name is.
check "a drifting on: route anchors where it was judged", "p=[:a] q=[:a]" do
  route = DRIFTING_ROUTE.new
  klass = Class.new do
    include Axn
    expects :p, type: Hash
    expects :q, type: Hash
    expects :a, on: :p, optional: true
    expects :a, on: route, as: :qa, optional: true
    def call; end
  end
  # Rendered pairwise rather than through `Hash#inspect`, whose spacing changed in Ruby 3.4.
  klass.input_schema[:properties].map { |key, prop| "#{key}=#{prop[:properties]&.keys.inspect}" }.join(" ")
end

# ---------------------------------------------------------------------------------------------------
# A NAME's own methods, run while the name is being reported. A declared name is caller-supplied, so a String
# subclass can define `==`/`eql?`/`to_s` — the very methods the property-name rules ask it — and every such
# dispatch between "these two names are one property" and the raised error is a chance for the name to raise
# INSTEAD of the report. Only a config ASSIGNED onto a class carries a raw name (the DSL symbolizes every
# declared one), which is the same route every other unwalked-graph row here uses.
# ---------------------------------------------------------------------------------------------------

RAISING_NAME_EQ = Class.new(String) do
  def ==(_other) = raise(NotImplementedError, "hijacked from #==")
  def eql?(_other) = false
end

RAISING_NAME_TO_S = Class.new(String) do
  def to_s = raise(NotImplementedError, "hijacked from #to_s")
end

RAISING_NAME_EQL = Class.new(String) do
  def eql?(_other) = raise(NotImplementedError, "hijacked from #eql?")
end

# A name whose rendering answers differently on successive reads. `first` for the first read, `second` after.
FLIPPING_NAME = Class.new do
  def initialize(first, second)
    @first = first
    @second = second
    @answered = false
  end

  def to_s
    was = @answered
    @answered = true
    was ? @second : @first
  end
end

def assigned_names(*fields, direction: :input)
  klass = Class.new do
    include Axn
    def call; end
  end
  configs = fields.each_with_index.map do |field, index|
    Axn::Core::Contract::FieldConfig.new(field:, reader_as: :"x#{index}", validations: { allow_nil: true })
  end
  klass.public_send(direction == :input ? :internal_field_configs= : :external_field_configs=, configs.freeze)
  klass
end

def assigned_projection(*fields, direction: :input)
  klass = assigned_names(*fields, direction:)
  schema = direction == :input ? klass.input_schema : klass.output_schema
  "props=#{schema[:properties].size}"
end

BAD_BINARY_NAME = "bad\xFF".dup.force_encoding("ASCII-8BIT")
BAD_UTF8_NAME = "bad\xFF".dup.force_encoding("UTF-8")

# Attribution recovers WHICH declarations collided by matching emitted paths, and `Array#==` dispatches each
# element's own `==`. The guard around the attribution WALK does not reach the lookup over its result.
check "a colliding name's == cannot replace the inbound report", /DuplicateFieldError.*"dup" and :dup/ do
  assigned_projection(RAISING_NAME_EQ.new("dup"), :dup)
end

check "a colliding name's == cannot replace the outbound report", /DuplicateFieldError.*"dup" and :dup/ do
  assigned_projection(RAISING_NAME_EQ.new("dup"), :dup, direction: :output)
end

check "an unrenderable name's == cannot replace its report", /ArgumentError.*no.*UTF-8 rendering/ do
  assigned_projection(RAISING_NAME_EQ.new(BAD_BINARY_NAME))
end

# Canonicalization is the rules' own INPUT, so a dispatch there is a dispatch inside a verdict. A name that OWNS
# that dispatch is refused a rule earlier — its two candidate names make the property it means undecidable — and
# what these rows pin is that the refusal itself runs none of the name's code.
check "a lone name whose to_s raises is refused without running it", /ArgumentError.*"a" does not render through Ruby's own `to_s`/ do
  assigned_projection(RAISING_NAME_TO_S.new("a"))
end

check "a colliding name whose to_s raises is refused, not run", /ArgumentError.*"dup" does not render through Ruby's own `to_s`/ do
  assigned_projection(RAISING_NAME_TO_S.new("dup"), :dup)
end

# Asking twice is what let a second, different answer overturn a verdict already reached. A String's canonical
# property is its own bytes, so its `to_s` is not asked at all — and both rules fire on this one, the rendering
# rule first: a name with two candidate names has no single property for the bytes rule to be about.
check "a String name judged on its bytes, whose to_s claims otherwise, is refused", /ArgumentError.*does not render through Ruby's own `to_s`/ do
  liar = Class.new(String) do
    def to_s = "renderable"
  end
  assigned_projection(liar.new(BAD_BINARY_NAME))
end

check "an exotic name is refused rather than judged on a rendering it may retract", /ArgumentError.*a name of class .* does not render through Ruby's own `to_s`/ do
  assigned_projection(FLIPPING_NAME.new(BAD_BINARY_NAME, "renderable"))
end

check "an exotic name's second rendering cannot hide a duplicate", /DuplicateFieldError.*JSON property "dup"/ do
  klass = assigned_names(FLIPPING_NAME.new("dup", "other"))
  klass.expects(:dup)
  "declared with no duplicate reported"
end

# One parent config carrying `name`, with two children whose names collapse onto one property.
def assigned_ancestor(name)
  klass = Class.new do
    include Axn
    def call; end
  end
  utf8 = :café
  latin1 = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym
  klass.internal_field_configs = [Axn::Core::Contract::FieldConfig.new(field: name, reader_as: :p, default: {},
                                                                      validations: { type: { klass: Hash }, allow_nil: true })].freeze
  klass.subfield_configs = [utf8, latin1].each_with_index.map do |child, index|
    Axn::Core::Contract::FieldConfig.new(field: child, reader_as: :"c#{index}", on: :p, validations: { allow_nil: true })
  end.freeze
  klass.input_schema
  "projected with no collision reported"
end

# The collision message names the whole resolved path, so an ANCESTOR's name is rendered there as well as at its
# own node, and deriving that segment twice would be reading one name twice. A STRING ancestor is what exercises
# the memo now: an ancestor that renders through its own code is refused at its own node, which a node is always
# walked before its children makes certain — so the children's collision is never reached.
check "an ancestor's name is rendered once for the whole walk", /DuplicateFieldError.*the JSON property "p\.café"/ do
  assigned_ancestor("p")
end

check "an ancestor that renders through its own code is refused before its children are judged",
      /ArgumentError.*a name of class .* does not render through Ruby's own `to_s`/ do
  parent = Class.new do
    def initialize = @answered = false
    def to_s
      raise(NotImplementedError, "hijacked from a second #to_s") if @answered

      @answered = true
      "p"
    end
  end
  assigned_ancestor(parent.new)
end


# Bytes that are no valid Symbol either: the size guard keys a wire key by a plain COPY rather than by interning,
# so such a name reaches the rule that reports it instead of dying of EncodingError inside a guard that counts.
check "a name that is neither UTF-8 nor a valid Symbol is reported", /ArgumentError.*no.*UTF-8 rendering/ do
  assigned_projection(BAD_UTF8_NAME)
end

# The declaration path's own report: which of the two duplicate wordings a collision gets is "same raw spelling".
check "an assigned name's == cannot replace the declaration report", /DuplicateFieldError.*both render as the JSON property "dup"/ do
  klass = assigned_names(RAISING_NAME_EQ.new("dup"))
  klass.expects(:dup)
  "declared with no duplicate reported"
end

# And the same check's canonicalization, which the declaration path needs to be dispatch-free on its OWN account:
# it runs before any projection exists, so the rendering rule cannot refuse such a name here, and reading a
# String's bytes is what keeps the duplicate reportable rather than replaced by the name's exception.
check "an assigned name's to_s cannot replace the declaration report", /DuplicateFieldError.*both render as the JSON property "dup"/ do
  klass = assigned_names(RAISING_NAME_TO_S.new("dup"))
  klass.expects(:dup)
  "declared with no duplicate reported"
end

# THE MERGE, which must not change: two names that are the same content in two objects are ONE property, exactly
# as two identical spellings are. That merge is the emitter's own `properties[config.field] =` Hash.
check "two plain Strings merge onto one property", "props=1" do
  assigned_projection("dup", "dup")
end

check "two Symbols merge onto one property", "props=1" do
  assigned_projection(:dup, :dup)
end

check "two String subclass instances merge onto one property", "props=1" do
  subclass = Class.new(String)
  assigned_projection(subclass.new("dup"), subclass.new("dup"))
end

check "two String subclass instances merge outbound too", "props=1" do
  subclass = Class.new(String)
  assigned_projection(subclass.new("dup"), subclass.new("dup"), direction: :output)
end

# ---------------------------------------------------------------------------------------------------
# A name that DECIDES ITS OWN RENDERING, which is the premise the other two rules rest on. Three readers read a
# property name — the rules canonicalize a String by its BYTES, the emitter writes it into `required` through its
# `to_s`, and `JSON.generate` renders a Hash key through that same `to_s` — so a name whose bytes and rendering
# differ is two properties wearing one declaration, and every verdict about it is about a property nothing emits.
# ---------------------------------------------------------------------------------------------------

# Bytes "other", rendering "dup": `String#hash`/`eql?` (and so the emitter's own properties Hash) see one name,
# `JSON.generate` and the `required` list see the other.
MASQUERADING_NAME = Class.new(String) do
  def to_s = "dup"
end

# What the encoder would emit for a projection, which is where this defect was visible and the schema Hash is not:
# two keys that a Hash holds apart and JSON renders alike.
def emitted_json(klass, direction: :input)
  JSON.generate(direction == :input ? klass.input_schema : klass.output_schema)
end

check "two names emitting one JSON property through the encoder are refused (inbound)",
      /ArgumentError.*a field name becomes a JSON property name, and "other" does not render through Ruby's own `to_s`/ do
  emitted_json(assigned_names(MASQUERADING_NAME.new("other"), :dup))
end

check "the same pair outbound", /ArgumentError.*"other" does not render through Ruby's own `to_s`/ do
  emitted_json(assigned_names(MASQUERADING_NAME.new("other"), :dup, direction: :output), direction: :output)
end

check "the same name on the render path, which builds no schema of its own",
      /ArgumentError.*does not render through Ruby's own `to_s`/ do
  klass = assigned_names(MASQUERADING_NAME.new("other"), direction: :output)
  Axn::Extensions::Serialization.render(klass.call).inspect
end

# No second declaration is needed for the name to be undecidable, so none is needed to refuse it: alone, this name
# emitted a `required` entry for a property its own `properties` map does not define.
check "a lone such name is refused too", /ArgumentError.*does not render through Ruby's own `to_s`/ do
  assigned_projection(MASQUERADING_NAME.new("other"))
end

check "one whose rendering happens to agree with its bytes is refused as well",
      /ArgumentError.*does not render through Ruby's own `to_s`/ do
  assigned_projection(MASQUERADING_NAME.new("dup"))
end

# The OBJECT, not the class: Ruby stores a plain String Hash key as a frozen copy of its bytes, so a singleton
# `to_s` never reached the emitted property — it diverted the `required` entry alone, and the schema then required
# a property it does not define. Both artifacts read the one name one way now.
check "a plain String carrying a singleton to_s: required and properties name one property", 'props=["other"] required=["other"]' do
  name = "other".dup
  name.define_singleton_method(:to_s) { "dup" }
  klass = Class.new do
    include Axn
    def call; end
  end
  klass.internal_field_configs = [Axn::Core::Contract::FieldConfig.new(field: name, reader_as: :held, validations: { presence: true })].freeze
  schema = klass.input_schema
  "props=#{schema[:properties].keys.map { |key| String.new(key) }.inspect} required=#{schema[:required].inspect}"
end

# The complement, and why the rule asks about the `to_s` rather than about the CLASS: a String subclass that has
# not redefined `to_s` renders its own bytes, so it names exactly one property and is as good a name as a plain
# String — including in the merges and collisions it takes part in (the four merge rows below are the same point).
check "a String subclass that has not redefined to_s is unaffected", 'props=["other"] required=["other"]' do
  klass = Class.new do
    include Axn
    def call; end
  end
  klass.internal_field_configs = [Axn::Core::Contract::FieldConfig.new(field: Class.new(String).new("other"), reader_as: :held,
                                                                      validations: { presence: true })].freeze
  schema = klass.input_schema
  "props=#{schema[:properties].keys.map { |key| String.new(key) }.inspect} required=#{schema[:required].inspect}"
end

check "such a subclass still collides with a Symbol naming the same property", /DuplicateFieldError.*"dup" and :dup both resolve to the JSON property "dup"/ do
  assigned_projection(Class.new(String).new("dup"), :dup)
end

# WHERE the rule fires is where the emitter keys a property by the name ITSELF, and that is the top level only. A
# SUBFIELD's wire segment is interned from the name's rendering by SubfieldTree (as a shape member's key is, and a
# `model:` route's generated id), so the emitted name is a Symbol: one property, read the same way by the schema,
# its `required` list and the encoder. Nothing to refuse, and nothing changed.
check "a subfield's name is interned into its wire segment, so there is nothing to refuse",
      'props=[:dup] required=["dup"] json={"type":"object","properties":{"dup":{"not":{"type":"null"}}},"required":["dup"]}' do
  klass = Class.new do
    include Axn
    def call; end
  end
  klass.internal_field_configs = [Axn::Core::Contract::FieldConfig.new(field: :payload, reader_as: :payload, default: {},
                                                                      validations: { type: { klass: Hash }, allow_nil: true })].freeze
  klass.subfield_configs = [Axn::Core::Contract::FieldConfig.new(field: MASQUERADING_NAME.new("other"), reader_as: :child, on: :payload,
                                                                validations: { presence: true })].freeze
  nested = klass.input_schema.dig(:properties, :payload)
  "props=#{nested[:properties].keys.inspect} required=#{nested[:required].inspect} json=#{JSON.generate(nested.slice(:type, :properties, :required))}"
end

check "a shape member's name is likewise stored as the Symbol it was judged under",
      'declared props=[:other] json={"other":{}}' do
  declare_and_reflect({ members: [duck_carrying(field: MASQUERADING_NAME.new("other"), validations: {})], container: Hash }, type: Hash)
end

# RECORDED RESIDUE, not a guarantee. The merge decision is the emitter's Hash, and `Reflection::Schema` is
# deliberately NOT one of the layers that refuse to dispatch (see AGENTS.md): a name whose `eql?` raises has no
# property map at all, and the emitter says so, exactly as a value whose `to_s` raises cannot be rendered. What
# the size guard must not do is pre-empt that with a SECOND merge decision of its own — the row below.
check "a raising eql? surfaces from the emitter, not from a guard", /NotImplementedError.*hijacked from #eql\?/ do
  assigned_projection(RAISING_NAME_EQL.new("dup"), RAISING_NAME_EQL.new("dup"))
end

check "the size guard decides wire-key ownership without asking the name", "counted" do
  configs = [RAISING_NAME_EQL.new("dup"), RAISING_NAME_EQL.new("dup")].each_with_index.map do |field, index|
    Axn::Core::Contract::FieldConfig.new(field:, reader_as: :"x#{index}", validations: { allow_nil: true })
  end
  Axn::Reflection::PropertyNames.send(:reject_oversized_schema!, configs, [], for_output: false)
  Axn::Reflection::PropertyNames.send(:reject_oversized_schema!, configs, [], for_output: true)
  "counted"
end

# RECORDED RESIDUE, not a guarantee: a member name whose `to_sym` answers with a STRING rather than a Symbol is
# converted twice — the walk judges what the first conversion returned, and `ShapeConfig` converts that answer
# again on the way into the snapshot. So the value the duplicate check compares is not always the key finally
# stored, which is the shape every other name defect in this file takes.
#
# It stays a residue because `to_sym` returning a non-Symbol breaks Ruby's own contract for the method rather than
# being an unusual-but-legitimate object: it is categorically unlike the reachable siblings that DID earn code
# here (a non-idempotent `to_s`, unrenderable bytes, a name owning its rendering, a raising `eql?`), each of which
# an ActiveSupport::SafeBuffer-shaped value or binary bytes off a file produces with nobody intending harm.
#
# The rows assert what actually happens, because the silent two-into-one collapse such a name might be expected to
# cause does NOT occur — both arrangements are refused at declaration. The message names the INTERMEDIATE rather
# than the Symbol stored, which is confusing prose for a correct verdict, and is what the second row pins.
NON_SYMBOL_TO_SYM_INNER = Class.new(String) { def to_sym = :collapsed }
NON_SYMBOL_TO_SYM = Class.new(String) { def to_sym = NON_SYMBOL_TO_SYM_INNER.new("#{self}-mid") }

def non_symbol_to_sym_members(*names)
  members = names.map { |name| Axn::Core::Contract::ShapeConfig.new(field: name, validations: {}) }
  Class.new do
    include Axn
    expects :p, type: Hash, shape: { members:, container: Hash }
    def call; end
  end
  "declared"
rescue ::Exception => e # rubocop:disable Lint/RescueException
  "#{e.class}: #{e.message[0, 60]}"
end

check "byte-distinct names whose to_sym answers a String are refused, not collapsed",
      /DuplicateFieldError/ do
  non_symbol_to_sym_members(NON_SYMBOL_TO_SYM.new("a"), NON_SYMBOL_TO_SYM.new("b"))
end

check "the refusal names the intermediate its to_sym returned, not the Symbol stored",
      /a-mid|b-mid/ do
  non_symbol_to_sym_members(NON_SYMBOL_TO_SYM.new("a"), NON_SYMBOL_TO_SYM.new("b"))
end

puts "\n#{'=' * 100}"
if $failures.empty?
  puts "ALL #{$rows} ROWS PASS"
else
  puts "#{$failures.size} of #{$rows} ROWS FAILED"
  $failures.each { |label, expected, actual| puts "  - #{label}\n      expected: #{expected.inspect}\n      actual:   #{actual.inspect}" }
end
exit($failures.empty? ? 0 : 1)
