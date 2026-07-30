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
# harness-only on purpose: the COST rows (a timing assertion belongs nowhere near CI) and the two rows that
# record a documented residue rather than a guarantee (a duck-typed member's nested shape staying aliased, and a
# non-idempotent reader splitting a guard from its consumer) — those exist to keep a claim honest, and a suite
# has nothing to assert about them.
#
# When you add a row here, ask the same question: mutate the guard it exercises, and if the suite stays green,
# the row is knowledge that dies with this file. Convert it.
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

# Reports a DIFFERENT name on each read. Nothing closes this; the row exists so no claim of
# guard/consumer agreement "by construction" survives.
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

# The control the fix must not break: the member's own class still decides membership...
check "a member subclass's own include? still decides", true do
  values = Class.new(Array) { def include?(_v) = true }.new.push("a", "b")
  klass = member_inclusion_axn({ inclusion: { in: values } })
  klass.call(payload: { choice: "z" }).ok?
end

# ...and a container whose duplication alters its elements is rejected for a member too.
check "a member container whose dup drops elements is rejected", /ArgumentError: the `inclusion: \{ in: … \}` container/ do
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

# A container is detached whatever it claims about itself and whatever its own copiers do. Three subclasses,
# three different ways of defeating the detach; the plain-Array/plain-Hash rows above are the controls.
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

check "an inclusion set denying its own class is still detached", [false, false] do
  values = Class.new(Array) { def is_a?(other) = ::Array.equal?(other) ? false : super }.new(%w[a b])
  accepts_after_mutation({ in: values }, -> { values << "c" })
end

check "an inclusion set whose dup returns self is still detached", [false, false] do
  values = Class.new(Array) { def dup = self }.new(%w[a b])
  accepts_after_mutation({ in: values }, -> { values << "c" })
end

check "a bag whose transform_values returns self is still detached", [false, false] do
  bag = Class.new(Hash) { def transform_values(&) = self }.new
  bag[:in] = %w[a b]
  accepts_after_mutation(bag, -> { bag[:in] << "c" })
end

# A same-class copy runs the container's own `initialize_dup`, so the copy is CHECKED against the original: one
# that alters the elements is rejected at declaration...
check "an inclusion set whose dup drops its elements is rejected", /ArgumentError.*does not survive being copied/ do
  values = Class.new(Array) do
    def initialize_dup(source)
      super
      clear
    end
  end.new.push("a", "b")
  begin
    inclusion_axn({ in: values }) && "declared"
  rescue ::Exception => e
    "#{e.class}: #{e.message}"
  end
end

# ...while the legitimate use of that same callback — rebuilding a derived index off the copied elements — still
# declares AND still answers membership from the rebuilt index.
check "an inclusion set that reindexes on dup still works", [true, false] do
  values = Class.new(Array) do
    def initialize_dup(source)
      super
      reindex
    end

    def reindex = @index = each_with_object({}) { |v, h| h[v] = true }

    def include?(value) = (@index || reindex).key?(value)
  end.new.push("x", "y")
  klass = inclusion_axn({ in: values })
  [klass.call(choice: "x").ok?, klass.call(choice: "z").ok?]
end

# ...and the copy does not over-reach: an Array's own `include?` IS how an inclusion set answers membership, so
# the stored copy keeps the caller's class (and reflection still withholds an enum for anything but an exact
# Array).
check "a subclass's own membership behavior survives the copy", [true, nil] do
  values = Class.new(Array) { def include?(_v) = true }.new(%w[a b])
  klass = inclusion_axn({ in: values })
  [klass.call(choice: "c").ok?, klass.input_schema.dig(:properties, :choice, :enum)]
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

check "a String-keyed member's metadata is read", "the a" do
  m = SC.new(field: :a, validations: {}, metadata: { "description" => "the a" })
  klass = expects_axn({ members: [m], container: Hash }, type: Hash)
  klass.input_schema.dig(:properties, :payload, :properties, :a, :description)
end

# The snapshot's bounded residue, recorded rather than implied away: a duck-typed member is the caller's own
# object and cannot be rebuilt, so a nested shape it carries stays aliased and CAN still be mutated after
# declaration. A ShapeConfig member (what the block form and every documented example produce) is rebuilt.
check "a duck-typed member's nested shape stays aliased — the documented residue", [%i[deep], %i[deep sneaked]] do
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
# it. The deep snapshot closed the hostile-`each` half of this outright — every walk after declaration iterates
# axn's own copy — leaving only a duck-typed member's READERS, which the snapshot cannot rebuild. A reader that
# breaks during a REQUIRED read has no schema to judge, so its own error is honest; one that breaks during
# attribution must degrade instead.
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

# A duck-typed member is not rebuilt by the snapshot, so its readers stay caller code in the stored contract.
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

# A required read cannot produce a schema, so the reader's own error is the honest outcome.
check "a reader that breaks during the schema build raises its own error", /NotImplementedError: read 2/ do
  verdict_when_reader_breaks_on(2)
end

# The collision is already proven here; attribution must not replace it.
check "a reader that breaks during attribution still reports the collision", /DuplicateFieldError/ do
  verdict_when_reader_breaks_on(3)
end

check "and that report degrades to the property rather than going silent", /both resolve to the JSON property/ do
  verdict_when_reader_breaks_on(3)
end

# When attribution survives, the message keeps its full source-naming form.
check "attribution that survives still names both sources", /Duplicate shape member declared/ do
  verdict_when_reader_breaks_on(9)
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

check "boot validates a shadowing tool's INBOUND contract",
      /readers shadowed=true; boot: Axn::DuplicateFieldError: BootShadowInbound has an invalid tool contract/ do
  boot_verdict("BootShadowInbound", inbound: true)
end

check "boot validates a shadowing tool's OUTBOUND contract too",
      /readers shadowed=true; boot: Axn::DuplicateFieldError: BootShadowOutbound has an invalid tool contract/ do
  boot_verdict("BootShadowOutbound", inbound: false)
end

# ---------------------------------------------------------------------------------------------------
puts "\n== a graph that becomes cyclic AFTER it is declared ====================================="
# ---------------------------------------------------------------------------------------------------

# The documented duck-typed residue at its sharpest: the member is stored by reference, so its nested shape
# can be pointed back at itself once the class is declared. Every projection walks it, and SystemStackError
# escapes every rescue meant to settle a result — so the walk is guarded and reports the cycle the way the
# declaration-time guard does.
def cyclic_after_declaration
  member = Class.new do
    attr_accessor :validations

    def initialize = @validations = { type: { klass: Hash }, shape: { members: [], container: Hash } }
    def field = :outer
  end.new
  member.validations[:shape][:members] << SC.new(field: :inner, validations: {})
  klass = Class.new do
    include Axn
    expects :payload, type: Hash, shape: { members: [member], container: Hash }
    exposes :out, type: Hash, shape: { members: [member], container: Hash }
    def call = expose(out: {})
  end
  [member, klass]
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
  klass = Class.new do
    include Axn
    expects :payload, type: Hash, shape: { members: [member], container: Hash }
    exposes :out, type: Hash, shape: { members: [member], container: Hash }
    def call = expose(out: {})
  end
  [member, klass]
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

# Declaring a LATER ambient subfield re-walks every ambient config's shape, so a graph mutated since its own
# declaration reaches that walk. Both halves, both bounded.
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
    expects :request, on: :ambient_context, type: Hash, shape: { members: [member], container: Hash }
    def call; end
  end
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

# ---------------------------------------------------------------------------------------------------
puts "\n== documented limit: NOT closed, recorded so a claim about it stays honest =============="
# ---------------------------------------------------------------------------------------------------

# A reader reporting a different name on each read splits the guard from its consumer whichever single
# read either makes. Recorded, not fixed: the honest claim is "a reachable reader is read the way
# reflection reads it", not "the two agree by construction".
check "non-idempotent reader: still splits guard from consumer", /declared props=\[:collide\]/ do
  members = [DRIFTING.new, DRIFTING.new]
  declare_and_reflect({ members:, container: Hash }, type: Hash)
end

puts "\n#{'=' * 100}"
if $failures.empty?
  puts "ALL #{$rows} ROWS PASS"
else
  puts "#{$failures.size} of #{$rows} ROWS FAILED"
  $failures.each { |label, expected, actual| puts "  - #{label}\n      expected: #{expected.inspect}\n      actual:   #{actual.inspect}" }
end
exit($failures.empty? ? 0 : 1)
