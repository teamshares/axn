# frozen_string_literal: true

require_relative "../../../spec_helper"
require_relative "../../../../lib/rubocop/cop/axn/ambient_context_bypass"

RSpec.describe RuboCop::Cop::Axn::AmbientContextBypass do
  include RuboCop::RSpec::ExpectOffense
  subject(:cop) { described_class.new }

  it "flags a direct Current attribute read inside an Axn class" do
    expect_offense(<<~RUBY)
      class Foo
        include Axn
        def call
          do_thing(Current.company)
                   ^^^^^^^^^^^^^^^ Axn/AmbientContextBypass: Read ambient state via `expects :company, on: :ambient_context` instead of `Current` directly.
        end
      end
    RUBY
  end

  it "flags a top-level ::Current read inside an Axn class" do
    expect_offense(<<~RUBY)
      class Foo
        include Axn
        def call
          x = ::Current.user
              ^^^^^^^^^^^^^^ Axn/AmbientContextBypass: Read ambient state via `expects :user, on: :ambient_context` instead of `Current` directly.
        end
      end
    RUBY
  end

  it "flags a Current read inside a class that includes the fully-qualified ::Axn" do
    expect_offense(<<~RUBY)
      class Foo
        include ::Axn
        def call
          do_thing(Current.company)
                   ^^^^^^^^^^^^^^^ Axn/AmbientContextBypass: Read ambient state via `expects :company, on: :ambient_context` instead of `Current` directly.
        end
      end
    RUBY
  end

  it "does not flag a Current read in a plain class that does not include Axn (false-positive guard)" do
    expect_no_offenses(<<~RUBY)
      class UsersController
        def show
          Current.user
        end
      end
    RUBY
  end

  it "does not flag a bare Current read outside any class (no enclosing Axn class)" do
    expect_no_offenses("do_thing(Current.company)")
  end

  it "does not flag unrelated receivers" do
    expect_no_offenses(<<~RUBY)
      class Foo
        include Axn
        def call
          x = Time.current
        end
      end
    RUBY
  end

  it "does not flag a Current assignment (setup, not a bypass read)" do
    expect_no_offenses(<<~RUBY)
      class Foo
        include Axn
        def call
          Current.company = c
        end
      end
    RUBY
  end

  it "does not flag a Current call with arguments" do
    expect_no_offenses(<<~RUBY)
      class Foo
        include Axn
        def call
          Current.foo(bar)
        end
      end
    RUBY
  end

  it "does not flag Current.reset (lifecycle API, not an attribute read)" do
    expect_no_offenses(<<~RUBY)
      class Foo
        include Axn
        def call
          Current.reset
        end
      end
    RUBY
  end

  it "does not flag Current.instance (lifecycle API, not an attribute read)" do
    expect_no_offenses(<<~RUBY)
      class Foo
        include Axn
        def call
          Current.instance
        end
      end
    RUBY
  end

  it "does not flag Current.attributes (lifecycle API, not an attribute read)" do
    expect_no_offenses(<<~RUBY)
      class Foo
        include Axn
        def call
          Current.attributes
        end
      end
    RUBY
  end

  it "does not flag ::Current.reset (lifecycle API, not an attribute read)" do
    expect_no_offenses(<<~RUBY)
      class Foo
        include Axn
        def call
          ::Current.reset
        end
      end
    RUBY
  end

  it "does not flag a Current read in a non-Axn outer class that merely contains a nested Axn class" do
    expect_no_offenses(<<~RUBY)
      class UsersController
        def show
          Current.user
        end

        class QuickAction
          include Axn
          def call; end
        end
      end
    RUBY
  end

  it "still flags a Current read inside a nested Axn class, even though the outer class does not include Axn" do
    expect_offense(<<~RUBY)
      class Outer
        class QuickAction
          include Axn
          def call
            Current.company
            ^^^^^^^^^^^^^^^ Axn/AmbientContextBypass: Read ambient state via `expects :company, on: :ambient_context` instead of `Current` directly.
          end
        end
      end
    RUBY
  end

  it "does not flag a Current read in a plain nested helper class under an Axn action (Bug MM: only the innermost class/module decides)" do
    expect_no_offenses(<<~RUBY)
      class Action
        include Axn
        class Helper
          def call
            Current.user
          end
        end
      end
    RUBY
  end

  it "still flags a Current read directly in the Axn action's own method, even when it also has a nested non-Axn helper class" do
    expect_offense(<<~RUBY)
      class Action
        include Axn
        class Helper
          def call
            Current.user
          end
        end

        def call
          Current.company
          ^^^^^^^^^^^^^^^ Axn/AmbientContextBypass: Read ambient state via `expects :company, on: :ambient_context` instead of `Current` directly.
        end
      end
    RUBY
  end
end
