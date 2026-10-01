# frozen_string_literal: true

require "active_support/inflector"

# Declares ActiveSupport acronyms for the duration of the block, as a host app's initializer would, and puts the
# process-wide inflections back afterwards so no other example sees them.
module WithAcronyms
  def with_acronyms(*words)
    inflections = ActiveSupport::Inflector.inflections(:en)
    saved = inflections.acronyms.dup
    words.each { |word| inflections.acronym(word) }
    yield
  ensure
    inflections.instance_variable_set(:@acronyms, saved)
    inflections.send(:define_acronym_regex_patterns)
  end
end

RSpec.configure { |config| config.include WithAcronyms }
