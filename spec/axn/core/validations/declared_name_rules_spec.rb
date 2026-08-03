# frozen_string_literal: true

# Every option that carries a NAME, held to one pair of rules. PRO-2995 established them for `expose_return_as:`
# and a subfield's `on:`; PRO-3026 finished the set with the names `expects`/`exposes` take and the two
# reader-name options, `as:` and `prefix:`.
#
# Two rules, applied in this order at every site:
#
#   TYPE     — a String or a Symbol, and nothing else. Those are the only two types whose `to_s` and `to_sym` are
#              each other's inverse, so they are the only values with ONE name to canonicalize to. Anything else
#              was left to the caller's own `to_sym` and diagnosed as whatever that raised.
#   ENCODING — bytes in an ASCII-compatible encoding. A wide one (UTF-16, UTF-32) makes the questions a
#              declaration asks — is this path dotted, is this reader reserved — raise instead of answering.
#
# What separates the sites is ABSENCE, and it is the thing most easily got backwards. `on:`, `as:`, `prefix:` and
# `expose_return_as:` are OPTIONAL, so each runs an absent check FIRST and every spelling of "not supplied" means
# the option was omitted. A field NAME is never optional, so it runs no absent check at all: `expects nil` names
# no field and is an error, not a declaration of nothing.
#
# Its own file rather than `property_name_collision_spec.rb` (where the `on:` half lives): these are rules about
# what a name may BE, asked before any name is compared to another, and that file is already three and a half
# thousand lines of what happens once two of them collide.
RSpec.describe "the rules every declared name is held to" do
  # Neither a name nor absent. `Object.new` is here because the rule is not "responds to `to_sym`" — an object
  # that merely answers one has no single name either.
  def not_names = { [] => "Array", {} => "Hash", 123 => "Integer", 1.5 => "Float", Object.new => "Object" }

  # `nil`/`false` are separated out: at an OPTIONAL site they are the absent set, and at a field name they are
  # errors. Keeping them apart is what makes each site's expectation explicit rather than inherited.
  def absent_spellings = [nil, false, "", "   ", :""]

  def wide(text) = text.encode("UTF-16LE")

  # ASCII-compatible but not UTF-8 — the case the encoding rule must NOT catch. It compares against axn's own
  # ASCII patterns, and it canonicalizes to its UTF-8 rendering for every property it names.
  def latin1(bytes) = bytes.dup.force_encoding("ISO-8859-1")

  describe "a field name" do
    it "rejects a value that is not a name, naming the DSL and the offending class" do
      not_names.each do |value, klass|
        expect { build_axn { expects value } }
          .to raise_error(ArgumentError, /\Aa field name must be a String or Symbol naming an inbound field \(got a value of class #{klass}\)/)
        expect { build_axn { exposes value } }
          .to raise_error(ArgumentError,
                          /\Aan exposure name must be a String or Symbol naming an outbound field \(got a value of class #{klass}\)/)
      end
    end

    # The easy thing to get backwards, so it is asserted rather than assumed: a field name has NO absent set, so
    # `nil` and `false` are values that name no field. Wiring the guard behind the absent check that precedes it
    # at `on:`/`as:` would accept both as declaring nothing at all.
    it "rejects nil and false, which mean `absent` at every optional name option" do
      [nil, false].each do |value|
        expect { build_axn { expects value } }.to raise_error(ArgumentError, /\Aa field name must be a String or Symbol/)
        expect { build_axn { exposes value } }.to raise_error(ArgumentError, /\Aan exposure name must be a String or Symbol/)
      end
    end

    # The flip side of that same rule, recorded rather than quietly left: the REST of the absent set — an empty or
    # whitespace-only String, the empty Symbol — is a String or a Symbol, so it passes the type rule and declares a
    # field genuinely named that. It is pointless but it is not broken: the name works end to end (`""` is a legal
    # JSON property, and a caller can supply it), which is what separates it from the wide-encoding names below.
    # Since a field name is never optional there is no "absent" reading available to prefer instead.
    it "reads the rest of the absent set as a name, because a field name is never optional" do
      ["", "   ", :""].each do |value|
        klass = build_axn { expects value, allow_blank: true }

        expect(klass.internal_field_configs.map(&:field)).to eq([value.to_sym])
      end

      expect(build_axn { expects "", allow_blank: true }.call("": "supplied")).to be_ok
    end

    it "rejects a name in a wide encoding, naming the encoding" do
      name = wide("ab")

      expect { build_axn { expects name } }
        .to raise_error(ArgumentError, /\Aa field name must be written in an ASCII-compatible encoding \(got one encoded as UTF-16LE\)/)
      expect { build_axn { exposes name } }
        .to raise_error(ArgumentError, /\Aan exposure name must be written in an ASCII-compatible encoding/)
    end

    # Why such a name is refused rather than accommodated: it interns to a Symbol distinct from the UTF-8 property
    # it canonicalizes to, so the contract advertises a property nothing can satisfy.
    it "is refused because no caller could satisfy it" do
      expect(wide("ab").to_sym).not_to eq(:ab)
      expect(Axn::Reflection::Values.canonical_wire_key(wide("ab").to_sym)).to eq("ab")
    end

    it "still accepts every legal spelling" do
      expect(build_axn { expects :sym, "str" }.internal_field_configs.map(&:field)).to eq(%i[sym str])
      expect(build_axn { expects Class.new(String).new("subclassed") }.internal_field_configs.map(&:field)).to eq([:subclassed])
    end

    # ASCII-compatible non-UTF-8 stays legal, and works end to end rather than merely declaring.
    it "accepts an ASCII-compatible non-UTF-8 name and reads it" do
      name = latin1("caf\xE9")
      klass = build_axn { expects name, allow_blank: true }

      expect(Axn::Reflection::Values.canonical_wire_key(klass.internal_field_configs.first.field)).to eq("café")
      expect(klass.call(name.to_sym => "au lait")).to be_ok
    end
  end

  # `as:` and `prefix:` were the two name options PRO-2995 did not reach, and they failed differently. `as:` was
  # left to `to_sym` and raised `NoMethodError`. `prefix:` was never a `to_sym` site at all — it is INTERPOLATED,
  # so `to_s` accepted every object silently and composed a reader out of whatever it rendered as.
  describe "a reader-name option" do
    it "rejects a value that is not a name, naming the option and the offending class" do
      not_names.each do |value, klass|
        expect { build_axn { expects :a, as: value } }
          .to raise_error(ArgumentError, /\A`as:` must be a String or Symbol naming the generated reader \(got a value of class #{klass}\)/)
        expect { build_axn { expects :a, prefix: value } }
          .to raise_error(ArgumentError,
                          /\A`prefix:` must be a String or Symbol naming a prefix for each generated reader \(got a value of class #{klass}\)/)
      end
    end

    # What `prefix:` used to do with each of those, and the reason this is a silent defect rather than a loud one:
    # nothing raised, and the reader it generated cannot be invoked by any caller.
    it "no longer composes a reader out of a rendered non-name" do
      expect { build_axn { expects :a, prefix: [] } }.to raise_error(ArgumentError, /`prefix:`/)
      expect { build_axn { expects :a, prefix: { x: 1 } } }.to raise_error(ArgumentError, /`prefix:`/)
    end

    # Both options are optional, so both take the same absent set — and take it identically, which they did not
    # before: only `nil` reached the identity check, while `if as` treated `false` as absent too. So `as: false`
    # meant "no rename" while `prefix: false` prepended the literal text "false", and the spellings in between
    # were neither absent nor names (`as: ""` generated a reader called `:""`).
    it "treats every spelling of absence as `no rename`" do
      absent_spellings.each do |value|
        expect(build_axn { expects :a, as: value }.internal_field_configs.map(&:reader_as)).to eq([:a])
        expect(build_axn { expects :a, prefix: value }.internal_field_configs.map(&:reader_as)).to eq([:a])
      end
    end

    it "rejects a wide encoding at either option" do
      reader = wide("bee")
      prefix = wide("p_")

      expect { build_axn { expects :a, as: reader } }
        .to raise_error(ArgumentError, /\A`as:` must be written in an ASCII-compatible encoding \(got one encoded as UTF-16LE\)/)
      expect { build_axn { expects :a, prefix: } }
        .to raise_error(ArgumentError, /\A`prefix:` must be written in an ASCII-compatible encoding/)
    end

    # The dotted rule was on `as:` only, though a dotted PREFIX composes exactly the same unusable reader — the
    # last member of that family, closed with the type rule that reached the same helper.
    it "rejects a dotted value at either option" do
      expect { build_axn { expects :a, as: "x.y" } }
        .to raise_error(ArgumentError, /`as:` reader name may not be dotted/)
      expect { build_axn { expects :a, prefix: "x." } }
        .to raise_error(ArgumentError, /`prefix:` may not be dotted \(:"x\." would compose a reader that does not name a method\)/)
    end

    it "still renames readers through every legal spelling" do
      expect(build_axn { expects :a, as: :bee }.internal_field_configs.map(&:reader_as)).to eq([:bee])
      expect(build_axn { expects :a, as: "bee" }.internal_field_configs.map(&:reader_as)).to eq([:bee])
      expect(build_axn { expects :a, :b, prefix: :p_ }.internal_field_configs.map(&:reader_as)).to eq(%i[p_a p_b])
      expect(build_axn { expects :a, :b, prefix: "p_" }.internal_field_configs.map(&:reader_as)).to eq(%i[p_a p_b])
    end

    it "leaves the combined-options rejection where it was" do
      expect { build_axn { expects :a, as: :x, prefix: :y } }.to raise_error(ArgumentError, /`as:` and `prefix:` cannot be combined/)
    end
  end

  # `on:` already had the type rule; the encoding rule is new for it, and it was the site whose wide-encoding
  # failure came from splitting the route rather than from converting it.
  describe "a subfield route" do
    it "rejects a wide encoding" do
      route = wide("p")

      expect do
        build_axn do
          expects :p, type: Hash
          expects :a, on: route, optional: true
        end
        # Spelled `on:` rather than `` `on:` `` — both of this option's rules name it the way its own type rule
        # always has, since they now come from one call.
      end.to raise_error(ArgumentError, /\Aon: must be written in an ASCII-compatible encoding \(got one encoded as UTF-16LE\)/)
    end

    it "still accepts a dotted route" do
      klass = build_axn do
        expects :p, type: Hash
        expects :a, on: "p.q", optional: true
      end

      expect(klass.subfield_configs.map(&:on)).to eq([:"p.q"])
    end
  end

  # Neither rule may be answered by the value it is judging. A declaration guard that runs the offender's code
  # lets the offender replace the verdict — and outside StandardError, escape the class definition entirely.
  describe "an object that lies about itself" do
    it "cannot route around the type rule or replace the verdict" do
      hostile = Class.new do
        def is_a?(_klass) = true
        def kind_of?(_klass) = true
        def inspect = raise(NotImplementedError, "inspect should not build the message")
        def to_s = raise(NotImplementedError, "to_s should not build the message")
        def to_sym = :hijacked
      end.new

      expect { build_axn { expects hostile } }.to raise_error(ArgumentError, /\Aa field name must be a String or Symbol/)
      expect { build_axn { expects :a, as: hostile } }.to raise_error(ArgumentError, /\A`as:` must be a String or Symbol/)
      expect { build_axn { expects :a, prefix: hostile } }.to raise_error(ArgumentError, /\A`prefix:` must be a String or Symbol/)
    end

    # The encoding is read from the bound base implementation rather than asked of the value, for the same reason
    # the type test is a `case`/`when`: a dispatch inside a verdict is one the verdict never needed. So a String
    # subclass that merely CLAIMS a different encoding is judged on its real bytes.
    it "is judged on its real bytes rather than on what it claims" do
      lying_ascii = Class.new(String) { def encoding = Encoding::UTF_16LE }.new("honest")

      expect(build_axn { expects lying_ascii }.internal_field_configs.map(&:field)).to eq([:honest])
    end
  end

  # Where these rules STOP, recorded so it is a boundary rather than a gap someone re-discovers. They serve a name
  # a developer wrote: a Symbol, a String, or the `nil`/`[]`/`123` a variable holding the wrong thing produces.
  # They do not try to survive a class that lies about its own conversions, and that is a deliberate limit, not an
  # oversight — verifying that a foreign object BEHAVES is unbounded, so each round of hardening is defeated by the
  # next case, and a class whose `to_sym` answers with something other than the name it renders as is not a
  # contract axn can be asked to hold. (AGENTS.md: "do not build a guard that depends on foreign behaviour being
  # honest.")
  describe "the limits of these rules" do
    it "does not defend against a String subclass whose to_sym lies" do
      wide = Class.new(String) { def to_sym = "ab".encode("UTF-16LE").to_sym }.new("ab")
      not_a_symbol = Class.new(String) { def to_sym = [] }.new("ab")

      # Whatever these do, they are the lying class's own problem — asserted only as "does not declare cleanly",
      # so the rules above stay free to change how such a value fails without this file dictating it.
      expect { build_axn { expects wide } }.to raise_error(StandardError)
      expect { build_axn { expects not_a_symbol } }.to raise_error(StandardError)
    end
  end
end
