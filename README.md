# sythos.github.io

This repository is the required publishing source for [https://sythos.github.io/](https://sythos.github.io/).

GitHub Pages serves the static site from this repository. The published site is built with HTML5 and CSS only; project pages, crawler metadata, localized pages, and the sitemap are kept here.

The `sythos.github.io` repository is intentionally excluded from its own portfolio index and project pages.

## IndexNow

The `.github/workflows/indexnow.yml` workflow can submit the canonical URLs in `sitemap.xml` to IndexNow when launched manually from GitHub Actions after a successful Pages deployment. A local PowerShell helper is maintained outside the published checkout at `F:\Dev\sythosgithubio\tools\submit-indexnow.ps1` and supports `-DryRun` for inspection.
