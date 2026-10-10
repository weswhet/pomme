---
title: Behind the scenes (about)
description: How the Pomme documentation is organized, which style guide it follows, how to build it locally, and who's narrating.
---

Welcome backstage, Crawler. This page explains how the Pomme documentation is
organized and how to work on it.

:::note[System Disclosure]
You're reading Crawler mode, which the System narrates. The facts, commands,
and tables match the normal pages exactly; only the commentary is new. To read
the same page without the System, switch back to the normal docs. The System
won't take it personally. It will, but it won't say so.
:::

## How the documentation is organized

The documentation separates pages by what you're trying to do. In the
dungeon, each group is a floor:

- **Get started** pages help you install Pomme and create your first VM.
- **Concept** pages explain how Pomme works and why it behaves the way it does.
- **How-to guides** give you the steps to complete one task.
- **Reference** pages list facts to look up, such as commands, flags, fields,
  and exit codes.
- **Resources** include troubleshooting, a glossary, and release notes. The
  troubleshooting page is where Crawlers go after they die, which makes it the
  most visited floor.

## Style

The documentation follows the
[Google developer documentation style guide](https://developers.google.com/style).
The repository file `Website/CONTRIBUTING.md` summarizes the rules that these
pages use most, including page structure, voice, formatting, and a word list.

The site checks prose with [Vale](https://vale.sh/) and the Google style
package. Crawler mode is exempt from the Google style rules, because
exclamation points and a narrator who says "I" are the whole point. Vale still
checks its spelling. The System can't spell its way out of everything.

## Crawler mode

You're in it, Crawler. The switch next to the theme selector turns Crawler
mode on and off. It changes the narration only: commands, flags, examples, and
tables match the [normal pages](/). Pages that the System doesn't retell, such
as the command-line reference, show their normal text under a notice. The
repository file `Website/CRAWLER_VOICE.md` explains how to write and maintain
these pages, in case you want to apply for the System's job. You don't.

## Command-line reference

The [command-line reference](/crawler/reference/cli/) is generated from the help text
of the installed `pomme` executable, so it matches the version that you run.
Each generated page names the version and commit that it came from. The
System doesn't narrate those pages. Help text is sacred, and also very long.

## Build the site locally

The site uses [Starlight](https://starlight.astro.build/), and it's published
at https://pommevm.dev from the `main` branch. To preview a change, build and
view the site on your own Mac. Pushing straight to `main` to see how it looks
publishes it to everyone, so build locally first, Crawler.

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

:::tip[New Achievement! Stagehand]
You built the docs yourself. You've seen how the show is made, and you can
never forget it. Reward: a Bronze Backstage Pass Box. It doesn't open any doors.
:::

## Check and regenerate content

The following commands check and regenerate site content:

| Command | Description |
| --- | --- |
| `npm run lint:style` | Checks every page against the Google style rules. |
| `npm run reference` | Regenerates the command-line reference from `~/.local/bin/pomme`. To use a different executable, set `POMME_RUNNER` to its absolute path. |
| `npm run check:crawler` | Checks that each Crawler mode page keeps the code blocks and tables of its normal page, and that its links stay in Crawler mode. |
| `npm run build` | Builds the static site into `Website/dist` and checks that every page compiles. |
