# frozen_string_literal: true

require "rspec/expectations"

# Holds every declaration-time refusal the suite asserts to three properties of its message, so a refusal added
# or edited anywhere is audited without anyone listing it:
#
# 1. it names the declaration it refuses — the direction and the field (`expects :company`, `exposes :total`,
#    `expects payload.company_id`, `shape member `sku` in expects :rows`) — wherever one is being declared;
# 2. it never renders a declared field as a Ruby Array inspect (`["company"]`);
# 3. it never renders a memory address (`#<Class:0x…>`), which changes on every boot.
#
# Which errors are refusals is decided where they are RAISED, not by their text: an `ArgumentError` or contract
# violation raised from `lib/` while an `expects`/`exposes` call is on the stack is tagged, with the declaration
# label current at that moment. Only an error a `raise_error` matcher then receives is judged — one the library
# raised and rescued internally never reaches a matcher, so it is never mistaken for a refusal.
module DeclarationMessageAudit
  LIB = File.expand_path("../../lib", __dir__)

  # A label in a message: `expects :v`, `exposes :"a.b"`, `expects payload.x`, or a field-name refusal raised
  # before the name could be rendered at all, which names its direction as `` `expects` ``.
  DIRECTION = /\b(?:expects|exposes) (?::|[^\s.`]+\.)|`(?:expects|exposes)`/
  ADDRESS = /0x\h{4,}/

  # Refusals whose subject is not the declaration being judged, so naming it would claim something false:
  # a graph walk over contract state the class already HOLDS (a config assigned onto it rather than declared),
  # and a loop of `on:` anchors, which spans several declarations at once.
  EXEMPT = [
    [%r{reached the class without being declared through `expects`/`exposes`}, "describes a graph the class holds"],
    [/\Acircular on: chain:/, "spans several declarations"],
  ].freeze

  # `current` is the label of what was being declared when the error was raised — a member's label while its
  # block is built — and `declaration` the label of the field that declaration belongs to.
  Tag = Data.define(:current, :declaration)

  TAGS = ObjectSpace::WeakMap.new

  class << self
    # The defects a refusal's message has, given the label that was current when it was raised. A refusal must
    # name THAT declaration — the text `DeclarationLabel` holds, verbatim — not merely something shaped like one:
    # a sibling's, an outer field's or a stale label reads just as well and points the author at the wrong line.
    # A refusal about another config (a re-anchored subfield, a crossed route) names that config as well, never
    # instead.
    def defects(message, label:)
      return [] if EXEMPT.any? { |pattern, _reason| message.match?(pattern) }

      found = []
      found << "renders a declared field as an Array inspect" if field_names(label).any? { |name| message.include?(%(["#{name}")) }
      found << "renders a memory address" if message.match?(ADDRESS)
      found.concat(naming_defects(message, label)) unless label.nil?
      found
    end

    def naming_defects(message, label)
      return ["does not name the declaration (direction and field) it refuses"] unless message.match?(DIRECTION)
      return ["names a declaration other than the one it refuses (#{label})"] unless message.include?(label)

      []
    end

    def field_names(label)
      return [] if label.nil?

      label.scan(/`([^`]+)`|:"([^"]+)"|:([^\s,"]+)|\.([^\s,.]+)(?=,|\z)/).flatten.compact.uniq
    end

    def tag(error, current, declaration = current) = TAGS[error] = Tag.new(current:, declaration:)

    def tag_for(error) = TAGS.key?(error) ? TAGS[error] : nil

    def under_declaration?
      caller_locations.any? { |location| location.path&.start_with?(LIB) && %w[expects exposes].include?(location.base_label) }
    end

    def refusal?(error)
      error.is_a?(ArgumentError) || (defined?(Axn::ContractViolation) && error.is_a?(Axn::ContractViolation))
    end
  end

  TRACE = TracePoint.new(:raise) do |tp|
    error = tp.raised_exception
    next unless tp.path&.start_with?(LIB)
    next unless DeclarationMessageAudit.refusal?(error)
    next if DeclarationMessageAudit.tag_for(error)
    next unless DeclarationMessageAudit.under_declaration?

    label = Axn::Core::Contract::DeclarationLabel
    DeclarationMessageAudit.tag(error, label.current, label.declaration)
  end

  # Judges the error a `raise_error` matcher received. Raising from here fails the example with the defect named,
  # beside whatever the matcher itself asserted about the text. Nothing is rescued: an audit that cannot read the
  # message, or breaks judging it, fails the example rather than passing it unjudged.
  module Matcher
    # RSpec's own signature, positional flag included.
    def matches?(given_proc, negative_expectation = false, &) # rubocop:disable Style/OptionalBooleanParameter
      result = super
      error = @actual_error
      tag = error && DeclarationMessageAudit.tag_for(error)
      audit!(error, tag) if tag
      result
    end

    private

    def audit!(error, tag)
      message = error.message
      problems = DeclarationMessageAudit.defects(message, label: tag.current)
      return if problems.empty?

      raise RSpec::Expectations::ExpectationNotMetError,
            "declaration refusal #{problems.join('; ')} (declared as #{tag.current.inspect}):\n  #{message}"
    end
  end
end

RSpec::Matchers::BuiltIn::RaiseError.prepend(DeclarationMessageAudit::Matcher)

RSpec.configure do |config|
  config.before(:suite) { DeclarationMessageAudit::TRACE.enable }
  config.after(:suite) { DeclarationMessageAudit::TRACE.disable }
end
