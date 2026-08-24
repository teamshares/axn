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

      expect(messages.length).to eq(2)
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
end
