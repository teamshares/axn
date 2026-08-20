# frozen_string_literal: true

require "timeout"

# A self-referential (cyclic) Array or Hash reaching one of axn's observability walkers used to
# recurse to SystemStackError. Because those walkers run inside `.call` (auto_log is on by default,
# and exception reporting runs on the failure path), a single action handling cyclic data hard-crashed
# every invocation — and SystemStackError is not a StandardError, so it bypassed fail!/fails_on/
# on_exception entirely and escaped to the caller.
RSpec.describe "self-referential values" do
  let(:cyclic_array) do
    array = [1]
    array << array
    array
  end

  let(:cyclic_hash) do
    hash = {}
    hash["self"] = hash
    hash
  end

  describe "the call logger" do
    let(:log_messages) { [] }

    def capture(_action)
      allow(Axn.config.logger).to receive(:info) { |message| log_messages << message }
    end

    it "renders a cyclic exposure the way Ruby's own #inspect does" do
      action = build_axn do
        exposes :items
        def call = expose(items: [1].tap { |a| a << a })
      end
      capture(action)

      expect(action.call).to be_ok
      expect(log_messages.last).to include("[...]")
    end

    it "renders a cyclic input rather than replacing the inbound line's exception" do
      action = build_axn do
        expects :items
        exposes :v
        def call = expose(v: 1)
      end
      capture(action)

      expect(action.call(items: cyclic_array)).to be_ok
      expect(log_messages.first).to include("About to execute").and include("[...]")
    end

    it "renders a cyclic Hash" do
      action = build_axn do
        expects :payload
        exposes :v
        def call = expose(v: 1)
      end
      capture(action)

      expect(action.call(payload: cyclic_hash)).to be_ok
      expect(log_messages.first).to include("{...}")
    end

    # ActiveSupport::ParameterFilter has no cycle guard of its own and runs on every slice once any
    # field is sensitive, so it blows the stack before our formatter is reached. axn can't guard inside
    # it, so the slice is retried on a decycled copy — which costs acyclic data nothing and keeps the
    # rest of the line, rather than losing every field because one of them was cyclic.
    it "renders a cyclic value, and the fields beside it, on an action declaring a sensitive field" do
      action = build_axn do
        expects :secret, sensitive: true, allow_blank: true
        expects :items
        exposes :v
        def call = expose(v: 1)
      end
      capture(action)

      expect(action.call(secret: "hunter2", items: cyclic_array)).to be_ok
      expect(log_messages.first).to include("[...]").and include("[FILTERED]")
    end

    # A cycle passing through a nested shaped member is caught by redaction's OWN guard rather than by
    # `inspect`'s cycle rendering, and masks wholesale — the over-redact-rather-than-leak call every revisit
    # on this walk makes. It reads differently from the flat case above because a shaped member is the one
    # place redaction descends: an ARRAY-typed member's contents are declared in its `of:` bag (PRO-3166), so
    # the container walk's guard sees the array reappear beneath itself and stops there. Before that
    # canonicalization the innermost rung returned `element.dup` ahead of its own guard, which put the
    # caller's own cyclic Array back into what redaction handed the logger and left `inspect` to render it.
    it "masks a cycle that runs through a nested shaped member" do
      action = build_axn do
        expects :items, type: Array do
          field :children, type: Array do
            field :ssn, type: String, sensitive: true, allow_blank: true
          end
        end
        exposes :v
        def call = expose(v: 1)
      end
      capture(action)

      items = []
      items << { children: items }

      expect(action.call(items:)).to be_ok
      expect(log_messages.first).to include("[FILTERED]")
    end

    # Ruby renders `x = [1]; [x, x].inspect` as "[[1], [1]]": only ancestry is a cycle.
    it "still renders a container repeated among siblings in full" do
      action = build_axn do
        exposes :a, :b
        def call
          shared = [1]
          expose(a: shared, b: shared)
        end
      end
      capture(action)

      expect(action.call).to be_ok
      expect(log_messages.last).not_to include("[...]")
    end
  end

  describe "exception reporting" do
    let(:reported) { [] }

    around do |example|
      Axn.config.on_exception = ->(_e, action:, context:) { reported << context } # rubocop:disable Lint/UnusedBlockArgument
      example.run
    ensure
      Axn.config.on_exception = nil
    end

    it "reports the exception with the cyclic value rendered, instead of dying while building context" do
      action = build_axn do
        exposes :items
        def call
          expose(items: [1].tap { |a| a << a })
          raise "boom"
        end
      end

      result = action.call
      expect(result.exception.message).to eq("boom")
      expect(reported.first[:outputs][:items]).to eq([1, "[...]"])
    end
  end

  describe "observability facets" do
    it "coerces a cyclic tag value instead of recursing" do
      action = build_axn do
        expects :thing
        exposes :v
        tag(:weird) { thing }
        def call = expose(v: 1)
      end

      expect(action.call(thing: cyclic_array)).to be_ok
    end
  end

  # `with_timing` is nested inside `with_logging`, so a non-StandardError escaping `log_before` used
  # to reach `log_after` with no elapsed_time — which raised NoMethodError out of that ensure and
  # REPLACED the in-flight exception, destroying an enclosing Timeout (its ExitException never reached
  # the handler that converts it to Timeout::Error).
  describe "a raise from the auto_log hooks" do
    let(:action) do
      build_axn do
        exposes :v
        def call = expose(v: 1)
      end
    end

    it "preserves an enclosing Timeout" do
      allow(Axn.config.logger).to receive(:info) { sleep 0.2 }

      expect { Timeout.timeout(0.02) { action.call } }.to raise_error(Timeout::Error)
    end

    it "preserves an Interrupt rather than reporting a completion that never happened" do
      allow(Axn.config.logger).to receive(:info).and_raise(Interrupt, "ctrl-c")

      expect { action.call }.to raise_error(Interrupt, "ctrl-c")
    end

    # Everything used to build a log line — the duration, the facet maps, the separator, the context
    # slices — is an ARGUMENT to the guard inside CallLogger#log_at_level, so it evaluates outside it.
    # The executor therefore guards the whole hook, not just the emit.
    it "swallows a swallowable error raised while evaluating a log line's arguments" do
      allow(Axn::Internal::Timing).to receive(:human_duration).and_raise(SystemStackError)

      expect(action.call).to be_ok
    end

    it "does not log a completion line for a body that never ran" do
      logged = []
      allow(Axn.config.logger).to receive(:info) do |message|
        logged << message
        raise Interrupt, "ctrl-c" if message.include?("About to execute")
      end

      expect { action.call }.to raise_error(Interrupt)
      expect(logged.grep(/Execution completed/)).to be_empty
    end
  end
end
