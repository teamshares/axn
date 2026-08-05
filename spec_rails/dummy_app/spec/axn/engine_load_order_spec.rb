# frozen_string_literal: true

require "open3"

# Load order is process-global and decided before this suite's own `spec_helper` runs, so these
# have to boot a fresh Ruby. The dummy app's `spec_helper` requires `config/environment` first,
# which is the *lucky* order — a conventional Rails app splits `spec_helper.rb` (loaded by
# `.rspec`, before Rails) from `rails_helper.rb` (which loads the environment), so the axn
# requires we document land before Rails exists.
RSpec.describe "Axn Rails engine registration vs. require order" do
  # Non-interpolating so the probe's own `#{}`s survive to the child process.
  def probe
    <<~'RUBY'
      require File.expand_path("config/environment", Dir.pwd)
      puts "engine=#{defined?(Axn::RailsIntegration::Engine) ? 'yes' : 'no'}"
      puts "namespace=#{Rails.autoloaders.main.send(:roots)[Rails.root.join('app/actions').to_s].inspect}"
      puts "resolve=#{begin
        Actions::Clients::User.name
      rescue StandardError => e
        "#{e.class}: #{e.message}"
      end}"
    RUBY
  end

  def boot_with(preamble)
    script = "#{preamble}\n#{probe}"

    out, status = Open3.capture2e(
      { "RAILS_ENV" => "test" }, RbConfig.ruby, "-e", script, chdir: Rails.root.to_s
    )
    raise "boot failed (#{status.exitstatus}):\n#{out}" unless status.success?

    out
  end

  it "registers the engine when axn is required before Rails" do
    output = boot_with('require "axn"')

    expect(output).to include("engine=yes")
    expect(output).to include("namespace=Actions")
    expect(output).to include("resolve=Actions::Clients::User")
  end

  # The regression that shipped in 0.1.0.pre.alpha.5: `axn/testing/spec_helpers` pulls in the
  # whole gem, and we document requiring it from `spec_helper.rb` — i.e. before Rails.
  it "registers the engine when axn/testing/spec_helpers is required before Rails" do
    output = boot_with('require "axn/testing/spec_helpers"')

    expect(output).to include("engine=yes")
    expect(output).to include("namespace=Actions")
    expect(output).to include("resolve=Actions::Clients::User")
  end

  it "registers the engine when Rails is loaded first" do
    output = boot_with("")

    expect(output).to include("engine=yes")
    expect(output).to include("namespace=Actions")
  end
end
