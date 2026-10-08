---
title: About these docs
description: How the Pomme documentation is organized, which style guide it follows, and how to build it locally.
---

This page explains how the Pomme documentation is organized and how to work
on it.

## How the documentation is organized

The documentation separates pages by what you're trying to do:

- **Get started** pages help you install Pomme and create your first VM.
- **Concept** pages explain how Pomme works and why it behaves the way it does.
- **How-to guides** give you the steps to complete one task.
- **Reference** pages list facts to look up, such as commands, flags, fields,
  and exit codes.
- **Resources** include troubleshooting, a glossary, and release notes.

## Style

The documentation follows the
[Google developer documentation style guide](https://developers.google.com/style).
The repository file `Website/CONTRIBUTING.md` summarizes the rules that these
pages use most, including page structure, voice, formatting, and a word list.

The site checks prose with [Vale](https://vale.sh/) and the Google style
package.

## Command-line reference

The [command-line reference](/reference/cli/) is generated from the help text
of the installed `pomme` executable, so it matches the version that you run.
Each generated page names the version and commit that it came from.

## Build the site locally

The site uses [Starlight](https://starlight.astro.build/), and it's published
at https://pommevm.dev from the `main` branch. To preview a change, build and
view the site on your own Mac.

To build and view the site, do the following:

1. Install [Node.js](https://nodejs.org/).
1. In a terminal, go to the `Website` directory of the Pomme repository:

   ```sh
   cd Website
   ```

1. Install the site's dependencies:

   ```sh
   npm install
   ```

1. Start the development server:

   ```sh
   npm run dev
   ```

1. In a browser, open `http://localhost:4321`.

The development server reloads pages when you save a change. The site's search
box works only in a built site. To build the site and serve the result, run
`npm run build` and then `npm run preview`.

## Check and regenerate content

The following commands check and regenerate site content:

| Command | Description |
| --- | --- |
| `npm run lint:style` | Checks every page against the Google style rules. |
| `npm run reference` | Regenerates the command-line reference from `~/.local/bin/pomme`. To use a different executable, set `POMME_RUNNER` to its absolute path. |
| `npm run build` | Builds the static site into `Website/dist` and checks that every page compiles. |
