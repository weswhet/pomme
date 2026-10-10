#!/usr/bin/env node
// Generates the command-line reference pages from the installed CLI's help text,
// so the reference always matches the executable it documents.
//
// Usage: npm run reference
//        POMME_RUNNER=/absolute/path/to/pomme npm run reference

import { execFileSync } from 'node:child_process';
import { mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const runner = process.env.POMME_RUNNER ?? join(homedir(), '.local/bin/pomme');
const outputDir = join(dirname(fileURLToPath(import.meta.url)), '../src/content/docs/reference/cli');

// Commands that the root help omits but that are part of the public interface.
const unlistedCommands = [
	{ name: 'tools', aliases: [] },
	{ name: 'agent-help', aliases: [] },
];

// Descriptions for arguments that the CLI help leaves blank.
const argumentFallbacks = {
	name: 'VM name. Uses `POMME_VM_NAME` when omitted.',
	vm: 'VM name. Uses `POMME_VM_NAME` when omitted.',
	path: 'Path to a config file with a `.json`, `.yaml`, `.yml`, `.toml`, or `.pkl` extension.',
};
const commandArgumentFallbacks = {
	tui: { name: 'VM to open when the terminal UI starts.' },
	'agent status': {},
};

const commonFlagDescriptions = new Map([
	['--json', 'Print JSON output. Equivalent to --format json.'],
	['--format <format>', 'Output format: table, json, or jsonl. (values: table, json, jsonl)'],
	[
		'--debug',
		'Print verbose diagnostics and retain Recovery navigation screenshots in a private temporary directory.',
	],
	['--progress <progress>', 'Progress display: auto, plain, or off. (values: auto, plain, off; default: auto)'],
	['-h, --help', 'Show help information.'],
]);

function help(path) {
	try {
		return execFileSync(runner, [...path, '--help'], { encoding: 'utf8' });
	} catch (error) {
		// Argument parsers commonly exit nonzero after printing help.
		if (error.stdout) return error.stdout;
		throw error;
	}
}

function version() {
	return execFileSync(runner, ['--version'], { encoding: 'utf8' }).trim();
}

/** Splits help text into its uppercase sections. */
function sections(text) {
	const result = { preamble: [] };
	let current = 'preamble';
	for (const line of text.split('\n')) {
		const heading = line.match(/^([A-Z]+):(?: (.*))?$/);
		if (heading) {
			current = heading[1];
			result[current] = heading[2] ? [heading[2]] : [];
		} else {
			result[current].push(line);
		}
	}
	return result;
}

/** Parses an indented two-column block (ARGUMENTS, OPTIONS, SUBCOMMANDS). */
function entries(lines = []) {
	const parsed = [];
	for (const line of lines) {
		if (/^\s*See 'pomme help/.test(line)) break;
		if (!line.trim()) continue;
		// A flag's term can run into its description with a single space when it
		// fills the help column, so terms are matched by shape rather than spacing.
		const start =
			line.match(/^ {2}((?:-[a-zA-Z], )?--?[a-zA-Z][\w-]*(?: <[\w-]+>)?)(?: +(\S.*))?$/) ??
			line.match(/^ {2}(<[\w-]+>)(?: +(\S.*))?$/) ??
			line.match(/^ {2}([a-z][\w-]*(?:, [\w-]+)*(?: \(default\))?)(?: {2,}(\S.*))?$/);
		if (start) {
			parsed.push({ term: start[1].trim(), description: start[2] ?? '' });
		} else if (parsed.length) {
			const last = parsed.at(-1);
			last.description = `${last.description} ${line.trim()}`.trim();
		}
	}
	return parsed;
}

function paragraphs(lines = []) {
	return lines
		.join('\n')
		.trim()
		.split(/\n\s*\n/)
		.map((paragraph) => paragraph.replace(/\s*\n\s*/g, ' ').trim())
		.filter(Boolean);
}

/** Converts `<value-name>` placeholders to the Google style UPPERCASE_NAME form. */
function placeholders(text) {
	return text.replace(/<([a-z][a-z0-9-]*)>/g, (_, name) => name.toUpperCase().replaceAll('-', '_'));
}

/** Formats CLI prose as Markdown, putting flags, variables, and literals in code font. */
function prose(text) {
	return text
		.split(/(`[^`]*`)/)
		.map((part, index) => {
			if (index % 2 === 1) return part;
			return placeholders(part)
				.replace(/'([^']+)'/g, '`$1`')
				.replace(/(^|[\s(/])(--?[a-z][a-z0-9-]*(?: (?:latest|recovery|none|json))?)(?=[\s.,;:)]|$)/g, '$1`$2`')
				.replace(/\b(POMME_[A-Z_]+)\b/g, '`$1`')
				.replace(/\b(NAME:\/absolute\/path)\b/g, '`$1`')
				.replace(/</g, '&lt;')
				.replace(/\|/g, '\\|');
		})
		.join('');
}

/** Splits a trailing `(values: ...; default: ...)` note from a flag description. */
function flagDetails(description) {
	const match = description.match(/\s*\((values: ([^;)]*))?(?:; )?(default: ([^)]*))?\)\s*$/);
	if (!match || (!match[1] && !match[3])) return { text: description };
	return {
		text: description.slice(0, match.index).trim(),
		values: match[2]?.split(',').map((value) => value.trim()),
		defaultValue: match[4]?.trim(),
	};
}

function flagTable(options) {
	const rows = options
		.filter(({ term, description }) => commonFlagDescriptions.get(term) !== description)
		.filter(({ term }) => term !== '-h, --help');
	if (!rows.length) return '';
	const lines = ['| Flag | Description |', '| --- | --- |'];
	for (const { term, description } of rows) {
		const { text, values, defaultValue } = flagDetails(description);
		let cell = prose(text);
		if (values) cell += ` Values: ${values.map((value) => `\`${value}\``).join(', ')}.`;
		if (defaultValue) cell += ` Default: \`${defaultValue}\`.`;
		const flag = placeholders(term)
			.split(', ')
			.map((part) => `\`${part}\``)
			.join(', ');
		lines.push(`| ${flag} | ${cell.trim()} |`);
	}
	return lines.join('\n');
}

function argumentTable(commandPath, args) {
	if (!args.length) return '';
	const fallbacks = { ...argumentFallbacks, ...(commandArgumentFallbacks[commandPath] ?? {}) };
	const lines = ['| Argument | Description |', '| --- | --- |'];
	for (const { term, description } of args) {
		const key = term.replace(/[<>]/g, '');
		const text = description ? prose(description) : (fallbacks[key] ?? '');
		lines.push(`| \`${placeholders(term)}\` | ${text} |`);
	}
	return lines.join('\n');
}

function synopsis(usageLines) {
	return placeholders(usageLines.join(' ').replace(/\s+/g, ' ').trim()).replace(/\[OPTIONS\]/g, '[FLAGS]');
}

/** Renders one command, then recurses into its subcommands. */
function renderCommand(path, depth, out) {
	const text = help(path);
	const parts = sections(text);
	const overview = paragraphs(parts.OVERVIEW);
	const heading = `pomme ${path.join(' ')}`;
	const subcommands = entries(parts.SUBCOMMANDS).filter(({ term }) => term !== 'help');

	if (depth > 0) out.push(`${'#'.repeat(Math.min(depth + 1, 4))} ${heading}`, '');
	for (const paragraph of overview) {
		if (/^Run 'pomme --version'/.test(paragraph)) continue;
		out.push(prose(paragraph), '');
	}
	out.push('```text', synopsis(parts.USAGE ?? []), '```', '');

	const args = argumentTable(path.join(' '), entries(parts.ARGUMENTS));
	if (args) out.push(args, '');
	const options = entries(parts.OPTIONS);
	const flags = flagTable(options);
	if (flags) out.push(flags, '');
	if (options.some(({ term, description }) => term !== '-h, --help' && commonFlagDescriptions.get(term) === description)) {
		out.push('This command also accepts the [common flags](/reference/cli/#common-flags).', '');
	}

	for (const sub of subcommands) {
		const [name] = sub.term.split(',').map((part) => part.trim());
		renderCommand([...path, name.replace(/ \(default\)$/, '')], depth + 1, out);
	}
	return { overview, subcommands };
}

function renderPage(command, order, generatedFrom) {
	const body = [];
	const { overview } = renderCommand([command.name], 0, body);
	const aliasNote = command.aliases.length
		? `Alias: ${command.aliases.map((alias) => `\`pomme ${alias}\``).join(', ')}.\n\n`
		: '';
	const description = overview[0]?.replace(/'/g, '').replace(/"/g, '\\"') ?? '';
	return [
		'---',
		`title: pomme ${command.name}`,
		`description: "${description}"`,
		`sidebar:`,
		`  order: ${order}`,
		'---',
		'',
		`<!-- Generated by scripts/generate-cli-reference.mjs from ${generatedFrom}. Do not edit by hand. -->`,
		'',
		aliasNote + body.join('\n').trim(),
		'',
		'---',
		'',
		`Generated from the help text of ${generatedFrom}.`,
		'',
	].join('\n');
}

function renderIndex(commands, generatedFrom) {
	const rows = commands
		.map(({ name, summary }) => `| [\`pomme ${name}\`](/reference/cli/pomme-${name}/) | ${prose(summary)} |`)
		.join('\n');
	return `---
title: Command-line reference
description: Reference for every pomme command, its arguments, and its flags.
sidebar:
  label: Overview
  order: 0
---

<!-- Generated by scripts/generate-cli-reference.mjs from ${generatedFrom}. Do not edit by hand. -->

This reference describes every \`pomme\` command, generated from the help text
of ${generatedFrom}. To see the same information in a terminal, run
\`pomme help COMMAND\` or \`pomme COMMAND --help\`.

## Commands

| Command | Description |
| --- | --- |
${rows}

## Syntax conventions

The command synopses on these pages use the following conventions.

| Convention | Meaning |
| --- | --- |
| \`UPPERCASE\` | A placeholder that you replace with a value. For example, replace \`NAME\` with the name of a VM. |
| \`[ ]\` | An optional argument or flag. |
| \`...\` | An argument that you can repeat. For example, \`[NAMES ...]\` accepts one or more VM names. |
| \`--\` | The end of \`pomme\` flags. Everything after \`--\` is passed to the guest program. |
| \`[FLAGS]\` | One or more flags described in the command's flag table. |

## Common flags

Most commands accept the following flags. A command's own page lists a flag
only when the command gives it a different meaning.

| Flag | Description |
| --- | --- |
| \`--format FORMAT\` | Output format: \`table\`, \`json\`, or \`jsonl\`. Table output is the default. For details, see [Structured output](/reference/structured-output/). |
| \`--json\` | Print JSON output. Equivalent to \`--format json\`. |
| \`--debug\` | Print verbose diagnostics, and keep screenshots of automatic Recovery navigation in a private temporary directory. |
| \`--progress PROGRESS\` | How to show progress on standard error: \`auto\`, \`plain\`, or \`off\`. The default, \`auto\`, keeps one updating status line when standard error is a terminal, prints one line per step otherwise, and shows nothing when the output format is JSON or JSONL. \`plain\` always prints one line per step. \`off\` shows no progress. |
| \`-h\`, \`--help\` | Show help for the command. |

## VM name resolution

Commands that act on a VM take its name as a positional argument. If you omit
the name, commands that accept an optional VM name use the value of the
\`POMME_VM_NAME\` environment variable. Pomme never picks a VM for you, even if
only one VM is running. For details, see
[Environment variables](/reference/environment-variables/).
`;
}

// The Errors page comes from the executable's error catalog, so each code's
// anchor matches the link that `pomme` prints after an error.
const errorsPage = join(dirname(fileURLToPath(import.meta.url)), '../src/content/docs/reference/errors.md');

function errorCatalog() {
	return JSON.parse(execFileSync(runner, ['--pomme-error-catalog'], { encoding: 'utf8' }));
}

function renderErrors(catalog, generatedFrom) {
	const areas = [];
	for (const entry of catalog) {
		let area = areas.find(({ name }) => name === entry.area);
		if (!area) {
			area = { name: entry.area, entries: [] };
			areas.push(area);
		}
		area.entries.push(entry);
	}
	const body = [];
	for (const area of areas) {
		body.push(`## ${area.name}`, '');
		for (const entry of [...area.entries].sort((a, b) => a.code.localeCompare(b.code))) {
			body.push(`### \`${entry.code}\``, '', entry.title, '', `**Cause:** ${entry.cause}`, '');
			if (entry.resolution.length === 1) {
				body.push(`**Resolution:** ${entry.resolution[0]}`, '');
			} else {
				body.push('**Resolution:**', '', ...entry.resolution.map((step, index) => `${index + 1}. ${step}`), '');
			}
			if (entry.reportable) {
				body.push(
					'This code means that Pomme hit a failure that it doesn\'t expect. Run `pomme bug-report` and attach the file to a [new issue](https://github.com/weswhet/pomme/issues/new?template=bug_report.yml).',
					'',
				);
			}
		}
	}
	return `---
title: Errors
description: Every error code that Pomme reports, what causes it, and how to resolve it.
---

<!-- Generated by scripts/generate-cli-reference.mjs from ${generatedFrom}. Do not edit by hand. -->

When a command fails, Pomme prints what happened, the next step when there is
one, and a stable error code with a link to its entry on this page:

\`\`\`text
Error: No Pomme-owned VM named my-vm exists. Create it with \`pomme create my-vm\` or run \`pomme list\`.
Error code: vm-not-found. For help, see https://pommevm.dev/reference/errors/#vm-not-found
\`\`\`

With \`--format json\` or \`--format jsonl\`, the failed result has the same code in
its \`errorCode\` field, the next step in \`hint\`, and the underlying reasons in
\`causes\`. For details, see [Structured output](/reference/structured-output/).
Codes don't change meaning between releases, so scripts can match on them.

If an error doesn't explain itself, run \`pomme bug-report\` to collect the
details that a maintainer needs into one file.

${body.join('\n').trim()}
`;
}

function main() {
	const generatedFrom = version();
	const root = sections(help([]));
	const commands = [
		...entries(root.SUBCOMMANDS).map(({ term, description }) => {
			const [name, ...aliases] = term.split(',').map((part) => part.trim());
			return { name, aliases, summary: description };
		}),
		...unlistedCommands.map((command) => ({
			...command,
			summary: paragraphs(sections(help([command.name])).OVERVIEW)[0],
		})),
	].filter(({ name }) => name !== 'help');

	mkdirSync(outputDir, { recursive: true });
	for (const file of readdirSync(outputDir)) {
		if (file.endsWith('.md')) rmSync(join(outputDir, file));
	}
	writeFileSync(join(outputDir, 'index.md'), renderIndex(commands, generatedFrom));
	commands.forEach((command, index) => {
		writeFileSync(join(outputDir, `pomme-${command.name}.md`), renderPage(command, index + 1, generatedFrom));
	});
	const catalog = errorCatalog();
	writeFileSync(errorsPage, renderErrors(catalog, generatedFrom));
	console.log(`Wrote ${commands.length + 1} pages from ${generatedFrom} to ${outputDir}`);
	console.log(`Wrote ${catalog.length} error codes to ${errorsPage}`);
}

main();
