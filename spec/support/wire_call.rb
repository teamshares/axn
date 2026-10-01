# frozen_string_literal: true

require "json"

# How a spec that holds a schema against the runtime calls the runtime: with the payload a JSON client sends, read
# back through JSON, so every key is a String and every value a JSON primitive — the arguments a tool adapter hands
# `Axn.call`. A Ruby-built payload (Symbol keys, a Symbol or Time value) can satisfy a literal the wire never can,
# and an audit calling with one passes for a mismatch the wire hits.
module WireCall
  module_function

  def payload(value) = JSON.parse(JSON.generate(value))

  def call(klass, value = {}) = klass.call(**payload(value))
end
