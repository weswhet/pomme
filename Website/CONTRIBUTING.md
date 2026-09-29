# Contributing to the Pomme documentation

The Pomme documentation follows the
[Google developer documentation style guide](https://developers.google.com/style).
This file summarizes the rules that come up most often in these pages. When
this file and the Google guide disagree, follow the Google guide and fix this
file.

## Run the site locally

```sh
cd Website
npm install
npm run dev        # http://localhost:4321, reloads on save
npm run build      # static output in Website/dist
npm run preview    # serve the built site locally
npm run lint:style # check prose against the Google style rules with Vale
npm run reference  # regenerate the command-line reference
npm run tailnet    # build and serve to your tailnet at https://HOST.TAILNET.ts.net/
npm run tailnet:stop
```

`npm run tailnet` builds the site for this Mac's MagicDNS name, runs a static
server on `127.0.0.1:4321`, and points `tailscale serve` at it. You can open
either `https://HOST.TAILNET.ts.net/` or `http://TAILSCALE_IP/`. The site is
reachable only from your tailnet (it doesn't use Funnel). The preview server
doesn't survive a restart, so run `npm run tailnet` again after you log in.

The command-line reference in `src/content/docs/reference/cli/` is generated
from the installed CLI's help text. Don't edit those files by hand. Build and
install the CLI first (`rtk proxy bash Scripts/build-local.sh` from the
repository root), then run `npm run reference`. To document a different
executable, set `POMME_RUNNER` to its absolute path.

## Page types

Every page is one of these types. Keep types separate: a how-to guide links to
a concept instead of explaining it at length.

| Type | Purpose | Title form | Location |
| --- | --- | --- | --- |
| Overview | What Pomme is and where to start. | Noun phrase | `index.mdx` |
| Get started | Requirements, installation, and a first task. | Noun phrase or verb | `get-started/` |
| Concept | How something works and why. | Noun phrase, such as "Guest agent" | `concepts/` |
| How-to guide | Steps to complete one task. | Bare infinitive, such as "Create a VM" | `guides/` |
| Reference | Facts to look up: commands, schemas, codes. | Noun phrase | `reference/` |
| Troubleshooting | Symptom, cause, and resolution. | Noun phrase | `resources/` |

### How-to guide structure

1. A one- or two-sentence introduction that says what the reader accomplishes.
2. `## Before you begin`: prerequisites as a bulleted list.
3. One `##` section per task, titled with a bare infinitive ("Create a
   template"). Each task starts with a sentence that states the goal, followed
   by numbered steps when there is more than one action.
4. `## What's next`: a bulleted list of related pages.

## Voice and tone

- Address the reader as "you". Use the imperative for instructions.
- Use present tense. Write "Pomme creates", not "Pomme will create".
- Use active voice. Make clear who or what performs the action.
- Be conversational but precise. Don't use "please", "simply", "just",
  "easy", or "obviously".
- Don't use "we" to mean the Pomme project. Name the product instead.
- Don't use Latin abbreviations. Write "for example", "that is", and "and so
  on" instead of "e.g.", "i.e.", and "etc.".
- Put conditions before instructions: "To resume creation, run ...", "If the
  agent is disconnected, run ...".

## Formatting

- Use sentence case for titles and headings. Don't end headings with
  punctuation.
- Use numbered lists for sequential steps and bulleted lists for everything
  else. Introduce every list with a complete sentence that ends in a colon.
- Use the serial (Oxford) comma.
- Put commands, flags, file names, paths, environment variables, key names,
  literal values, and output in code font. Don't use code font for product
  names such as Pomme, macOS, Xcode, or Virtualization.framework.
- Write placeholders in uppercase with underscores, such as `VM_NAME` and
  `TEMPLATE_NAME`. After a code sample that contains placeholders, explain each
  one in a "Replace the following:" list.
- Give code blocks a language (`sh`, `text`, `json`, `yaml`, `toml`). Don't
  include a shell prompt (`$`) in commands that the reader copies. Show output
  in a separate `text` block.
- Use the Starlight asides for notices, and use them sparingly:
  `:::note` for useful extra information, `:::caution` for possible data loss
  or a surprising result, and `:::danger` for irreversible harm.
- Use descriptive link text. Link to the page title or describe the
  destination; never write "click here" or "this page".
- Write dates as "September 28, 2026" and sizes as "40 GB" in prose. Keep the
  CLI's own spelling, such as `40GB`, in code.

## Word list

| Use | Don't use |
| --- | --- |
| VM, virtual machine | box, instance (for a Pomme VM) |
| host (the Mac that runs Pomme) | local machine, hypervisor |
| guest (the macOS inside a VM) | client |
| guest agent | daemon (except when describing launchd) |
| Recovery (the macOS Recovery environment) | recovery mode (lowercase) |
| restore image, IPSW | firmware, installer image |
| template | golden image, base image |
| start, stop, pause, resume | spin up, tear down, kill (except for `jobs kill`) |
| select | click on, hit |
| turn on, turn off (a setting) | enable, disable (except for command names) |
| terminal session | tty, PTY session (in prose) |

## Accuracy rules for Pomme

- Describe the behavior of the current source and the installed CLI. When the
  engineering records in `Docs/` disagree with the source, the source wins.
- Pomme is pre-release (version 0.1.0). Don't describe publication, notarized
  packages, or Homebrew installation as available.
- Don't document hidden or internal commands, internal environment variables,
  or private protocol details that a user can't act on.
- Never include real credentials, host names, serial numbers, or UUIDs from a
  live machine. Use clearly fake values in examples.
