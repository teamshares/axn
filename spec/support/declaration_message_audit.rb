# frozen_string_literal: true

require "rspec/expectations"

# Holds every declaration-time refusal the suite observes to three properties of its message, so a refusal added
# or edited anywhere is audited without anyone listing it:
#
# 1. it names the declaration it refuses — the direction and the field (`expects :company`, `exposes :total`,
#    `expects payload.company_id`, `shape member `sku` in expects :rows`) — wherever one is being declared;
# 2. it never renders a declared field as a Ruby Array inspect (`["company"]`);
# 3. it never renders a memory address (`#<Class:0x…>`), which changes on every boot.
#
# Which errors are refusals is decided where they are RAISED, not by their text: an `ArgumentError` or contract
# violation raised from `lib/` while an `expects`/`exposes` call is on the stack is tagged, with the declaration
# label current at that moment. A tagged error is judged once a spec OBSERVES it: when a `raise_error` matcher
# (or `raise_exception`, its alias, alone or in a compound) receives it — or one wrapping it as a `cause` — and,
# on Rubies that report `rescue` (3.3+), when spec code rescues it itself. An error the library rescues internally
# is never observed, so it is never mistaken for a refusal.
module DeclarationMessageAudit
  LIB = File.expand_path("../../lib", __dir__)
  CONTRACT = File.join(LIB, "axn/core/contract.rb")
  # The method frame itself — `expects`, or `Axn::Core::Contract::ClassMethods#expects` on Ruby 3.4 — never a
  # `block in`/`rescue in`/`ensure in` frame of it, so one call counts once.
  DECLARATION_METHOD = /\A(?:[\w:]+[#.])?(?:expects|exposes)\z/

  # A label in a message: `expects :v`, `exposes :"a.b"`, `expects payload.x`, or a field-name refusal raised
  # before the name could be rendered at all, which names its direction as `` `expects` ``.
  DIRECTION = /\b(?:expects|exposes) (?::|[^\s.`]+\.)|`(?:expects|exposes)`/
  ADDRESS = /0x\h{4,}/

  # How far down a `cause` chain an observed error is searched for the refusal it wraps.
  CAUSE_DEPTH = 8

  # Refusals whose subject is not the declaration being judged, so naming it would claim something false:
  # a graph walk over contract state the class already HOLDS (a config assigned onto it rather than declared),
  # and a loop of `on:` anchors, which spans several declarations at once.
  EXEMPT = [
    [%r{reached the class without being declared through `expects`/`exposes`}, "describes a graph the class holds"],
    [/\Acircular on: chain:/, "spans several declarations"],
  ].freeze

  # `current` is the label of what was being declared when the error was raised — a member's label while its
  # block is built — and `declaration` the label of the field that declaration belongs to. `current` is nil only
  # while the raising declaration's own names are not yet known (a refusal of the name itself). `frames` is how
  # many `expects`/`exposes` calls were on the stack, `depth` how many declarations `DeclarationLabel` had open:
  # unequal, the label belongs to some other declaration than the one that raised.
  Tag = Data.define(:current, :declaration, :frames, :depth)

  # Identity-keyed and held strongly for one example, then cleared. A WeakMap would hold its VALUES weakly too, so
  # a tag nothing else referenced could be collected while its error was still in flight — an error with no tag
  # is never judged, so that is a hole, not a leak.
  TAGS = {}.compare_by_identity
  # Tagged errors whose first rescue was in lib/ (internal, never a refusal a caller sees), and those already
  # judged, so a matcher and a spec's own `rescue` observing one error report it once.
  INTERNAL = {}.compare_by_identity
  JUDGED = {}.compare_by_identity
  # Errors a spec rescued itself during the current example, judged when it ends.
  OBSERVED = {}.compare_by_identity

  class << self
    # The defects a refusal's message has, given the label that was current when it was raised. A refusal must
    # name THAT declaration — the text `DeclarationLabel` holds, as a whole label — not merely something shaped
    # like one: a sibling's, an outer field's or a stale label reads just as well and points the author at the
    # wrong line. A refusal about another config (a re-anchored subfield, a crossed route) names that config as
    # well, never instead.
    def defects(message, label:, frames: nil, depth: nil)
      raise ArgumentError, "the audit was handed a blank declaration label" if !label.nil? && label.strip.empty?
      return [] if EXEMPT.any? { |pattern, _reason| message.match?(pattern) }

      found = []
      unless frames == depth
        found << "was raised by a declaration whose own label was not current (#{frames} declaration call(s) on " \
                 "the stack, #{depth} label(s) open)"
      end
      found << "renders a declared field as an Array inspect" if field_names(label).any? { |name| message.include?(%(["#{name}")) }
      found << "renders a memory address" if message.match?(ADDRESS)
      found.concat(naming_defects(message, label)) unless label.nil?
      found
    end

    def naming_defects(message, label)
      return ["does not name the declaration (direction and field) it refuses"] unless message.match?(DIRECTION)
      return ["names a declaration other than the one it refuses (#{label})"] unless names_label?(message, label)

      []
    end

    # Whether `label` occurs in `message` as a whole label: `expects :v` must not be found inside `expects :value`,
    # `expects :v.w` or `unexpects :v`, so neither neighbour may continue an identifier or a path. A `.` that
    # ends the sentence is not a path step, so it is told apart by what follows it.
    def names_label?(message, label)
      message.match?(/(?<![\w.:])#{Regexp.escape(label)}(?![\w?!=]|\.[\w"`])/)
    end

    def field_names(label)
      return [] if label.nil?

      label.scan(/`([^`]+)`|:"([^"]+)"|:([^\s,"]+)|\.([^\s,.]+)(?=,|\z)/).flatten.compact.uniq
    end

    def tag(error, current, declaration = current, frames: nil, depth: nil)
      TAGS[error] = Tag.new(current:, declaration:, frames:, depth:)
    end

    def tag_for(error) = TAGS.key?(error) ? TAGS[error] : nil

    # The refusal an observed error is or wraps: itself when tagged, else the first tagged error down its `cause`
    # chain, so a spec asserting a wrapper still has the refusal inside it judged.
    def refusal_in(error)
      CAUSE_DEPTH.times do
        return error if error.nil? || tag_for(error)

        error = error.cause
      end
      nil
    end

    # Judges one observed refusal, once. Raises the expectation failure naming the defect; anything else the
    # judging raises (an unreadable message, say) propagates too, so the audit never passes unjudged.
    def judge!(error)
      return if JUDGED.key?(error)

      JUDGED[error] = true
      tag = tag_for(error)
      message = error.message
      problems = defects(message, label: tag.current, frames: tag.frames, depth: tag.depth)
      return if problems.empty?

      raise RSpec::Expectations::ExpectationNotMetError,
            "declaration refusal #{problems.join('; ')} (declared as #{tag.current.inspect}):\n  #{message}"
    end

    # The `expects`/`exposes` calls on the stack — counted at the method axn defines them in, so a wrapper of the
    # caller's own (`def self.expects(...) = super`) does not count twice.
    def declaration_frames
      caller_locations.count { |location| location.path == CONTRACT && location.label&.match?(DECLARATION_METHOD) }
    end

    def refusal?(error)
      error.is_a?(ArgumentError) || (defined?(Axn::ContractViolation) && error.is_a?(Axn::ContractViolation))
    end

    def in_lib?(path) = path&.start_with?(LIB)
  end

  TRACE = TracePoint.new(:raise) do |tp|
    error = tp.raised_exception
    next unless DeclarationMessageAudit.in_lib?(tp.path)
    next unless DeclarationMessageAudit.refusal?(error)
    next if DeclarationMessageAudit.tag_for(error)

    frames = DeclarationMessageAudit.declaration_frames
    next if frames.zero?

    label = Axn::Core::Contract::DeclarationLabel
    DeclarationMessageAudit.tag(error, label.current, label.declaration, frames:, depth: label.depth)
  end

  # Ruby 3.3+ reports where an exception is rescued. A tagged error first rescued inside lib/ is the library's own
  # business; one first rescued anywhere else was observed by the spec (RSpec's matcher included, which also
  # judges it directly), and is judged when the example ends.
  RESCUE_TRACE = begin
    TracePoint.new(:rescue) do |tp|
      error = tp.raised_exception
      next unless DeclarationMessageAudit.tag_for(error)
      next if DeclarationMessageAudit::INTERNAL.key?(error) || DeclarationMessageAudit::JUDGED.key?(error)

      if DeclarationMessageAudit.in_lib?(tp.path)
        DeclarationMessageAudit::INTERNAL[error] = true
      else
        DeclarationMessageAudit::OBSERVED[error] = true
      end
    end
  rescue ArgumentError
    nil
  end

  # Judges the error a `raise_error` matcher received, or the refusal it wraps. Raising from here fails the example
  # with the defect named, beside whatever the matcher itself asserted about the text.
  module Matcher
    # RSpec's own signature, positional flag included.
    def matches?(given_proc, negative_expectation = false, &) # rubocop:disable Style/OptionalBooleanParameter
      result = super
      refusal = DeclarationMessageAudit.refusal_in(@actual_error)
      DeclarationMessageAudit.judge!(refusal) if refusal
      result
    end
  end
end

RSpec::Matchers::BuiltIn::RaiseError.prepend(DeclarationMessageAudit::Matcher)

RSpec.configure do |config|
  config.before(:suite) do
    DeclarationMessageAudit::TRACE.enable
    DeclarationMessageAudit::RESCUE_TRACE&.enable
  end
  config.after(:suite) do
    DeclarationMessageAudit::TRACE.disable
    DeclarationMessageAudit::RESCUE_TRACE&.disable
  end
  config.after do
    observed = DeclarationMessageAudit::OBSERVED.keys
    observed.each { |error| DeclarationMessageAudit.judge!(error) }
  ensure
    [DeclarationMessageAudit::OBSERVED, DeclarationMessageAudit::TAGS, DeclarationMessageAudit::INTERNAL,
     DeclarationMessageAudit::JUDGED].each(&:clear)
  end
end
