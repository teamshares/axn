---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Axn"
  text: "A terse convention for business logic"
  tagline: "**ALPHA release -- everything subject to change**"
  actions:
    - theme: brand
      text: Overview
      link: /intro/overview
    - theme: alt
      text: Usage
      link: /usage/setup
    - theme: alt
      text: DSL Reference
      link: /reference/class
    # - theme: alt
    #   text: API Examples
    #   link: /api-examples

features:
  - title: Declarative interface
    details: Clear, explicit contracts for inputs and outputs with `expects` and `exposes`
  - title: Exception swallowing
    details: Automatic error handling with user-safe error messages and internal logging
  - title: Advanced Patterns
    details: Attachable actions, workflow composition, and background processing capabilities
  - title: Default Observability
    details: Built-in logging, timing, and error tracking out of the box
---

::: danger ALPHA RELEASE
Axn is used in production at [Teamshares](https://teamshares.com/), but is still in alpha and is undergoing active development.
:::
