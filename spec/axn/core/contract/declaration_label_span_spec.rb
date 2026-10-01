# frozen_string_literal: true

# The span in which a declaration's label is current is exactly the span of that declaration: from the first line
# of `expects`/`exposes` to its return. A refusal raised inside a nested declaration — one made while another's
# block is being evaluated — names the nested declaration, or nothing while its own label is not yet known; never
# the enclosing one.
RSpec.describe "a declaration label's span" do
  let(:inner) { Class.new { include Axn } }

  # Runs `nested` from inside the block of an outer `expects :outer`, and answers the message it raised.
  def refused_inside_outer(&nested)
    nested_class = inner
    message = nil
    Class.new { include Axn }.expects(:outer, type: Hash) do
      nested_class.instance_exec(&nested)
    rescue ArgumentError => e
      message = e.message
    end
    message
  end

  {
    "a field name that is not a name (expects nil)" => -> { expects nil },
    "a route that is not a name (expects :x, on: 1)" => -> { expects :x, on: 1 },
    "an exposure name that is not a name (exposes nil)" => -> { exposes nil },
    "a declaration naming no field (expects(method_call: true))" => -> { expects(method_call: true) },
    "a declaration naming no field (exposes(type: 1))" => -> { exposes(sensitive: :x, type: 1) },
  }.each do |shape, nested|
    it "never names the enclosing declaration for #{shape}" do
      message = refused_inside_outer(&nested)

      expect(message).not_to be_nil
      expect(message).not_to include("expects :outer")
    end
  end

  # The same refusal left to escape both declarations, as most specs assert one: the audit judges it at the
  # matcher, against the label of the declaration that raised it.
  it "lets the nested refusal escape with the nested declaration's own label" do
    nested_class = inner
    expect { Class.new { include Axn }.expects(:outer, type: Hash) { nested_class.expects :x, on: 1 } }
      .to raise_error(ArgumentError, /\A`on:` isn't allowed on expects :x — it must be a String or Symbol/)
  end

  # A path segment that is not a plain identifier is quoted as its Symbol would be, in the label and in the `on:`
  # echo alike, so `expects "x y".a` reads as one path; the audit matches the quoted label whole.
  it "quotes a route segment that is not a plain identifier" do
    expect do
      build_axn do
        expects :"x y", type: Hash
        expects :a, on: :"x y", type: String, inclusion: { in: [1] }
      end
    end.to raise_error(ArgumentError, /\Ainclusion: on expects "x y"\.a can never match/)
    expect { build_axn { expects :a, on: "x y" } }
      .to raise_error(ArgumentError, /\A`on: :"x y"` isn't allowed on expects "x y"\.a — no such reader exists/)
  end

  it "names the nested declaration once its names are known, even before its route is" do
    expect(refused_inside_outer { expects :x, on: 1 }).to include("expects :x")
  end

  it "leaves the enclosing declaration's label in place once the nested one returns" do
    nested_class = inner
    seen = nil
    Class.new { include Axn }.expects(:outer, type: Hash) do
      nested_class.expects :ok
      seen = Axn::Core::Contract::DeclarationLabel.current
    end
    expect(seen).to eq("expects :outer")
    expect(Axn::Core::Contract::DeclarationLabel.current).to be_nil
  end
end
