# Pomme documentation site

This directory contains the Pomme documentation site, built with
[Starlight](https://starlight.astro.build/). Cloudflare Pages publishes it at
<https://pommevm.dev> from the `main` branch.

```sh
cd Website
npm install
npm run dev        # open http://localhost:4321
```

The pages live in `src/content/docs/`. They follow the
[Google developer documentation style guide](https://developers.google.com/style);
see [CONTRIBUTING.md](CONTRIBUTING.md) for the conventions, the build and lint
commands, and how to regenerate the command-line reference.
