# frozen_string_literal: true

# A caller's `format:` value decides nothing about its own type here — `Regexp#===` is C-level and runs none
# of the object's code, which `Internal::Identity.kind?` is the seam for.
require "axn/internal/identity"

module Axn
  module Internal
    module Reflection
      # A declared `format:` regex as a JSON Schema `pattern`, or nothing.
      #
      # `pattern` is an **ECMA-262 source with no flags available**, and a Ruby Regexp is neither: Ruby carries
      # flags that ECMA spells differently or not at all, and its source may use constructs ECMA has no form
      # for. So a faithful translation is only sometimes possible.
      #
      # The asymmetry that decides the whole design: **standing down is free, a false emit is not.** Emitting
      # nothing is where the emitter started (a declared `format:` reflected nowhere), so a missed translation
      # costs only the keyword; a pattern that means something OTHER than the regex it came from publishes a
      # contract axn does not enforce. Every judgment here therefore errs toward nil, and the escape set is an
      # ALLOWLIST rather than a list of known-bad escapes — an escape nobody thought about stands down instead
      # of passing through.
      module Pattern
        # The escapes that mean the same thing in both dialects. `A`/`z` are Ruby-only and TRANSLATED below
        # rather than passed through; they are listed because they are legal input. Absent on purpose, each
        # because ECMA has no equivalent or needs a flag to enable one: `Z` (end-or-before-final-newline),
        # `h`/`H` (hex digit), `p`/`P` (needs the `u` flag), `G`/`K` (match-start / keep), `R`/`X` (linebreak /
        # grapheme), `g`/`k` (subexpression call / named backreference), `e`/`a` (escape / bell), `o` (braced
        # octal), `M`/`C` (meta / control).
        SAFE_ESCAPES = Set.new(
          %w[A z d D w W s S b B n r t f v 0 x u] +
          %w[. * + ? ( ) [ ] { } | ^ $ / \\ -] +
          %w[1 2 3 4 5 6 7 8 9],
        ).freeze

        # Constructs with no ECMA form, checked against the source rather than the escape set because each is a
        # GROUP or QUANTIFIER shape rather than a single escape. A false positive here is free (it stands down),
        # which is why `&&` is matched anywhere rather than only inside a character class.
        RUBY_ONLY_CONSTRUCTS = /
          \(\?[\#>~']       | # comment, atomic group, absence operator, quote-named capture
          \(\?<[^=!]        | # named capture — the lookbehinds `(?<=` and `(?<!` are shared, and pass
          \(\?[imxdau-]     | # inline flag group
          \(\?\(            | # conditional
          \[\[:             | # POSIX bracket class
          &&                | # character-class intersection
          [*+?}]\+          | # possessive quantifier
          \\[xu]\{            # braced escape, which ECMA needs the `u` flag for
        /x
        private_constant :RUBY_ONLY_CONSTRUCTS

        A_QUANTIFIER = /\{\d+(?:,\d*)?\}/
        private_constant :A_QUANTIFIER

        module_function

        # The ECMA-262 pattern for a declared `format:` entry's regex, or nil to emit nothing.
        def ecma_source(regexp)
          return nil unless Internal::Identity.kind?(regexp, ::Regexp)
          # Any flag at all: `i` and `x` have no `pattern` spelling, Ruby's `m` is ECMA's `s` rather than its
          # `m`, and the encoding bits are not worth reasoning about for the sake of a rare declaration.
          return nil unless regexp.options.zero?

          source = regexp.source
          return nil if RUBY_ONLY_CONSTRUCTS.match?(source)
          return nil unless escapes_translatable?(source)
          return nil unless braces_are_quantifiers?(source)

          translate_anchors(source)
        end

        # Every `\X` in the source, left to right. `scan` consumes each escape pair before looking further, so
        # `\\d` (an escaped backslash then a literal `d`) reports `\` rather than `d` — the reading that
        # matters, since the second character is not an escape at all.
        def escapes_translatable?(source)
          source.scan(/\\(.)/m).all? { |(char)| SAFE_ESCAPES.include?(char) }
        end

        # A `{` that is not a well-formed quantifier is a literal brace in Ruby and a parse hazard in a strict
        # ECMA engine, so it stands down rather than risk a document a consumer's validator errors on. Escapes
        # are stripped first, so an escaped `\{` is not mistaken for one.
        def braces_are_quantifiers?(source)
          bare = source.gsub(/\\./m, "")
          !bare.gsub(A_QUANTIFIER, "").match?(/[{}]/)
        end

        # `\A`/`\z` become `^`/`$`, which is EXACT rather than approximate: ECMA's `^`/`$` mean start/end of
        # input whenever no `m` flag is set, and a `pattern` can never set one.
        #
        # Accepted only as a leading `\A` and a trailing `\z` — the idiom this exists for. Anywhere else (inside
        # an alternation, inside a character class, where `[\A]` would translate to a negated empty class) the
        # position would have to be tracked to translate safely, so it stands down instead.
        #
        # A Ruby `^`/`$` in the source is passed through untranslated, and that is a deliberate narrowing rather
        # than an oversight: Ruby's are ALWAYS line anchors while ECMA's are input anchors here, so the emitted
        # pattern matches a subset of what the runtime accepts. Stricter is the direction reflection is
        # documented to err in.
        def translate_anchors(source)
          body = source.delete_prefix("\\A").delete_suffix("\\z")
          return nil if body.match?(/\\[Az]/)

          "#{'^' if source.start_with?('\\A')}#{body}#{'$' if source.end_with?('\\z')}"
        end
      end
    end
  end
end
