# frozen_string_literal: true

module Axn
  # The public-error boundary, as a MODULE rather than a base class: `rescue` matches a module by
  # `is_a?`, so tagging a class gives callers `rescue Axn::Error` without touching its ancestry.
  #
  # That is what makes the tag usable everywhere it needs to be. Four core errors are deliberately
  # `ArgumentError`s, and an adapter gem may need its own base to be a `Faraday::Error` or a
  # `Timeout::Error` for its ecosystem's interop — a base class would force each of them to choose
  # between the superclass they need and being catchable as an axn error. A module forces nothing.
  #
  # Inclusion IS the boundary declaration, not a blanket sweep over everything axn raises: a class
  # that includes this is public, documented, rescuable, and breaking to remove, and one that does not
  # is either internal or (in the single case of `Axn::Failure`) deliberately excluded. That makes the
  # boundary per-class and explicit rather than inferred from which directory a file sits in, and
  # `spec/axn/error_policy_spec.rb` pins the exact partition so neither an untagged public error nor a
  # tagged internal one can land.
  #
  # `Axn::Failure` is the deliberate exclusion. It is a control-flow signal raised by `call!`, not a
  # fault, so tagging it would make `rescue Axn::Error` around a `call!` catch the INTENDED outcome
  # while still missing an unintended `NoMethodError` from the action body — a net whose partiality is
  # the confusing part. Untagged, the three outcomes stay legible: `Axn::Error` means axn objected,
  # `Axn::Failure` means the action deliberately failed, anything else means the body blew up. A caller
  # who wants all three writes `rescue StandardError`.
  #
  # A gem building on axn roots its own hierarchy here:
  #
  #   module Axn::Webhooks
  #     class Error < StandardError
  #       include Axn::Error
  #     end
  #     class RetryLater < Error; end
  #   end
  #
  # The tag is inherited, so a tagged class cannot have an untagged subclass. That is deliberate: a
  # public error family should not have secretly-internal members.
  module Error; end
end
