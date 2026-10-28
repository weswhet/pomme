// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Cloudflare Pages publishes the site at https://pommevm.dev from main.
// Set POMME_DOCS_SITE to build for another URL, such as a tailnet name.
export default defineConfig({
	site: process.env.POMME_DOCS_SITE || 'https://pommevm.dev',
	telemetry: false,
	integrations: [
		starlight({
			title: 'Pomme',
			description:
				'Documentation for Pomme, a command-line tool for creating and controlling macOS virtual machines on Apple silicon.',
			favicon: '/favicon.svg',
			// Crawler mode is a playful retelling of the docs at /crawler/. It's a
			// Starlight locale, so pages without a crawler version fall back to
			// the normal text. See CRAWLER_VOICE.md.
			defaultLocale: 'root',
			locales: {
				root: { label: 'English', lang: 'en' },
				crawler: { label: 'Crawler', lang: 'en-x-crawler' },
			},
			components: {
				ThemeSelect: './src/components/ThemeSelect.astro',
				LanguageSelect: './src/components/LanguageSelect.astro',
			},
			customCss: ['./src/styles/pomme.css'],
			lastUpdated: false,
			pagination: true,
			tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
			sidebar: [
				{ label: 'Overview', translations: { 'en-x-crawler': 'The Lobby' }, link: '/' },
				{
					label: 'Get started',
					translations: { 'en-x-crawler': 'Floor 1: Orientation' },
					items: [
						'get-started/requirements',
						'get-started/install',
						'get-started/quickstart',
					],
				},
				{
					label: 'Concepts',
					translations: { 'en-x-crawler': 'Floor 2: Lore' },
					items: [
						'concepts/architecture',
						'concepts/vm-lifecycle',
						'concepts/durable-creation',
						'concepts/guest-agent',
						'concepts/security-model',
						'concepts/os-qualification',
					],
				},
				{
					label: 'Create and manage VMs',
					translations: { 'en-x-crawler': 'Floor 3: Spawning Things' },
					items: [
						'guides/create-vms',
						'guides/use-templates',
						'guides/create-from-config',
						'guides/manage-vm-lifecycle',
						'guides/use-snapshots',
						'guides/manage-restore-images',
						'guides/use-the-tui',
					],
				},
				{
					label: 'Work inside a VM',
					translations: { 'en-x-crawler': 'Floor 4: Inside the Box' },
					items: [
						'guides/run-guest-commands',
						'guides/use-terminal-sessions',
						'guides/transfer-files',
						'guides/install-packages',
						'guides/view-guest-logs',
					],
				},
				{
					label: 'Security and management',
					translations: { 'en-x-crawler': 'Floor 5: Boss Mechanics' },
					items: [
						'guides/change-sip-and-amfi',
						'guides/enroll-in-mdm',
						'guides/enable-remote-access',
						'guides/repair-the-agent',
					],
				},
				{
					label: 'Automation',
					translations: { 'en-x-crawler': 'Floor 6: Bots and Macros' },
					items: ['guides/automate-the-display', 'guides/script-pomme'],
				},
				{
					label: 'Reference',
					translations: { 'en-x-crawler': 'The Library of Stats' },
					items: [
						{
							label: 'Command-line reference',
							translations: { 'en-x-crawler': 'The Spellbook' },
							collapsed: true,
							items: [{ autogenerate: { directory: 'reference/cli' } }],
						},
						'reference/config-file',
						'reference/structured-output',
						'reference/exit-codes',
						'reference/errors',
						'reference/environment-variables',
						'reference/files-and-paths',
						'reference/key-names',
					],
				},
				{
					label: 'Resources',
					translations: { 'en-x-crawler': 'Safe Room' },
					items: [
						'resources/troubleshooting',
						'resources/glossary',
						'resources/release-notes',
						'resources/about-these-docs',
					],
				},
			],
		}),
	],
});
