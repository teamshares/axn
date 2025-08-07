---
outline: deep
---
# Getting Started

## Installation

Adding `axn` to your Gemfile is enough to start using `include Action`.

## Global Configuration

A few configuration steps are _highly_ recommended to get the full benefits (e.g. making sure all your swallowed exceptions are getting reported to your error tracking service).

The full set of available configuration settings is documented [over here](/reference/configuration), but there are two worth calling out specifically:

### Error Tracking

By default any swallowed errors are noted in the logs, but it's _highly recommended_ to [wire up an `on_exception` handler](/reference/configuration#on-exception).

### Metrics / Tracing

If you're using an APM provider, observability can be greatly enhanced by [configuring tracing and metrics hooks](/reference/configuration#tracing-and-metrics).


