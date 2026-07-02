# frozen_string_literal: true

require "axn/reflection/values"

module Axn
  # Read-only reflection of an Axn's contract (Schema) and a Result's values (Values) into
  # transport-agnostic Hashes. Off the execution path; used by adapters (MCP/RubyLLM/REST) and docs.
  module Reflection
  end
end
