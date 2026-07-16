# frozen_string_literal: true

RSpec.describe "Step data passing" do
  subject(:result) { composed.call(num: 10, extra: 11) }

  let(:composed) do
    build_axn do
      expects :num
      exposes :num, :third

      step :step1, expects: [:num], exposes: [:num] do
        puts "Step1:#{num}"
        expose :num, num + 1
      end

      step :step2, expects: %i[num extra], exposes: :num do
        puts "Step2:#{num}"

        # Note we can expect things from what was given to parent, NOT needed to be passed by prev step
        expose :num, num + extra
      end

      step :step3, expects: [:num], expose_return_as: :third do
        puts "Step3:#{num}"
        3
      end
    end
  end

  it "can pass data through the stack" do
    expect { result }.to output("Step1:10\nStep2:11\nStep3:22\n").to_stdout
    is_expected.to be_ok
    expect(result.num).to eq(22)
    expect(result.third).to eq(3)
  end
end

RSpec.describe "Step data passing forwards parent's resolved top-level default" do
  subject(:result) { composed.call }

  let(:composed) do
    build_axn do
      # No value provided by the caller -- the parent must resolve this default itself, and that
      # resolved value (not a raw/missing one) is what the child step should see.
      expects :tenant_id, default: 1
      exposes :tenant_id

      step :step1, expects: [:tenant_id], exposes: [:tenant_id] do
        expose :tenant_id, tenant_id
      end
    end
  end

  it "gives the child step the parent's resolved default, not a raw/missing value" do
    is_expected.to be_ok
    expect(result.tenant_id).to eq(1)
  end
end

RSpec.describe "Step data passing forwards parent's normalized-to-nil value, not the raw caller value" do
  subject(:result) { composed.call(role: "   ") }

  let(:composed) do
    build_axn do
      # A blank caller value is normalized to nil by the parent's preprocess -- the child step
      # should see that resolved nil (and apply its own fallback), not the raw blank string.
      expects :role, allow_blank: true, preprocess: ->(v) { v.to_s.strip.empty? ? nil : v.strip }
      exposes :role_seen_by_child

      step :step1, expects: { role: { allow_nil: true } }, exposes: [:role_seen_by_child] do
        expose :role_seen_by_child, role || "fallback"
      end
    end
  end

  it "gives the child step the parent's resolved nil, not the raw blank string" do
    is_expected.to be_ok
    expect(result.role_seen_by_child).to eq("fallback")
  end
end
