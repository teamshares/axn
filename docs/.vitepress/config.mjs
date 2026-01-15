import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: "Axn",
  description: "A terse convention for business logic",
  base: "/axn/",
  themeConfig: {
    // https://vitepress.dev/reference/default-theme-config
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Overview', link: '/intro/overview' },
      { text: 'Guide', link: '/usage/setup' },
      { text: 'Reference', link: '/reference/configuration' }
    ],

    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'About', link: '/intro/about' },
          { text: 'Overview', link: '/intro/overview' },
        ]
      },
      {
        text: 'Usage Guide',
        items: [
          { text: 'Getting Started', link: '/usage/setup' },
          { text: 'Writing Actions', link: '/usage/writing' },
          { text: 'Using Actions', link: '/usage/using' },
          { text: 'Steps', link: '/usage/steps' },
        ]
      },
      {
        text: 'DSL Reference',
        items: [
          { text: 'Configuration', link: '/reference/configuration' },
          { text: 'Class Interface', link: '/reference/class' },
          { text: 'Instance Interface', link: '/reference/instance' },
          { text: 'Result Interface', link: '/reference/axn-result' },
          { text: 'Async', link: '/reference/async' },
          { text: 'FormObject', link: '/reference/form-object' },
        ]
      },
      {
        text: 'Strategies',
        items: [
          { text: 'Overview', link: '/strategies/index' },
          { text: 'Transaction', link: '/strategies/transaction' },
          { text: 'Form', link: '/strategies/form' },
          { text: 'Client', link: '/strategies/client' },
        ]
      },
      {
        text: 'Recipes',
        items: [
          { text: 'Memoization', link: '/recipes/memoization' },
          { text: 'Validating User Input', link: '/recipes/validating-user-input' },
          { text: 'Testing Actions', link: '/recipes/testing' },
          { text: 'RuboCop Integration', link: '/recipes/rubocop-integration' },
          { text: 'Formatting Context for Error Tracking', link: '/recipes/formatting-context-for-error-tracking' },
        ]
      },
      {
        text: 'Advanced',
        items: [
          { text: 'Profiling', link: '/advanced/profiling' },
          { text: 'Conventions', link: '/advanced/conventions' },
          { text: 'Mountable', link: '/advanced/mountable' },
          { text: 'Internal Notes', link: '/advanced/rough' },
        ]
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/teamshares/axn' }
    ]
  }
})
