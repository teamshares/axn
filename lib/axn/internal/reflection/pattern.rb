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
        # because ECMA has no equivalent, needs a flag to enable one, or matches a DIFFERENT set of characters:
        # `Z` (end-or-before-final-newline), `h`/`H` (hex digit), `p`/`P` (needs the `u` flag), `G`/`K`
        # (match-start / keep), `R`/`X` (linebreak / grapheme), `g`/`k` (subexpression call / named
        # backreference), `e`/`a` (escape / bell), `o` (braced octal), `M`/`C` (meta / control), and — the one
        # that looks safe and is not — `s`/`S`: Ruby's `\s` is the ASCII whitespace set while ECMA's also
        # includes NBSP, the Unicode Zs category and the line/paragraph separators, so emitting it would accept
        # strings the runtime rejects. `d`/`D` and `w`/`W` ARE the same set in both and stay.
        #
        # `.` is a knowing exception rather than an oversight: ECMA's excludes `\r` and U+2028/9 where Ruby's
        # excludes only `\n`, so an emitted `.` matches FEWER strings — stricter, the licensed direction, and
        # standing down on it would cost the keyword for most real patterns.
        # `x` and `0` are absent for a UNIT difference rather than a syntax one, found by sweeping this list
        # rather than by a review: Ruby reads `\xHH` as a BYTE and ECMA as a CHARACTER, so `/\xC3\xA9/` matches
        # the single character "é" in Ruby while the same source as an ECMA pattern means the two characters
        # "Ã©" — wrong in both directions at once. `\0` is Ruby's octal escape (`\012` is a newline), whose
        # ECMA reading is a legacy form or an error. `\uHHHH` names the same codepoint in both and stays; its
        # braced `\u{…}` form is refused separately, ECMA needing the `u` flag for that one.
        #
        # Numeric BACKREFERENCES are absent for a semantic difference, not a syntactic one: where the referenced
        # group did not participate in the match, Ruby fails the backreference and ECMA matches the empty string
        # — so `/\A(a|(b))\2c\z/` rejects `"ac"` in Ruby and an emitted `^(a|(b))\2c$` accepts it. Proving
        # participation would mean parsing the alternation, so they stand down instead.
        SAFE_ESCAPES = Set.new(
          %w[A z d D w W b B n r t f v u] +
          %w[. * + ? ( ) [ ] { } | ^ $ / \\ -],
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

        # The flags that change what the source MEANS, and so have no faithful `pattern` translation: `i` and
        # `x` have no spelling there at all, Ruby's `m` is ECMA's `s` rather than its `m`, and `n`
        # (NOENCODING) matches BYTES rather than characters where a `pattern` is a Unicode string.
        #
        # `FIXEDENCODING` is deliberately absent. Ruby sets it on ANY non-ASCII regex, so refusing it refused
        # every accented or non-Latin pattern — and it pins the regex's encoding without saying anything about
        # matching, which a Unicode `pattern` carries faithfully.
        SEMANTIC_FLAGS = ::Regexp::IGNORECASE | ::Regexp::EXTENDED | ::Regexp::MULTILINE | ::Regexp::NOENCODING

        module_function

        # The ECMA-262 pattern for a declared `format:` entry's regex, or nil to emit nothing.
        def ecma_source(regexp)
          return nil unless Internal::Identity.kind?(regexp, ::Regexp)
          return nil unless regexp.options.nobits?(SEMANTIC_FLAGS)

          source = regexp.source
          # The guard patterns below are UTF-8, so matching them against a source in an incompatible encoding
          # raises `Encoding::CompatibilityError` — and this runs inside schema building, where a raise breaks
          # reflection outright rather than degrading it. A source that is ASCII-only is safe whatever its
          # encoding claims; a valid UTF-8 one is safe; anything else stands down, which is what an
          # untranslatable pattern gets anyway.
          return nil unless translatable_encoding?(source)
          return nil if RUBY_ONLY_CONSTRUCTS.match?(source)
          return nil unless escapes_translatable?(source)
          return nil unless braces_are_quantifiers?(source)

          translate_anchors(source)
        end

        # Whether the source can be inspected by the UTF-8 guard patterns at all. `ascii_only?` covers every
        # ordinary pattern regardless of the Regexp's declared encoding; beyond that only valid UTF-8 is safe to
        # match. An invalid byte sequence is refused for the same reason — `match?` raises on one.
        def translatable_encoding?(source)
          return true if source.ascii_only?

          source.encoding == ::Encoding::UTF_8 && source.valid_encoding?
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
