# The owner's ZigboxOrg setup

One script, `ops/owner/zigboxorg-setup.sh`, sets up what Zigbox and Zigcube need in the GitHub
organisation `ZigboxOrg` (the old `Zigbox` is suspended). It runs on **your own machine** (macOS or
Linux, bash 3.2 or later), is safe to run again, and ends in one line: `owner-setup: OK ...` or
`owner-setup: FAIL <what to fix>`.

## 1. Tools and logins

| Tool | For | Install |
|---|---|---|
| `git`, `curl`, `jq` | everything | `brew install jq` (the rest ship with macOS) / `apt install git curl jq` |
| `gh` | GitHub | https://cli.github.com, `brew install gh` |
| `gcloud` | Google (section `wif`) | https://cloud.google.com/sdk/docs/install |

```bash
gh auth login        # as an OWNER of ZigboxOrg; scopes repo, workflow, read:org
gh auth status
gcloud auth login    # an account that may change IAM on the Google projects below
```

Get Zigbox:

```bash
git clone https://github.com/ZigboxOrg/zigbox && cd zigbox
```

## 2. Run it

```bash
ops/owner/zigboxorg-setup.sh --dry-run     # read-only: what it would do (still reads GitHub and Google)
ops/owner/zigboxorg-setup.sh               # all sections, asks before each
ops/owner/zigboxorg-setup.sh --only tags   # one section: tags | jepsen | wif | fleet
```

Flags: `--yes` (answer the per-section questions; it never invents a value). Order matters once:
`jepsen` before `wif`.

Secrets are read with no echo or from files, passed on standard input, and never printed or put on
a command line. Values you may set in the environment instead of being asked (none is a secret): `ZBX_GCP_PROJECT`,
`ZBX_GCP_REGION`, `FLEET_TOKEN_FILE`; for names that differ from the docs `JEPSEN_GCP_PROJECT`,
`JEPSEN_GCP_POOL`, `JEPSEN_GCP_PROVIDER`, `ZBX_GCP_POOL`, `ZBX_GCP_PROVIDER`. An empty answer to a value
prompt skips that step and lists it as "still yours".

## 3. What each section does

**tags.** For `zigbox` and `zigcube`: reads the tags of the old `Zigbox/<repo>` (still readable),
fetches those `ZigboxOrg/<repo>` lacks, and pushes them with the same objects (annotated tags stay
annotated). A tag is pushed only if its commit is already on a branch of the new repository (the
`old/*` branches); otherwise it is refused, so no history is invented. Tags that exist at another
object are reported, never moved. `untagged-*` (a draft release's placeholder) is skipped. GitHub
Releases (notes and assets) of the old organisation are not copied. Check:
`gh api repos/ZigboxOrg/zigbox/git/matching-refs/tags --jq '.[].ref'` (v0.3.1 is the one
demo-m8 needs; it fails on ZigboxOrg/zigbox PR 1 without it).

**jepsen.** Creates `ZigboxOrg/zigcube-jepsen` (the old repository's visibility if readable, else
private), pushes `ZigboxOrg/zigcube`'s `old/jepsen/main` as `main` and every other `old/jepsen/X` as
`X` (never overwriting commits it does not know), sets `main` as default, then lists the repository
variables and secrets its workflows read, found in the pushed code, and the ones not set yet.

**Not here: the release plumbing.** The environments (`release`, `release-publish`,
`package-refresh`, Zigcube's `release`), the new Zigbox GPG key, the release GitHub App's id and key,
the Mac secrets, and the copies of `homebrew-tap` and `website` are `release-setup.sh`, which the
supervisor gave you separately. Run it as well (order does not matter, except that `tags` should come
before you enable a `v*` tag ruleset).

**wif.** Needs `gcloud` signed in and `jq`.
- *Jepsen* (project `zigcube-jepsen`, pool `github`, provider `zigcube-jepsen`): reads the
  provider's attribute condition, replaces the old repository id `1455702118` and owner id
  `347124131` by the ids of `ZigboxOrg/zigcube-jepsen` and `ZigboxOrg` (looked up with `gh api`),
  and the old organisation's name by `ZigboxOrg`, shows old and new, and asks before updating it.
  It also copies every IAM grant to a `principalSet`/`principal` naming the old organisation (on the
  project's service accounts and the project) to the new name; the old grants stay.
- *demo-m6d* (Zigbox): asks for a Google project and region (nothing is created without them),
  enables the APIs, creates the pool and provider if missing (condition: repository
  `ZigboxOrg/zigbox` with its id and owner id, on `main`, pull requests and `vm/*`; the spelling of
  the organisation is as GitHub reports it, which Google compares exactly), the Artifact Registry
  repositories `zbx-demo`, `zbx-denied` and `gcr.io` (us), the service account `zbx-pull` (reader on
  `zbx-demo` and `gcr.io` only; impersonation by the new principal set), and sets the four repository
  variables `ZBX_GAR_PROVIDER`, `ZBX_GAR_SERVICE_ACCOUNT`, `ZBX_GAR_REGISTRY`, `ZBX_GCR_REGISTRY`.
  If the provider already exists with another condition it asks before replacing it.

**fleet.** Creates the `sim-fleet` label and the tracking issue "Simulation fleet: seeds per day" in
`ZigboxOrg/zigcube` (and pins it), or finds it, and prints the issue number. The **token is browser
only**: GitHub has no API for fine-grained personal access tokens. https://github.com/settings/personal-access-tokens/new:
resource owner `ZigboxOrg` (the organisation must allow fine-grained tokens, and may have to approve
yours), repository access only `ZigboxOrg/zigcube`, permission Issues: Read and write, expiry as long
as allowed (put the date in your calendar). Save it to a file with mode 600. Give the script that
path and it proves the token reads `zigcube`, reads the tracker, cannot read `zigbox`, and prints its
expiry. It then prints what the fleet host needs: the token file, `SIM_FLEET_TRACKER=<n>`,
`SIM_FLEET_GH_REPO=ZigboxOrg/zigcube` and `SIM_FLEET_REMOTE`, and the redeploy commands. It does not
edit `ops/sim-fleet` (slice C2).

## 4. Final checks, by hand

```bash
gh api repos/ZigboxOrg/zigbox/git/matching-refs/tags/v0.3.1 --jq '.[].ref'
gh api repos/ZigboxOrg/zigcube-jepsen/branches --jq '.[].name'
gh variable list --repo ZigboxOrg/zigbox                        # ZBX_GAR_* (4)
gcloud iam workload-identity-pools providers describe zigcube-jepsen --project zigcube-jepsen --location global --workload-identity-pool github --format='value(attributeCondition)'
gh issue view <N> --repo ZigboxOrg/zigcube --json title,number
```

The real proofs are later: a run of `gcp.yml` in `zigcube-jepsen` authenticates to Google, and the fleet's first tracker post.

## What the script could not know

- The Jepsen provider's exact condition was not in the repositories; the script edits the one it
  reads and refuses (printing it) if it names none of the old ids or names.
- `zigcube-jepsen`'s own variables and secrets: it lists what the pushed workflows read, not what
  they should hold.
- The Google project for demo-m6d does not exist in any document (docs/demos/m6d.md says "the
  owner's Google project"); you choose it. The pool and provider names default to `github` and
  `zigbox`.
- Whether `gh issue pin` and `gh secret list --json` exist in your `gh` (2.40 or later): update `gh`
  if the script says a flag is unknown.
