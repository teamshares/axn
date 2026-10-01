# frozen_string_literal: true

# LITERAL_RENDERINGS names each literal class it reads a rendering through.
require "bigdecimal"
require "date"
require "time"
# A mentioned fragment is encoded only after it has been reduced to plain primitives.
require "json"

require "axn/internal/text"
require "axn/internal/rendering"
require "axn/internal/identity"
require "axn/internal/reflection/schema/vocabulary"

module Axn
  module Internal
    module Reflection
      module Schema
        # How a residue names what it could not emit: a declined fragment rendered verbatim, a caller's literal
        # reduced to something JSON can carry without asking it anything, and an author's description closed as a
        # sentence and joined to the prose after it. Every read here is bound or guarded, so composing a report
        # never runs a caller's code.
        module Mentions
          include Vocabulary

          # The container reads the residue reduction makes, held UNBOUND. Exact class is not enough on its
          # own: an exact Array or Hash can still carry a singleton `map`/`each_pair`, so the reduction reaches
          # for Array's and Hash's own.
          MENTIONABLE_MAP = ::Array.instance_method(:map)
          MENTIONABLE_EACH_PAIR = ::Hash.instance_method(:each_pair)
          private_constant :MENTIONABLE_MAP, :MENTIONABLE_EACH_PAIR

          # The fragment a residue MENTIONS, rendered without requiring the caller's literals to be
          # JSON-encodable. They need not be: `normalize_scalar_literal` deliberately keeps a
          # `Float::INFINITY` default and its kind, so ordinary reflection does not fail on one — and a path
          # that merely NAMES such a value must not be the one that fails instead.
          def render_constraint(prop)
            # A mentioned subtree no longer participates in the final schema walk. Finalize its
            # reports now, on a copy, while schema nodes can still be distinguished from literals.
            finalized, = finalize_residues!(prop, copy: true)
            JSON.generate(json_mentionable(finalized))
          end

          # `value` reduced to something JSON can carry WITHOUT asking it anything. Reducing first rather than
          # encoding and rescuing is the point: `JSON.generate` dispatches `to_json`, so encoding a caller's
          # own object runs its code — which this layer may never do, and which a `StandardError` rescue does
          # not contain anyway (a `to_json` raising `NotImplementedError` escaped one and took `input_schema`
          # down while it was merely composing a report).
          #
          # Everything that reaches the encoder is a plain primitive: a String through `Text.renderable`, so
          # neither a subclass's `to_json` nor bytes with no UTF-8 rendering reach it, and anything else
          # through `Rendering`, whose reads are bound.
          #
          # EVERY test and read here is undispatched, because a reduction is only a defence if the reduction
          # itself runs nothing. `nil?`, `==`, `instance_of?` and `map` are all overridable by the literal, so
          # identity comes from `Identity.same?`, the class from `Identity.class_of`, and the two container
          # walks from Array's and Hash's own unbound methods. Only an EXACT built-in is traversed, the rule
          # `normalize_schema_literal` already follows: a subclass is opaque and renders as one.
          #
          # Integer/Float/Symbol need no bound read beyond the class test — none of the three can carry a
          # singleton method, so an exact one answers with its own implementation or not at all.
          def json_mentionable(value)
            return value if Axn::Internal::Identity.nil_value?(value) || Axn::Internal::Identity.same?(value, true) ||
                            Axn::Internal::Identity.same?(value, false)
            return value if exactly?(value, ::Integer)
            return value.finite? ? value : mentionable_rendering(value) if exactly?(value, ::Float)
            # `Text.renderable` reads the bytes through bound methods, so the String itself goes in — asking it
            # for `to_s` first would dispatch, which is the thing this method exists not to do.
            return Axn::Internal::Text.renderable(value) if exactly?(value, ::String)
            return Axn::Internal::Text.renderable(value.name) if exactly?(value, ::Symbol)
            return MENTIONABLE_MAP.bind_call(value) { |element| json_mentionable(element) } if exactly?(value, ::Array)
            return mentionable_pairs(value) if exactly?(value, ::Hash)
            # A declared class, named through `Module#to_s` bound rather than its own `to_s`.
            return Axn::Internal::Rendering.stable_module_name(value) if Axn::Internal::Identity.kind?(value, ::Module)

            mentionable_rendering(value)
          end

          # `value` is an instance of `klass` ITSELF, asking neither the value nor its class. A subclass
          # answers false: it may override the reads a traversal would make.
          def exactly?(value, klass) = Axn::Internal::Identity.same?(Axn::Internal::Identity.class_of(value), klass)

          # An exact Hash walked through Hash's own `each_pair`. Every reduced key is a plain primitive, so the
          # `[]=` that collects them hashes something axn built rather than something it was handed.
          def mentionable_pairs(value)
            MENTIONABLE_EACH_PAIR.bind_call(value).each_with_object({}) do |(key, nested), reduced|
              reduced[json_mentionable(key)] = json_mentionable(nested)
            end
          end

          # A callable is named by what it is, never rendered: its only rendering is an object address, which would
          # change the document on every boot.
          PER_CALL_RENDERING = "(resolved per call)"

          # The literal classes whose rendering says what the value is, each read through its OWN class's `to_s`
          # bound to the value — the exact class only, so the text is the built-in one and no override can run.
          # Anything else, a callable object included, is named by its class: its own `to_s` is caller code, which
          # reflection may never run, and Ruby's default one is an address that would change on every boot.
          LITERAL_RENDERINGS = {
            ::Float => ::Float.instance_method(:to_s), ::Regexp => ::Regexp.instance_method(:to_s),
            ::Rational => ::Rational.instance_method(:to_s), ::Complex => ::Complex.instance_method(:to_s),
            ::BigDecimal => ::BigDecimal.instance_method(:to_s), ::Date => ::Date.instance_method(:to_s),
            ::DateTime => ::DateTime.instance_method(:to_s), ::Time => ::Time.instance_method(:to_s)
          }.freeze
          RANGE_EXCLUDE_END = ::Range.instance_method(:exclude_end?)
          RANGE_BEGIN = ::Range.instance_method(:begin)
          RANGE_END = ::Range.instance_method(:end)
          private_constant :LITERAL_RENDERINGS, :RANGE_EXCLUDE_END, :RANGE_BEGIN, :RANGE_END

          def mentionable_rendering(value)
            # A String (a subclass included) is read through `Text.renderable`, whose reads are bound.
            return Axn::Internal::Text.renderable(value) if Axn::Internal::Identity.kind?(value, ::String)
            return PER_CALL_RENDERING if Axn::Internal::Identity.kind?(value, ::Proc) || Axn::Internal::Identity.kind?(value, ::Method)
            return range_rendering(value) if exactly?(value, ::Range)

            to_s = LITERAL_RENDERINGS[Axn::Internal::Identity.class_of(value)]
            return Axn::Internal::Text.renderable(to_s.bind_call(value)) if to_s

            Axn::Internal::Rendering.stable_class_name(value)
          end

          # A Range's endpoints are reduced like any other value, so an endpoint of a caller's class runs nothing.
          def range_rendering(range)
            ends = [RANGE_BEGIN.bind_call(range), RANGE_END.bind_call(range)].map do |endpoint|
              Axn::Internal::Identity.nil_value?(endpoint) ? "" : JSON.generate(json_mentionable(endpoint))
            end
            ends.join(RANGE_EXCLUDE_END.bind_call(range) ? "..." : "..")
          end

          # An authored `description:` survives a stand-down even though the declaration's constraints do not:
          # it describes the POSITION for a reader, not the value for a validator, so nothing about it is
          # untrustworthy across a transform or a closed gate. Dropping it silently lost the explicit node's
          # own prose in the ordinary case — a shape member cannot transform, so the node is nearly always the
          # side that stands down, and its description was published before this. Both are kept when both
          # exist, and an identical pair collapses.
          # Both descriptions are the AUTHOR'S OWN prose, so neither is asked anything: each is reduced through
          # the rendering seam first, and the equal-pair collapse then compares two plain Strings axn owns
          # rather than dispatching a `==` the description's class may define.
          #
          # `nil?` is overridable too, so every nil test this reporting path makes of a caller's own object —
          # here, in `carry_metadata`, and in `stand_down_from` — goes through `Identity.nil_value?`. The rule
          # is the region's, not this method's: a value reaches the guarded rendering seam WITHOUT having been
          # asked anything on the way.
          def carried_description(kept, dropped)
            return kept if Axn::Internal::Identity.nil_value?(dropped)
            return dropped if Axn::Internal::Identity.nil_value?(kept)

            kept_prose = mentionable_rendering(kept)
            dropped_prose = mentionable_rendering(dropped)
            kept_prose == dropped_prose ? kept_prose : join_prose(kept_prose, dropped_prose)
          end

          # Two pieces of prose joined through the text seam, either of which may be caller-supplied and in
          # an encoding the other cannot be concatenated with.
          #
          # Reduced through `mentionable_rendering`, never `to_s`: a String SUBCLASS description can override
          # `to_s`, and one that raises took `input_schema` down from inside the append. The seam reads a
          # String's bytes through bound methods and guards everything else.
          # An author's description, rendered, and closed as a sentence where it is not already, so the residue
          # sentence appended after it reads as its own ("ID of the User record. Additional constraints…").
          SENTENCE_END = /[.!?:;]["')\]]*\s*\z/

          def as_sentence(prose)
            return prose if Axn::Internal::Identity.nil_value?(prose)

            rendered = mentionable_rendering(prose)
            rendered.empty? || rendered.match?(SENTENCE_END) ? rendered : "#{rendered}."
          end

          def join_prose(*parts)
            rendered = parts.reject { |part| Axn::Internal::Identity.nil_value?(part) }.map { |part| mentionable_rendering(part) }
            rendered.empty? ? nil : rendered.join(" ")
          end
        end
      end
    end
  end
end
