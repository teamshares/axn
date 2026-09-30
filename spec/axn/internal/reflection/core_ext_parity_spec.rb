# frozen_string_literal: true

require "open3"
require "json"
require "rbconfig"

# A value renders the same whether or not ActiveSupport's `json` core_ext is loaded. The core_ext is process-wide
# and can leak in from any `require` (`globalid` is one), so the two environments are each a FRESH process rather
# than a toggle in this one: the same cases run in both and the renderings are compared.
#
# Excluded on purpose, because the difference is the documented `reject_opaque` case rather than a routing
# disagreement: a value with NO public `to_h`/`to_hash`/`as_json` of its own declares no shape, so it renders as
# an object address outside Rails and as ActiveSupport's instance-variable dump inside it. And a class that
# overrides `respond_to?` to deny a method it has: nothing routes around a lie the first dispatch depends on.
RSpec.describe "Values.serialize_value with and without ActiveSupport's json core_ext" do
  def cases_script = <<~'RUBY'
    require "active_support" and require "active_support/core_ext/object/json" if ENV["CORE_EXT"] == "1"
    require "bigdecimal"
    require "set"
    require "date"
    require "json"
    require "axn"

    values = Axn::Internal::Reflection::Values
    pair = Data.define(:a, :b)
    rec = Struct.new(:a, :b)
    enum = ->(&extra) { Class.new { include Enumerable; def each(&) = [1, 2].each(&); class_exec(&extra) if extra } }
    nonpublic = ->(base, vis) { Class.new(base) { define_method(:to_h) { { via: "to_h" } }; send(vis, :to_h) } }
    hashy = Class.new { def to_hash = { amount: BigDecimal("3.14"), nan: 1.5 } }
    both = Class.new { def to_hash = { via: "to_hash" }; def to_h = { via: "to_h" } }
    custom_as_json = Class.new { def as_json(*) = { via: "as_json" }; def to_h = { via: "to_h" } }

    cases = {
      "set of decimals" => -> { Set[BigDecimal("3.14"), 2] },
      "set of pairs" => -> { Set[[1, 2]] },
      "empty set" => -> { Set.new },
      "set of nan" => -> { Set[Float::NAN] },
      "set of data" => -> { Set[pair.new(BigDecimal("1.5"), 1)] },
      "enumerator" => -> { [1, 2].each },
      "range" => -> { 1..3 },
      "endless range" => -> { 1.. },
      "enumerable" => -> { enum.call.new },
      "enumerable own to_h" => -> { enum.call { def to_h = { own: true } }.new },
      "enumerable own as_json" => -> { enum.call { def as_json(*) = { via: "as_json" } }.new },
      "data" => -> { pair.new(BigDecimal("1.5"), Time.utc(2026, 1, 1, 0, 0, 0.5r)) },
      "struct" => -> { rec.new(BigDecimal("1.5"), Date.new(2026, 1, 1)) },
      "data nan" => -> { pair.new(Float::NAN, 1) },
      "data with set and to_hash" => -> { pair.new(Set[BigDecimal("1.5")], hashy.new) },
      "data in data" => -> { pair.new(pair.new(BigDecimal("1.5"), 1), [pair.new(2, 3)]) },
      "data public to_h" => -> { nonpublic.call(pair, :public).new(1, 2) },
      "data protected to_h" => -> { nonpublic.call(pair, :protected).new(1, 2) },
      "data private to_h" => -> { nonpublic.call(pair, :private).new(1, 2) },
      "struct protected to_h" => -> { nonpublic.call(rec, :protected).new(1, 2) },
      "struct private to_h" => -> { nonpublic.call(rec, :private).new(1, 2) },
      "to_hash only" => -> { hashy.new },
      "to_hash and to_h" => -> { both.new },
      "own as_json and to_h" => -> { custom_as_json.new },
      "array of decimals" => -> { [BigDecimal("3.14")] },
      "hash of decimals" => -> { { a: BigDecimal("3.14") } },
    }

    rendered = cases.flat_map do |name, build|
      [false, true].map do |opaque|
        out = begin
          JSON.generate(values.serialize_value(build.call, reject_opaque: opaque))
        rescue StandardError => e
          "raised #{e.class}"
        end
        ["#{name} (reject_opaque: #{opaque})", out]
      end
    end.to_h
    puts JSON.generate(rendered)
  RUBY

  def render_cases(core_ext:)
    stdout, stderr, process = Open3.capture3(
      { "CORE_EXT" => core_ext ? "1" : "0" }, RbConfig.ruby, "-Ilib", "-e", cases_script, chdir: File.expand_path("../../../..", __dir__)
    )
    raise "subprocess failed: #{stderr}" unless process.success?

    JSON.parse(stdout.lines.last)
  end

  it "renders every case identically in a process with the core_ext and one without" do
    without = render_cases(core_ext: false)
    with = render_cases(core_ext: true)

    expect(without.keys).to eq(with.keys)
    differing = without.keys.reject { |k| without[k] == with[k] }.to_h { |k| [k, { without: without[k], with: with[k] }] }
    expect(differing).to eq({})
  end

  it "actually loads the core_ext in one of the two processes (the comparison is not vacuous)" do
    stdout, = Open3.capture3(
      { "CORE_EXT" => "1" }, RbConfig.ruby, "-Ilib", "-e",
      'require "active_support"; require "active_support/core_ext/object/json"; puts Data.instance_method(:as_json).owner',
      chdir: File.expand_path("../../../..", __dir__)
    )

    expect(stdout.strip).to eq("Data")
  end
end
