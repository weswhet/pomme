import { defineCollection } from 'astro:content';
import { docsLoader, i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';

export const collections = {
	docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
	// UI strings for Crawler mode live in src/content/i18n/en-x-crawler.json.
	i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
};
