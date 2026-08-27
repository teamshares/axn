# frozen_string_literal: true

require "spec_helper"

# PRO-3192 made `of:` the documented remedy for constraints it refuses at a container position — its two
# refusal messages, `AGENTS.md`, `docs/reference/class.md` and the CHANGELOG all point here. This is that
# remedy: an `of:` bag carries the value constraints for the position it describes.
#
# The whitelist is DERIVED, not listed: a position offers a value and nothing else, so the validators refused
# are exactly those that read something a position has not got (a name, a sibling reader, a record). And an
# admitted validator is then held to PRO-3192's own two guards with `klass:` in `type:`'s role, so one rule
# covers the field and all three bag positions rather than a second table that can drift from the first.
RSpec.describe "value validators in an of: bag" do
  describe "an Array's element position" do
    it "constrains each element with format:" do
      action = build_axn { expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]{2}\z/ } } }

      expect(action.call(codes: %w[US GB])).to be_ok
      expect(action.call(codes: %w[US usa])).not_to be_ok
    end

    it "names the failing element by its position" do
      action = build_axn { expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]{2}\z/ } } }

      expect(action.call(codes: %w[US usa]).exception.message).to include("element at index 1")
    end

    it "constrains each element with inclusion:" do
      action = build_axn { expects :tags, type: Array, of: { klass: String, inclusion: { in: %w[a b] } } }

      expect(action.call(tags: %w[b a])).to be_ok
      expect(action.call(tags: %w[a zzz])).not_to be_ok
    end

    # The distributing reading PRO-3192 retired at the FIELD level, now available where it has a rule.
    it "constrains each element with exclusion:, which the field level could not do correctly" do
      action = build_axn { expects :roles, type: Array, of: { klass: String, exclusion: { in: %w[admin] } } }

      expect(action.call(roles: %w[member])).to be_ok
      expect(action.call(roles: %w[admin])).not_to be_ok
      # The bug that made the field-level reading nonsense: `all?` under a negating caller meant "reject only
      # when EVERY element is forbidden", so one forbidden element among legal ones passed.
      expect(action.call(roles: %w[member admin])).not_to be_ok
    end

    it "constrains each element with numericality:" do
      action = build_axn { expects :qtys, type: Array, of: { klass: Integer, numericality: { greater_than: 0 } } }

      expect(action.call(qtys: [1, 2])).to be_ok
      expect(action.call(qtys: [1, -1])).not_to be_ok
    end

    it "constrains each element's own length, not the array's" do
      action = build_axn { expects :codes, type: Array, of: { klass: String, length: { maximum: 2 } } }

      expect(action.call(codes: %w[ab cd ef])).to be_ok
      expect(action.call(codes: %w[abc])).not_to be_ok
    end

    it "constrains each element with presence:" do
      action = build_axn { expects :names, type: Array, of: { klass: String, presence: true } }

      expect(action.call(names: %w[a])).to be_ok
      expect(action.call(names: ["a", ""])).not_to be_ok
    end

    it "constrains each element with a validate: callable" do
      action = build_axn do
        expects :codes, type: Array, of: { klass: String, validate: ->(v) { "must be shouty" unless v == v.upcase } }
      end

      expect(action.call(codes: %w[US])).to be_ok
      expect(action.call(codes: %w[us])).not_to be_ok
      expect(action.call(codes: %w[us]).exception.message).to include("must be shouty")
    end

    # The whitelist is DERIVED, so every admitted validator is admitted at every position whether or not
    # anyone wrote an example. These three close the audit: each is exercised at a position, and the ones with
    # no honest keyword are asserted to emit nothing rather than left to be discovered.
    it "constrains each element with comparison:" do
      action = build_axn { expects :f, type: Array, of: { klass: Integer, comparison: { greater_than: 0 } } }

      expect(action.call(f: [1])).to be_ok
      expect(action.call(f: [0])).not_to be_ok
      expect(action.input_schema.dig(:properties, :f, :items)).to include(exclusiveMinimum: 0)
    end

    it "constrains each element with absence:, and emits no keyword for it" do
      action = build_axn { expects :f, type: Array, of: { klass: String, absence: true } }

      expect(action.call(f: [""])).to be_ok
      expect(action.call(f: ["a"])).not_to be_ok
      # `maxLength: 0` / `const: null` would depend on the position's type and collides with the emptiness
      # axis, which is PRO-3220's subject — so this stays unemitted, as at a field.
      expect(action.input_schema.dig(:properties, :f, :items)).to eq(type: "string")
    end

    it "constrains each element with acceptance:, and emits no keyword for it" do
      action = build_axn { expects :f, type: Array, of: { klass: String, acceptance: { accept: %w[yes] } } }

      expect(action.call(f: %w[yes])).to be_ok
      expect(action.call(f: %w[no])).not_to be_ok
      expect(action.input_schema.dig(:properties, :f, :items)).to eq(type: "string")
    end

    it "constrains a klass-less bag, leaving the element's class open" do
      action = build_axn { expects :tags, type: Array, of: { inclusion: { in: ["a", 1] } } }

      expect(action.call(tags: ["a"])).to be_ok
      expect(action.call(tags: [1])).to be_ok
      expect(action.call(tags: ["z"])).not_to be_ok
    end

    it "runs the type check and the value constraint together" do
      action = build_axn { expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]+\z/ } } }

      expect(action.call(codes: [1]).exception.message).to include("is not a String")
    end
  end

  describe "a map's values: axis" do
    it "constrains every value" do
      action = build_axn { expects :counts, type: Hash, of: { values: { klass: Integer, numericality: { greater_than: 0 } } } }

      expect(action.call(counts: { a: 1 })).to be_ok
      expect(action.call(counts: { a: -1 })).not_to be_ok
    end

    # A map entry is located by its ORDINAL at every depth: a validation message settles unredacted, so
    # rendering the key would publish exactly what a `sensitive:` declaration asks to be masked.
    it "names the failing value by its ordinal, never its key" do
      action = build_axn { expects :counts, type: Hash, of: { values: { klass: Integer, numericality: { greater_than: 0 } } } }

      message = action.call(counts: { secret_key: -1 }).exception.message
      expect(message).to include("value at index 0")
      expect(message).not_to include("secret_key")
    end
  end

  describe "a map's keys: axis" do
    it "constrains every key" do
      action = build_axn { expects :m, type: Hash, of: { keys: { klass: Symbol, inclusion: { in: %i[a b] } }, values: Integer } }

      expect(action.call(m: { a: 1 })).to be_ok
      expect(action.call(m: { z: 1 })).not_to be_ok
    end

    it "names the failing key by its ordinal" do
      action = build_axn { expects :m, type: Hash, of: { keys: { klass: String, format: { with: /\A[a-z]+\z/ } }, values: Integer } }

      expect(action.call(m: { "AB" => 1 }).exception.message).to include("key at index 0")
    end
  end

  describe "a nested bag, at depth 2" do
    it "constrains an element of an element" do
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: String, format: { with: /\Ax/ } } } }

      expect(action.call(m: [%w[xa xb]])).to be_ok
      expect(action.call(m: [%w[xa yb]])).not_to be_ok
    end

    it "composes one position per level in the message" do
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: String, format: { with: /\Ax/ } } } }

      message = action.call(m: [%w[xa yb]]).exception.message
      expect(message).to include("element at index 0")
      expect(message).to include("element at index 1")
    end

    it "constrains a map value inside an array element" do
      action = build_axn { expects :m, type: Array, of: { klass: Hash, of: { values: { klass: Integer, numericality: { greater_than: 0 } } } } }

      expect(action.call(m: [{ a: 1 }])).to be_ok
      expect(action.call(m: [{ a: -1 }])).not_to be_ok
    end
  end

  # A bag's OWN keys were already canonicalized at every rung (PRO-3166). A validator entry carries an option
  # bag of its own, and ActiveModel reads THOSE keys as Symbols too — a String-keyed `"with"` reaches
  # `FormatValidator#check_validity!` as no `:with` at all and raises on every call. The field path
  # canonicalizes them; a bag position is held to the same grammar by the same seam.
  describe "option-key canonicalization inside a bag's validators" do
    it "accepts a String-keyed validator option bag" do
      action = build_axn { expects :f, type: Array, of: { klass: String, format: { "with" => /\A[A-Z]+\z/ } } }

      expect(action.call(f: %w[AB])).to be_ok
      expect(action.call(f: %w[ab])).not_to be_ok
      expect(action.call(f: %w[ab]).exception).to be_a(Axn::InboundValidationError)
    end

    it "accepts an indifferent-access bag, the form a Rails author hands in" do
      action = build_axn do
        expects :f, type: Array, of: { klass: String, format: { with: /\A[A-Z]+\z/ } }.with_indifferent_access
      end

      expect(action.call(f: %w[AB])).to be_ok
      expect(action.call(f: %w[ab])).not_to be_ok
    end

    it "canonicalizes at a map axis" do
      action = build_axn do
        expects :f, type: Hash, of: { values: { klass: Integer, numericality: { "greater_than" => 0 } } }
      end

      expect(action.call(f: { a: 1 })).to be_ok
      expect(action.call(f: { a: -1 })).not_to be_ok
    end

    it "canonicalizes at a nested bag" do
      action = build_axn do
        expects :f, type: Array, of: { klass: Array, of: { klass: String, format: { "with" => /\Ax/ } } }
      end

      expect(action.call(f: [%w[xa]])).to be_ok
      expect(action.call(f: [%w[ya]])).not_to be_ok
    end

    # Canonicalizing writes back into the bag, so it has to write a NEW Hash rather than convert the caller's
    # in place — the aliasing rule `detach_option_containers!` exists for, applied to the one container this
    # step reaches that no earlier step did: a validator entry's own option bag.
    it "leaves the caller's validator option bag unmutated" do
      option_bag = { "with" => /\A[A-Z]+\z/ }
      build_axn { expects :f, type: Array, of: { klass: String, format: option_bag } }

      expect(option_bag).to eq("with" => /\A[A-Z]+\z/)
    end

    it "does not carry a later mutation of that bag into the declared contract" do
      option_bag = { "with" => /\A[A-Z]+\z/ }
      action = build_axn { expects :f, type: Array, of: { klass: String, format: option_bag } }
      option_bag["with"] = /\A\d+\z/

      expect(action.call(f: %w[AB])).to be_ok
      expect(action.call(f: %w[12])).not_to be_ok
    end

    # The symbolizer only builds a new Hash when a key actually needs converting, so the ORDINARY symbol-keyed
    # spelling took its no-op path and the caller's option bag was stored by reference — "nothing needs
    # changing" answering a different question from "nothing needs copying", which is the aliasing rule
    # verbatim. The field path escapes it because `detach_option_containers!` reaches its entries directly;
    # a bag's entries are one level further down, where `detached_option_bag` copies a nested HASH by
    # reference (it detaches nested Arrays only).
    it "detaches a Symbol-keyed option bag, whose keys need no conversion" do
      opts = { in: ["a"] }
      action = build_axn { expects :f, type: Array, of: { klass: String, inclusion: opts } }
      opts[:in] << "b"

      expect(action.call(f: %w[a])).to be_ok
      expect(action.call(f: %w[b])).not_to be_ok
    end

    it "detaches the container INSIDE an option bag, not just the bag" do
      members = ["a"]
      action = build_axn { expects :f, type: Array, of: { klass: String, inclusion: { in: members } } }
      members << "b"

      expect(action.call(f: %w[b])).not_to be_ok
    end

    it "detaches the bare-Array form too" do
      members = ["a"]
      action = build_axn { expects :f, type: Array, of: { klass: String, inclusion: members } }
      members << "b"

      expect(action.call(f: %w[b])).not_to be_ok
    end

    it "detaches at a map axis" do
      members = ["a"]
      action = build_axn { expects :m, type: Hash, of: { values: { klass: String, inclusion: { in: members } } } }
      members << "b"

      expect(action.call(m: { x: "b" })).not_to be_ok
    end

    it "detaches at a nested bag" do
      members = ["a"]
      action = build_axn do
        expects :f, type: Array, of: { klass: Array, of: { klass: String, inclusion: { in: members } } }
      end
      members << "b"

      expect(action.call(f: [%w[b]])).not_to be_ok
    end

    it "leaves the caller's own objects unmutated" do
      opts = { in: ["a"] }
      build_axn { expects :f, type: Array, of: { klass: String, inclusion: opts } }

      expect(opts).to eq(in: ["a"])
    end

    it "reflects the canonicalized option, so the schema agrees with the runtime" do
      action = build_axn { expects :f, type: Array, of: { klass: String, format: { "with" => /\A[A-Z]+\z/ } } }

      expect(action.input_schema.dig(:properties, :f, :items)).to include(pattern: "^[A-Z]+$")
    end
  end

  describe "validators a position cannot read, refused at declaration" do
    # Each reads something an unnamed position has not got. The derivation is the point: the refusals are not
    # a hand-kept list beside the admitted set, they are what is left when the grammar's own keys and the
    # shared options come out of the known-validation set.
    {
      "type:" => { type: String },
      "model:" => { model: true },
      "confirmation:" => { confirmation: true },
      "coerce:" => { coerce: true },
    }.each do |label, extra|
      it "refuses #{label}" do
        expect { build_axn { expects :f, type: Array, of: { klass: String, **extra } } }
          .to raise_error(ArgumentError, /of: does not support/)
      end
    end

    it "refuses a misspelled option, naming the supported set" do
      expect { build_axn { expects :f, type: Array, of: { klass: String, mesage: "x" } } }
        .to raise_error(ArgumentError, /of: does not support mesage:/)
    end
  end

  describe "PRO-3192's positional guards, reaching a bag position unchanged" do
    it "refuses format: on a bag whose klass is a container" do
      expect { build_axn { expects :f, type: Array, of: { klass: Array, format: { with: /a/ } } } }
        .to raise_error(ArgumentError, /cannot constrain a container/)
    end

    it "refuses numericality: on a bag whose klass is a container" do
      expect { build_axn { expects :f, type: Array, of: { klass: Hash, numericality: { greater_than: 0 } } } }
        .to raise_error(ArgumentError, /cannot constrain a container/)
    end

    it "refuses an inclusion: set no value of the bag's klass could satisfy" do
      expect { build_axn { expects :f, type: Array, of: { klass: String, inclusion: { in: [1, 2] } } } }
        .to raise_error(ArgumentError, /can never match/)
    end

    it "reaches a map axis too" do
      expect { build_axn { expects :f, type: Hash, of: { values: { klass: String, inclusion: { in: [1] } } } } }
        .to raise_error(ArgumentError, /can never match/)
    end

    it "reaches a nested bag at depth 2" do
      expect { build_axn { expects :f, type: Array, of: { klass: Array, of: { klass: String, format: { with: /a/ } } } } }
        .not_to raise_error
      expect { build_axn { expects :f, type: Array, of: { klass: Array, of: { klass: Array, format: { with: /a/ } } } } }
        .to raise_error(ArgumentError, /cannot constrain a container/)
    end

    # At a FIELD, a tolerance flag stands the satisfiability guard down because it genuinely rescues the
    # contract — `type: String, inclusion: { in: [1, 2] }, optional: true` really does accept nil. A bag's own
    # `allow_nil:`/`allow_blank:` govern its POSITION the same way (PRO-3225): the tolerance is applied to
    # every check written there, so a tolerated nil/blank really does pass the position's own contract, and
    # the guard stands down for the same reason it does at a field.
    # The VACUITY twin, which reaches a bag position on the same terms. An inverted validator forbidding
    # literals no value of the bag's `klass:` could be enforces nothing at that position, exactly as it
    # enforces nothing at a field — so "PRO-3192's two guards" has to mean both of them here.
    it "refuses an exclusion: set no value of the bag's klass could be" do
      expect { build_axn { expects :f, type: Array, of: { klass: Integer, exclusion: { in: ["admin"] } } } }
        .to raise_error(ArgumentError, /exclusion: on an `of:` bag on :f enforces nothing/)
    end

    it "refuses comparison: other_than on the same reading" do
      expect { build_axn { expects :f, type: Array, of: { klass: Integer, comparison: { other_than: "admin" } } } }
        .to raise_error(ArgumentError, /comparison: on an `of:` bag on :f enforces nothing/)
    end

    it "reaches a map axis too" do
      expect { build_axn { expects :f, type: Hash, of: { values: { klass: Integer, exclusion: { in: ["a"] } } } } }
        .to raise_error(ArgumentError, /exclusion: .* enforces nothing/)
    end

    it "reports the UNSATISFIABLE half first where a declaration is broken both ways" do
      expect { build_axn { expects :f, type: Array, of: { klass: Integer, inclusion: { in: ["a"] }, exclusion: { in: ["b"] } } } }
        .to raise_error(ArgumentError, /inclusion: .* can never match/)
    end

    # The controls: each of these forbids something a value of the position's class really could be, so each
    # enforces something and must keep declaring.
    it "stands down where the forbidden literal is of the bag's own class" do
      expect { build_axn { expects :f, type: Array, of: { klass: Integer, exclusion: { in: [1] } } } }.not_to raise_error
      expect { build_axn { expects :f, type: Array, of: { klass: String, exclusion: { in: ["admin"] } } } }.not_to raise_error
    end

    it "lets the bag's own tolerance stand the guard down, the way a field's does" do
      expect { build_axn { expects :f, type: Array, of: { klass: String, inclusion: { in: [1, 2] }, allow_nil: true } } }
        .not_to raise_error
    end

    it "does so under allow_blank: too" do
      expect { build_axn { expects :f, type: Array, of: { klass: String, inclusion: { in: [1, 2] }, allow_blank: true } } }
        .not_to raise_error
    end

    # The field-level control, which must keep standing down — there the tolerance IS enforced.
    it "still stands down at a field, where the tolerance is enforced" do
      action = build_axn { expects :f, type: String, inclusion: { in: [1, 2] }, optional: true }

      expect(action.call(f: nil)).to be_ok
    end

    it "stands the container refusal down when the bag's klass is a scalar" do
      expect { build_axn { expects :f, type: Array, of: { klass: String, format: { with: /a/ } } } }.not_to raise_error
    end
  end

  describe "the destination obligation PRO-3192's messages created" do
    it "no longer says a per-element spelling is unsupported" do
      messages = []
      begin
        build_axn { expects :f, type: Array, format: { with: /a/ } }
      rescue ArgumentError => e
        messages << e.message
      end
      begin
        build_axn { expects :f, type: Array, of: String, inclusion: { in: %w[a b] } }
      rescue ArgumentError => e
        messages << e.message
      end
      # The VACUITY mirror, which carries its own copy of the remedy and so its own copy of the obligation.
      begin
        build_axn { expects :f, type: Array, exclusion: { in: ["admin"] } }
      rescue ArgumentError => e
        messages << e.message
      end

      expect(messages.length).to eq(3)
      messages.each do |message|
        expect(message).not_to include("not supported yet")
        expect(message).to include("of:")
      end
    end
  end

  # `validate:` is the one newly-admitted validator that reports through axn's own side channel, and that
  # channel names its subject in prose. A named position names itself; an unnamed one was naming axn's
  # synthetic attribute, which means nothing to the author reading the warning.
  describe "a crashing validate: callable at a position" do
    def warnings_from(&declaration)
      logged = []
      allow(Axn.config.logger).to receive(:warn) { |*args, &blk| logged << (args.first || blk&.call).to_s }
      action = build_axn(&declaration)
      yield_result = action.call(f: ["a"])
      [logged.join("\n"), yield_result]
    end

    it "names the position rather than axn's synthetic attribute" do
      message, = warnings_from { expects :f, type: Array, of: { klass: String, validate: -> {} } }

      expect(message).not_to include("__AXN_CONTENTS__")
      expect(message).to match(/CONTENTS OF A CONTAINER/i)
    end

    it "still fails the field rather than passing silently" do
      _, result = warnings_from { expects :f, type: Array, of: { klass: String, validate: -> {} } }

      expect(result).not_to be_ok
    end

    it "still names a NAMED position by its own name" do
      logged = []
      allow(Axn.config.logger).to receive(:warn) { |*args, &blk| logged << (args.first || blk&.call).to_s }
      build_axn { expects :f, type: String, validate: -> {} }.call(f: "a")

      expect(logged.join("\n")).to include("FIELD 'F'")
    end
  end

  # An output schema that rejects what the action can successfully serialize is worse than one that says less,
  # which is why `effective_validations` reduces a self-gated entry away on output for a named field. A bag's
  # validators get the same reduction — `emitted_contents_edge` already did it for the bag's `of:`/`shape:`.
  describe "a self-gated positional validator on output" do
    let(:action) do
      build_axn do
        expects :flag, type: :boolean
        exposes :codes, type: Array, of: { klass: String, inclusion: { in: ["a"], if: :flag } }
        def call = expose(:codes, ["zzz"])
      end
    end

    it "is reduced away in the output schema, which must not reject what the action exposes" do
      expect(action.call(flag: false)).to be_ok
      expect(action.output_schema.dig(:properties, :codes, :items)).not_to have_key(:enum)
    end

    it "still enforces the gated constraint when the gate is open" do
      expect(action.call(flag: true)).not_to be_ok
    end

    # The keys AXIS needed the same reduction, and did not get it when the element position did — one call site
    # swept, one missed. Sibling of the element-position case above, not a separate rule.
    it "is reduced away on a keys axis too" do
      keyed = build_axn do
        expects :flag, type: :boolean
        exposes :m, type: Hash, of: { keys: { klass: String, inclusion: { in: ["a"], if: :flag } }, values: Integer }
        def call = expose(:m, { "zzz" => 1 })
      end

      expect(keyed.call(flag: false)).to be_ok
      expect(keyed.output_schema.dig(:properties, :m, :propertyNames)).to be_nil
      expect(keyed.call(flag: true)).not_to be_ok
    end

    # Reflection is static-maximal on INPUT: a gate removes the check at runtime but the document advertises it
    # regardless, which is the existing rule for a self-gated `of:` edge (PRO-3166) and for a field's own.
    it "still advertises it on input, where reflection is static-maximal" do
      inbound = build_axn do
        expects :flag, type: :boolean
        expects :codes, type: Array, of: { klass: String, inclusion: { in: ["a"], if: :flag } }
      end

      expect(inbound.input_schema.dig(:properties, :codes, :items)).to include(enum: ["a"])
    end
  end

  # `validate:` is the one admitted validator with a DSL-misuse guard of its own, and the bag path was skipping
  # it — so `validate: { inclusion: … }` declared cleanly and raised `ArgumentError` on every call, the
  # declares-cleanly-then-always-raises shape this grammar exists to remove. The field path refuses it at
  # declaration; a position is held to the same rule by the same expander.
  describe "validate: misuse at a position" do
    it "refuses a Hash with no :with at an element position" do
      expect { build_axn { expects :f, type: Array, of: { klass: String, validate: { inclusion: { in: ["a"] } } } } }
        .to raise_error(ArgumentError, /`validate:` expects a callable/)
    end

    it "refuses an empty Hash" do
      expect { build_axn { expects :f, type: Array, of: { klass: String, validate: {} } } }
        .to raise_error(ArgumentError, /`validate:` expects a callable/)
    end

    it "refuses it on a map axis too" do
      expect { build_axn { expects :f, type: Hash, of: { values: { klass: Integer, validate: { inclusion: { in: [1] } } } } } }
        .to raise_error(ArgumentError, /`validate:` expects a callable/)
    end

    it "refuses it in a nested bag" do
      expect do
        build_axn do
          expects :f, type: Array, of: { klass: Array, of: { klass: String, validate: { inclusion: { in: ["a"] } } } }
        end
      end.to raise_error(ArgumentError, /`validate:` expects a callable/)
    end

    # The remedy the message offers has to be the one that works HERE: declaring the validator directly in the
    # bag constrains the element, where the field-level wording points at the container instead.
    it "points a positional misuse at the position rather than at the container" do
      message = begin
        build_axn { expects :f, type: Array, of: { klass: String, validate: { inclusion: { in: ["a"] } } } }
        nil
      rescue ArgumentError => e
        e.message
      end

      expect(message).to include("in the same bag")
      expect(message).not_to include("the container itself")
    end

    it "still accepts the bare callable and the with: form" do
      bare = build_axn { expects :f, type: Array, of: { klass: String, validate: ->(v) { "no" if v == "x" } } }
      withed = build_axn { expects :f, type: Array, of: { klass: String, validate: { with: ->(v) { "no" if v == "x" } } } }

      [bare, withed].each do |action|
        expect(action.call(f: ["a"])).to be_ok
        expect(action.call(f: ["x"])).not_to be_ok
      end
    end
  end

  describe "a bag that constrains nothing" do
    it "still refuses an empty bag" do
      expect { build_axn { expects :f, type: Array, of: {} } }
        .to raise_error(ArgumentError, /of: must constrain something/)
    end

    it "still refuses a message-only bag" do
      expect { build_axn { expects :f, type: Array, of: { message: "nope" } } }.to raise_error(ArgumentError)
    end

    it "still refuses an empty klass union, whatever else the bag carries" do
      expect { build_axn { expects :f, type: Array, of: { klass: [], format: { with: /a/ } } } }
        .to raise_error(ArgumentError, /empty union/)
    end

    it "accepts a bag whose only constraint is a validator" do
      expect { build_axn { expects :f, type: Array, of: { format: { with: /\Aa/ } } } }.not_to raise_error
    end
  end

  # A field's tolerance is a fact about the DECLARATION, so it is recorded there — once — rather than
  # copied into every validator entry. ActiveModel applies a declaration's shared options to each
  # validator itself (`defaults.merge(_parse_validates_options(options))`), which is the tier
  # `effective_entry_options` and `nil_accepted?` already resolve against. Recording it per entry made
  # axn's copies indistinguishable from an author's, which is what stopped a bag's own keys meaning the
  # position they describe.
  describe "where a field's tolerance is recorded" do
    it "states the pair on the declaration and writes it into no validator entry" do
      action = build_axn { expects :f, type: Array, of: Integer, optional: true }
      validations = action.internal_field_configs.first.validations

      expect(validations).to include(allow_blank: true, allow_nil: false)
      expect(validations[:type]).to eq(klass: Array)
      expect(validations[:of]).to eq(klass: Integer, container: Array, allow_nil: false, allow_blank: false)
    end

    it "keeps optional? reading true off the declaration tier alone" do
      action = build_axn { expects :f, type: Array, of: Integer, optional: true }

      expect(action.internal_field_configs.first.optional?).to be(true)
    end

    # The bag states its own `false` explicitly rather than leaving the keys absent: ActiveModel merges a
    # declaration's shared options into every validator built from the same `validates` call, `of:`
    # included, so an absent pair here would let the FIELD's own `allow_nil:`/`allow_blank:` — whatever a
    # future call site sets them to — silently reach this POSITION. Stating `false` is what makes a bag
    # with no tolerance of its own immune to that merge (PRO-3225).
    it "states its own false pair on a required field's bag, unreachable by the field's own tolerance" do
      action = build_axn { expects :f, type: Array, of: Integer }

      expect(action.internal_field_configs.first.validations[:of])
        .to eq(klass: Integer, container: Array, allow_nil: false, allow_blank: false)
    end
  end

  # A bag's tolerance governs the POSITION it describes: it stands that position's own checks down for a
  # value it admits, which is what `optional:` does at a named shape member. Without it there is no spelling
  # for "a nil element, alongside another validator": widening the class (`klass: [String, NilClass]`) widens
  # only the type check, and ActiveModel runs `format:`/`length:`/`inclusion:`/`numericality:` on a nil
  # regardless of what the type permits.
  describe "positional tolerance" do
    describe "an Array's element position" do
      it "admits a nil element beside another validator under allow_nil:" do
        action = build_axn do
          expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]{2}\z/ }, allow_nil: true }
        end

        expect(action.call(codes: ["AB", nil])).to be_ok
        expect(action.call(codes: ["AB"])).to be_ok
        expect(action.call(codes: ["ab"])).not_to be_ok
        expect(action.call(codes: [1])).not_to be_ok
      end

      it "admits a blank element only under allow_blank:" do
        nil_only = build_axn do
          expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]{2}\z/ }, allow_nil: true }
        end
        blank_too = build_axn do
          expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]{2}\z/ }, allow_blank: true }
        end

        expect(nil_only.call(codes: ["AB", ""])).not_to be_ok
        expect(blank_too.call(codes: ["AB", ""])).to be_ok
        expect(blank_too.call(codes: ["AB", nil])).to be_ok
      end

      it "stands the position's own type check down too, not only its value validators" do
        action = build_axn { expects :codes, type: Array, of: { klass: String, allow_nil: true } }

        expect(action.call(codes: ["AB", nil])).to be_ok
        expect(action.call(codes: [1])).not_to be_ok
      end

      it "stands the position's contents descent down as well" do
        action = build_axn do
          expects :rows, type: Array, of: { klass: Hash, allow_nil: true, shape: { members: [] } }
        end

        expect(action.call(rows: [{}, nil])).to be_ok
      end

      it "leaves a bag with no tolerance rejecting a nil element" do
        action = build_axn { expects :codes, type: Array, of: { klass: String } }

        expect(action.call(codes: ["AB", nil])).not_to be_ok
      end
    end

    describe "a map's axes" do
      it "admits a nil value under the values axis's own tolerance" do
        action = build_axn { expects :m, type: Hash, of: { values: { klass: String, allow_nil: true } } }

        expect(action.call(m: { a: "x", b: nil })).to be_ok
        expect(action.call(m: { a: 1 })).not_to be_ok
      end

      it "keeps the two axes independent" do
        action = build_axn do
          expects :m, type: Hash, of: { keys: { klass: Symbol }, values: { klass: String, allow_nil: true } }
        end

        expect(action.call(m: { a: nil })).to be_ok
        expect(action.call(m: { "a" => nil })).not_to be_ok
      end
    end

    describe "a nested bag" do
      it "tolerates at the rung that declares it, not at its parent" do
        action = build_axn do
          expects :f, type: Array, of: { klass: Array, of: { klass: String, allow_nil: true } }
        end

        expect(action.call(f: [["AB", nil]])).to be_ok
        expect(action.call(f: [nil])).not_to be_ok
      end
    end

    describe "a contradiction the position cannot hold" do
      # The same rule the field carries, for the same reason: the tolerance is applied to every check at the
      # position, so the presence check could never fail. Dead machinery, refused where it is written.
      it "refuses a tolerance beside an explicit presence: at an element position" do
        expect { build_axn { expects :f, type: Array, of: { klass: String, presence: true, allow_blank: true } } }
          .to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
      end

      it "refuses it under the optional: spelling too" do
        expect { build_axn { expects :f, type: Array, of: { klass: String, presence: true, optional: true } } }
          .to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
      end

      it "refuses it at a map axis" do
        expect do
          build_axn { expects :f, type: Hash, of: { values: { klass: String, presence: true, allow_nil: true } } }
        end.to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
      end

      it "still accepts a presence: with no tolerance beside it" do
        expect { build_axn { expects :f, type: Array, of: { klass: String, presence: true } } }.not_to raise_error
      end

      it "still refuses the same contradiction at a field" do
        expect { build_axn { expects :f, type: String, presence: true, optional: true } }
          .to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
      end
    end
  end
end
