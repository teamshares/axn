# frozen_string_literal: true

require "rspec/core/formatters"

# Records how many examples THIS process actually ran, so the parallel lanes can assert that the
# workers' counts sum to the single-process total (see RUN_PARALLEL_LANE in the Rakefile).
#
# The check has to be independent of the runner's own accounting to be worth anything: a runner that
# miscounts, or that loses a worker without noticing, would report a self-consistent total either way.
# `dump_summary` is public formatter API and fires once per process at the end of its run, and the
# filename is the pid so N workers can write the same directory without coordinating.
#
# Deliberately silent on `output` — the lane already has a formatter producing human output, and this
# one exists only for its file.
class AxnParallelExampleCounter
  RSpec::Core::Formatters.register self, :dump_summary

  COUNT_DIR_ENV = "AXN_SPEC_COUNT_DIR"

  def initialize(_output); end

  def dump_summary(notification)
    dir = ENV.fetch(COUNT_DIR_ENV, nil)
    return if dir.nil? || dir.empty?

    File.write(File.join(dir, "#{Process.pid}.count"), notification.examples.size)
  end
end
