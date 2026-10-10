#!/usr/bin/env node
// Checks that Crawler mode pages (src/content/docs/crawler/) still match the
// facts of the normal pages they retell. See CRAWLER_VOICE.md.
//
// Fails when a crawler page:
// - has no matching normal page, or retells a generated page,
// - has fenced code blocks or tables that differ from its normal page,
// - is missing a title or description, or changes other frontmatter keys,
// - links to an internal page outside /crawler/, or to a page or #anchor that
//   doesn't exist.
//
// Warns, without failing, when a normal page has a newer git commit than its
// crawler page, and lists normal pages that fall back to the normal text.

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import GithubSlugger from 'github-slugger';

const websiteDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const docsDir = join(websiteDir, 'src/content/docs');
const crawlerDir = join(docsDir, 'crawler');
const publicDir = join(websiteDir, 'public');

// Links that intentionally leave Crawler mode, such as the overview's link to
// the normal docs.
const allowedNormalLinks = new Set(['/']);

const errors = [];
const warnings = [];

function listPages(dir) {
	const pages = [];
	for (const name of readdirSync(dir)) {
		const path = join(dir, name);
		if (statSync(path).isDirectory()) pages.push(...listPages(path));
		else if (/\.mdx?$/.test(name)) pages.push(path);
	}
	return pages;
}

/** Split a page into frontmatter lines and body text. */
function splitFrontmatter(text) {
	const match = text.match(/^---\n([\s\S]*?)\n---\n?/);
	if (!match) return { frontmatter: '', body: text };
	return { frontmatter: match[1], body: text.slice(match[0].length) };
}

/** Top-level frontmatter keys mapped to their raw text (key line plus nested lines). */
function frontmatterEntries(frontmatter) {
	const entries = new Map();
	let key;
	for (const line of frontmatter.split('\n')) {
		const top = line.match(/^([A-Za-z][\w-]*):/);
		if (top) {
			key = top[1];
			entries.set(key, line);
		} else if (key) {
			entries.set(key, `${entries.get(key)}\n${line}`);
		}
	}
	return entries;
}

function dedent(lines) {
	const indents = lines.filter((l) => l.trim()).map((l) => l.match(/^\s*/)[0].length);
	const min = indents.length ? Math.min(...indents) : 0;
	return lines.map((l) => l.slice(min)).join('\n');
}

/**
 * Extract fenced code blocks, tables, and the remaining prose lines. Code
 * blocks and tables are compared after removing their common indentation, so
 * that moving a block into or out of a list item doesn't count as a change.
 */
function parseBody(body) {
	const lines = body.split('\n');
	const codeBlocks = [];
	const tables = [];
	const prose = [];
	let i = 0;
	while (i < lines.length) {
		const fence = lines[i].match(/^(\s*)(`{3,}|~{3,})(.*)$/);
		if (fence) {
			const marker = fence[2];
			const block = [lines[i]];
			i++;
			while (i < lines.length && !new RegExp(`^\\s*${marker[0]}{${marker.length},}\\s*$`).test(lines[i])) {
				block.push(lines[i]);
				i++;
			}
			if (i < lines.length) block.push(lines[i]);
			codeBlocks.push(dedent(block));
			i++;
			continue;
		}
		if (/^\s*\|/.test(lines[i])) {
			const table = [];
			while (i < lines.length && /^\s*\|/.test(lines[i])) {
				table.push(lines[i]);
				i++;
			}
			tables.push(dedent(table));
			continue;
		}
		prose.push(lines[i]);
		i++;
	}
	return { codeBlocks, tables, prose: prose.join('\n') };
}

/** Heading anchors as Starlight generates them. */
function headingSlugs(body) {
	const slugger = new GithubSlugger();
	const slugs = new Set();
	for (const line of parseBody(body).prose.split('\n')) {
		const heading = line.match(/^#{1,6}\s+(.*?)\s*#*\s*$/);
		if (!heading) continue;
		const text = heading[1]
			.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
			.replace(/[`*]/g, '')
			.replace(/<[^>]+>/g, '');
		slugs.add(slugger.slug(text));
	}
	return slugs;
}

/** Map a site path such as /guides/use-snapshots/ to a page file, if any. */
function pageForPath(pathname) {
	const slug = pathname.replace(/^\/+|\/+$/g, '');
	const candidates = slug
		? [`${slug}.md`, `${slug}.mdx`, `${slug}/index.md`, `${slug}/index.mdx`]
		: ['index.md', 'index.mdx'];
	for (const candidate of candidates) {
		const path = join(docsDir, candidate);
		if (existsSync(path)) return path;
	}
	return undefined;
}

/** Resolve a crawler path to its crawler page, or to the normal page it falls back to. */
function resolveCrawlerPath(pathname) {
	const page = pageForPath(pathname);
	if (page) return page;
	return pageForPath(pathname.replace(/^\/crawler(?=\/|$)/, ''));
}

/** Files in public/, such as /install.pl, aren't pages and have no crawler version. */
function isPublicFile(pathname) {
	const path = join(publicDir, pathname);
	return existsSync(path) && statSync(path).isFile();
}

const slugCache = new Map();
function slugsFor(page) {
	if (!slugCache.has(page)) {
		slugCache.set(page, headingSlugs(splitFrontmatter(readFileSync(page, 'utf8')).body));
	}
	return slugCache.get(page);
}

/** Internal links from Markdown links, MDX/HTML href attributes, and hero `link:` keys. */
function internalLinks(text) {
	const links = [];
	const patterns = [/\]\((\/[^)\s]*|#[^)\s]*)\)/g, /href=["'](\/[^"']*|#[^"']*)["']/g, /^\s*link:\s*["']?(\/[^"'\s]*)/gm];
	for (const pattern of patterns) {
		for (const match of text.matchAll(pattern)) links.push(match[1]);
	}
	return links;
}

/** Pages that scripts/generate-cli-reference.mjs writes always fall back. */
function isGenerated(text) {
	return text.includes('<!-- Generated by scripts/generate-cli-reference.mjs');
}

function gitTime(path) {
	try {
		const out = execFileSync('git', ['log', '-1', '--format=%ct', '--', path], {
			cwd: websiteDir,
			encoding: 'utf8',
		}).trim();
		return out ? Number(out) : undefined;
	} catch {
		return undefined;
	}
}

function checkPage(crawlerPage) {
	const rel = relative(crawlerDir, crawlerPage);
	const label = `crawler/${rel}`;
	const normalPage = join(docsDir, rel);
	if (!existsSync(normalPage)) {
		errors.push(`${label}: no matching normal page at ${relative(websiteDir, normalPage)}`);
		return;
	}

	const crawlerText = readFileSync(crawlerPage, 'utf8');
	const normalText = readFileSync(normalPage, 'utf8');
	if (isGenerated(normalText)) {
		errors.push(`${label}: ${rel} is generated, so it falls back instead; delete the crawler page`);
		return;
	}
	const crawler = splitFrontmatter(crawlerText);
	const normal = splitFrontmatter(normalText);

	// Frontmatter: voice title and description; keep everything else.
	const crawlerFm = frontmatterEntries(crawler.frontmatter);
	const normalFm = frontmatterEntries(normal.frontmatter);
	for (const key of ['title', 'description']) {
		if (normalFm.has(key) && !crawlerFm.has(key)) errors.push(`${label}: frontmatter is missing \`${key}\``);
	}
	for (const [key, value] of normalFm) {
		if (key === 'title' || key === 'description' || key === 'hero') continue;
		if (crawlerFm.get(key) !== value) errors.push(`${label}: frontmatter \`${key}\` differs from the normal page`);
	}
	for (const key of crawlerFm.keys()) {
		if (!normalFm.has(key)) errors.push(`${label}: frontmatter \`${key}\` isn't on the normal page`);
	}

	// Facts: code blocks and tables must match exactly, in order.
	const crawlerParts = parseBody(crawler.body);
	// Links inside tables point into Crawler mode, so ignore that prefix.
	crawlerParts.tables = crawlerParts.tables.map((table) => table.replace(/\]\(\/crawler(?=\/)/g, ']('));
	const normalParts = parseBody(normal.body);
	for (const [kind, a, b] of [
		['code block', crawlerParts.codeBlocks, normalParts.codeBlocks],
		['table', crawlerParts.tables, normalParts.tables],
	]) {
		if (a.length !== b.length) {
			errors.push(`${label}: has ${a.length} ${kind}s; the normal page has ${b.length}`);
		}
		const n = Math.min(a.length, b.length);
		for (let i = 0; i < n; i++) {
			if (a[i] !== b[i]) {
				const firstLine = b[i].split('\n').find((l, j) => l !== a[i].split('\n')[j]) ?? '';
				errors.push(`${label}: ${kind} ${i + 1} differs from the normal page (near: ${firstLine.trim().slice(0, 80)})`);
				break;
			}
		}
	}

	// Links: stay in Crawler mode, and point at real pages and headings.
	for (const link of internalLinks(crawlerText)) {
		const [pathname, fragment] = link.split('#');
		let target = crawlerPage;
		if (pathname) {
			if (allowedNormalLinks.has(pathname) || isPublicFile(pathname)) continue;
			if (!/^\/crawler(\/|$)/.test(pathname)) {
				errors.push(`${label}: link ${link} leaves Crawler mode; use /crawler${pathname}`);
				continue;
			}
			target = resolveCrawlerPath(pathname);
			if (!target) {
				errors.push(`${label}: link ${link} points to a page that doesn't exist`);
				continue;
			}
		}
		if (fragment && !slugsFor(target).has(fragment)) {
			errors.push(`${label}: link ${link} points to a heading that doesn't exist in ${relative(docsDir, target)}`);
		}
	}

	const crawlerTime = gitTime(crawlerPage);
	const normalTime = gitTime(normalPage);
	if (crawlerTime && normalTime && normalTime > crawlerTime) {
		warnings.push(`${label}: ${rel} has a newer commit; check that the crawler page still matches it`);
	}
}

if (!existsSync(crawlerDir)) {
	console.error('No crawler pages found in src/content/docs/crawler/.');
	process.exit(1);
}

const crawlerPages = listPages(crawlerDir);
for (const page of crawlerPages) checkPage(page);

const covered = new Set(crawlerPages.map((p) => relative(crawlerDir, p)));
const fallbacks = listPages(docsDir)
	.map((p) => relative(docsDir, p))
	.filter((rel) => !rel.startsWith('crawler/') && !covered.has(rel))
	.filter((rel) => !isGenerated(readFileSync(join(docsDir, rel), 'utf8')));

for (const warning of warnings) console.warn(`warning: ${warning}`);
if (fallbacks.length) {
	console.warn(`note: ${fallbacks.length} hand-written page(s) fall back to the normal text:`);
	for (const rel of fallbacks) console.warn(`  ${rel}`);
}
for (const error of errors) console.error(`error: ${error}`);

console.log(`Checked ${crawlerPages.length} crawler page(s): ${errors.length} error(s), ${warnings.length} warning(s).`);
process.exit(errors.length ? 1 : 0);
