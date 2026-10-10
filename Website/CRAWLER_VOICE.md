# Crawler mode voice guide

Crawler mode is a playful retelling of the Pomme documentation at
`/crawler/`. The reader is a contestant in a dungeon run by a cheerful,
sarcastic System AI that narrates the docs for an audience of viewers and
sponsors. The facts are identical to the normal pages. Only the narration
changes.

Crawler mode is a Starlight locale (`crawler`, `lang: en-x-crawler`). Each page
in `src/content/docs/crawler/` mirrors the normal page at the same relative
path. A normal page without a crawler version falls back to its normal text
under a System notice. Pages that `scripts/generate-cli-reference.mjs` writes, the command-line reference and the Errors page, always fall back this way, and the check refuses crawler copies of them.

This voice is an original homage to dungeon-crawler game shows in general. It
doesn't borrow from any particular book, show, or game.

## Rules

### Facts don't change

Keep these byte-identical to the normal page, in the same order:

- Fenced code blocks: commands, output samples, config files, and JSON.
- Tables, including every cell.
- Command names, flags, defaults, file paths, environment variables, error
  codes, and version numbers, wherever they appear in prose.

`npm run check:crawler` fails when a crawler page's code blocks or tables
differ from its normal page.

Every warning, prerequisite, and limitation in the normal page appears in the
crawler page. Don't drop a caution because it isn't funny.

### Clarity comes first

Every instruction is as clear as it is on the normal page. The snark goes
around the steps, never into them:

- Keep numbered steps numbered, and keep one action per step.
- Put the joke in the sentence before or after the step, or in an aside.
- Keep the "Replace the following" lists for placeholders, and keep them
  accurate.
- When a sentence explains why something matters, keep the explanation.

A reader who ignores every joke must still be able to follow the page.

### Headings

You can voice headings. Keep them short and specific, so that the table of
contents still works as navigation: "Before you begin" can become "Before you
descend", but not "A thing happens". `npm run check:crawler` verifies that
every `#anchor` link in a crawler page points to a heading that exists.

### Frontmatter

Voice the `title` and `description`. Keep every other frontmatter key from the
normal page, such as `template`, `hero`, `sidebar`, and `tableOfContents`.
The sidebar shows the title, so keep it short enough to fit.

### Links

Point internal links at `/crawler/...`, so that readers stay in Crawler mode:
`[Use snapshots](/crawler/guides/use-snapshots/)`. Pages that fall back, such
as `/crawler/reference/cli/pomme-create/`, work too. Keep external links
unchanged.

## Devices

Use a few of these per page. A page that's all bits and no docs is worse than
the normal page.

- **The reader is "Crawler".** "Run this command, Crawler." Use it a few times
  per page, not every sentence.
- **System notifications.** Starlight asides render as System notices in
  Crawler mode, and the default labels are already voiced. Give them a custom
  label when it's funnier:

  ```md
  :::tip[New Achievement! Snapshot Hoarder]
  You saved a snapshot before breaking something. The viewers are
  disappointed. Reward: a Bronze Patience Box.
  :::
  ```

- **Achievements and loot.** Award achievements for finishing tasks, with a
  reward line: "Reward: a Bronze Patience Box." Boxes come in Bronze, Silver,
  Gold, and Legendary tiers, and usually contain something useless.
- **Death notices.** Frame `:::danger` and serious `:::caution` asides as what
  happens to Crawlers who ignore them, and then state the actual risk plainly.
- **The audience.** Viewers who want to watch you fail, sponsors who send
  unhelpful gifts, and ratings that drop when things go smoothly.
- **The System's personality.** Cheerful, a little bored, contractually
  obligated to help you, and openly hoping for drama. It compliments the
  reader backhandedly and complains about its working conditions.
- **Floors.** The sidebar groups are floors of the dungeon. The guest VM is
  "the box" only in jokes; the word list in `CONTRIBUTING.md` still applies to
  facts.

## Hard limits

- Don't use characters, quotes, place names, catchphrases, or trademarks from
  any book, show, or game.
- Don't mock real people, companies, or products, including Apple.
- Keep it fit for a product site: no slurs, sexual content, gore, or
  profanity stronger than "damn".
- Don't make security guidance sound optional. Jokes about SIP, AMFI, MDM, and
  credentials must leave the warning intact.

## Keep the crawler pages current

When you change a hand-written page, update its crawler page in the same
change, or delete the crawler page so that it falls back to the normal text.
Never leave a crawler page that contradicts the facts.

`npm run check:crawler` warns when a normal page has a newer commit than its
crawler page. Run it, along with `npm run build`, before you finish.

Vale doesn't apply the Google style to crawler pages, because exclamation
points and the System's first person are the point. It still checks spelling.
