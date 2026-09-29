// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// The site is built and previewed locally; it is not deployed anywhere.
// Set POMME_DOCS_SITE to the URL it is served from, such as a tailnet name.
export default defineConfig({
	site: process.env.POMME_DOCS_SITE || 'http://localhost:4321',
	telemetry: false,
	integrations: [
		starlight({
			title: 'Pomme',
			description:
				'Documentation for Pomme, a command-line tool for creating and controlling macOS virtual machines on Apple silicon.',
			favicon: '/favicon.svg',
			customCss: ['./src/styles/pomme.css'],
			lastUpdated: false,
			pagination: true,
			tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
			sidebar: [
				{ label: 'Overview', link: '/' },
				{
					label: 'Get started',
					items: [
						'get-started/requirements',
						'get-started/install',
						'get-started/quickstart',
					],
				},
				{
					label: 'Concepts',
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
					items: [
						'guides/run-guest-commands',
						'guides/use-terminal-sessions',
						'guides/transfer-files',
						'guides/view-guest-logs',
					],
				},
				{
					label: 'Security and management',
					items: [
						'guides/change-sip-and-amfi',
						'guides/enroll-in-mdm',
						'guides/enable-remote-access',
						'guides/repair-the-agent',
					],
				},
				{
					label: 'Automation',
					items: ['guides/automate-the-display', 'guides/script-pomme'],
				},
				{
					label: 'Reference',
					items: [
						{
							label: 'Command-line reference',
							collapsed: true,
							items: [{ autogenerate: { directory: 'reference/cli' } }],
						},
						'reference/config-file',
						'reference/structured-output',
						'reference/exit-codes',
						'reference/environment-variables',
						'reference/files-and-paths',
						'reference/key-names',
					],
				},
				{
					label: 'Resources',
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
