# What the engineer must do by hand

Everything else in this template is machinery; these are the steps machinery
cannot do, either because they need credentials only a human holds or because
they are per-project judgment calls. Work through them once when adopting the
template, in order.

## 1. Repo settings — `./scripts/setup.sh`

Renames the project after your repository and enables the GitHub settings
templates cannot carry over: secret scanning, push protection, private
vulnerability reporting, Dependabot alerts + security updates, and branch
protection requiring the CI checks. Needs the `gh` CLI authenticated as an
admin of the repo.

## 2. Dependency automerge — one setting, one token

- Enable **Settings → General → Allow auto-merge** on the repository.
- Create a fine-grained personal access token
  (github.com/settings/personal-access-tokens): repository access limited to
  this repo (add it to an existing fleet token if you have one), permissions
  **Contents: read/write** and **Pull requests: read/write**. Store it:

  ```bash
  gh secret set DEPENDABOT_AUTOMERGE_TOKEN --repo <owner>/<repo>
  ```

  A PAT rather than `GITHUB_TOKEN` on purpose: merges performed with
  `GITHUB_TOKEN` trigger no workflows, so the default branch would run no CI
  or deploy on the dependency it just took. Until both the setting and the
  secret exist, the automerge workflow warns and does nothing. When the
  token expires (set an expiry; ~90 days), CI on the next Dependabot PR goes
  red — that is the renewal reminder, not a mystery failure. Note the
  token's *repository access list* is part of the setup: a token that exists
  but does not cover this repo fails with "Resource not accessible", which
  reads as red CI on every Dependabot PR.

## 3. Deploy — copy `deploy.yml.example` and wire the cloud

- Azure: create the app registration with **OIDC federated credentials**
  (no client secret) — both subject formats, `repo:<owner>/<repo>:ref:...`
  and `:environment:...` if you use environments. See `docs/deploying.md`.
- Cloudflare (only if you proxy the site through it):
  - a cache rule that edge-caches HTML (Edge TTL override; browser TTL
    respects origin) — safe **only** together with the purge job;
  - an API token with **Zone → Cache Purge** on the zone, stored with the
    zone id:

    ```bash
    gh secret set CLOUDFLARE_PURGE_TOKEN --repo <owner>/<repo>
    gh secret set CLOUDFLARE_ZONE_ID --repo <owner>/<repo>
    ```

  Without the secrets the purge job warns and skips; with the cache rule but
  no purge, deploys serve stale pages for up to the rule's TTL.

## 4. .NET major upgrades — close and reopen the PR

The monthly `dotnet-major-upgrade` workflow opens its PR with the default
token, and workflow-opened PRs do not start checks on their own. Close and
reopen that PR once to trigger CI on it; merge on green.

## 5. Prerendering — keep the route list honest

`client/src/prerenderedRoutes.ts` lists the routes baked to HTML at build
time. When you add a page whose content is the same for every visitor
between deploys, add its route there — that is the entire step. Never list a
page that shows live or per-visitor data; its snapshot would open stale. The
day you add a client-side router, wrap the app in its static router inside
`client/src/entry-server.tsx` and the matching browser router in
`client/src/main.tsx` — both entries must compose the same tree, because
hydration compares the prerendered markup against it.
