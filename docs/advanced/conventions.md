---
outline: deep
---

# Conventions

This page serves as a repository for various softly-held opinions about _how_ it makes sense to use the library.

::: warning DRAFT
These conventions are still in flux as the library is solidified and we gain more experience using it in production. Take these notes with a grain of salt.
:::

## Organizing Actions (Rails)

You _can_ `include Action` into _any_ Ruby class, but to keep track of things we've found it helpful to:

  * Create a new `app/actions` folder for our actions
  * Name them `Actions::[DOMAIN]::[VERB]` where `[DOMAIN]` is a (possibly nested) identifier and `[VERB]` is the action to be taken.

    Examples:
      * `Actions::User::Create`
      * `Actions::Slack::Notify`

For us, we've found the maintenance benefits of knowing roughly how the class will behave just by glancing at the name has been worth being a bit pedantic about the naming.

## Naming conventions

### The responsible user
When tracking _who_ is responsible for the action being taken, one option is to inject it globally via `Current.user` (see: [Current Attributes](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html)), but that only works if you're _sure_ you're never going to want to execute the action asynchronously on a background processor.

More generally, we've adopted the convention of passing in the responsible user as `actor`:

  ```ruby
  class Foo
    include Axn
    expects :actor, type: User # [!code focus]
  end
  ```
