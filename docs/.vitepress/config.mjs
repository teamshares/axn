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
        ]
      },
      {
        text: 'DSL Reference',
        items: [
          { text: 'Configuration', link: '/reference/configuration' },
          { text: 'Class Interface', link: '/reference/class' },
          { text: 'Instance Interface', link: '/reference/instance' },
          { text: 'Result Interface', link: '/reference/axn-result' },
        ]
      },
      {
        text: 'Recipes',
        items: [
          { text: 'Memoization', link: '/recipes/memoization' },
          { text: 'Validating User Input', link: '/recipes/validating-user-input' },
          { text: 'Testing Actions', link: '/recipes/testing' },
        ]
      },
      {
        text: 'Strategies',
        items: [
          { text: 'Overview', link: '/strategies/index' },
          { text: 'Transaction', link: '/strategies/transaction' },
        ]
      },
      {
        text: 'Additional Notes',
        items: [
          { text: 'ROUGH NOTES', link: '/advanced/rough' },
          { text: 'Conventions', link: '/advanced/conventions' },
        ]
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/teamshares/axn' }
    ]
  }
})
