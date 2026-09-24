# Bitbucket Cloud pull-request parity

Maintainer record for Firstmate's Bitbucket Cloud provider path.
Operator setup is owned by [configuration.md](configuration.md#bitbucket-cloud-authentication); this document records the implementation boundary and repeatable verification.

## Canonical identity

Only this public URL shape is accepted:

```text
https://bitbucket.org/<workspace>/<repository>/pull-requests/<positive integer>
```

`bin/fm-pr-lib.sh` parses it into provider `bitbucket`, workspace, repository slug, and pull-request number.
It rejects credentials, ports, query strings, fragments, extra path segments, encoded separators, dot segments, control characters, and non-canonical number spellings before any state is written or API call is made.
The corresponding API identity is fixed beneath `https://api.bitbucket.org/2.0/repositories/<workspace>/<repository>/pullrequests/<number>`.

## Credential boundary

`bin/fm-bitbucket-api.sh` is the only bearer-authenticated Bitbucket client entry point, and every request it makes runs through the self-contained launcher `bin/fm-bitbucket-av.sh`, which owns request validation and the curl call.
Each request selects one Secret Name: `BITBUCKET_ACCESS_TOKEN`, or, for a path at or beneath `/2.0/repositories/<workspace>/<repository>`, the name that repository maps to in the home's gitignored `config/bitbucket-repo-tokens`; the helper header owns the map format, and a mapped repository never falls back to the default name.
Credential precedence for the selected name is the ambient environment, then the home's gitignored `.env`, both handed to the tracked launcher on standard input, then an Automic Vault run of the Vault launcher exactly as its shebang declares:

```sh
av inject +BITBUCKET_ACCESS_TOKEN /bin/sh bin/fm-bitbucket-av.sh --secret BITBUCKET_ACCESS_TOKEN ...
```

Automic Vault matches a request to a Blessing only when its Secret Names and injection options equal the blessed shebang's, and a blessed script cannot request a Secret chosen at run time; file-descriptor delivery from inside a blessed script needs fresh approval on every run.
A home that maps repositories therefore renders a per-home copy, `config/bitbucket-av.sh`, with `fm-bitbucket-api.sh render-launcher`: the tracked launcher's body under a shebang declaring `--allow-missing-keys`, `BITBUCKET_ACCESS_TOKEN`, and every mapped name, which keeps home-specific Secret Names out of the tracked file.
The helper derives Automic Vault's arguments from the chosen launcher's own shebang, so the request always equals the declaration, and refuses a selected name that shebang does not declare before asking Automic Vault.
The launcher's `--secret` selects among its declared names, refuses any other, and unsets every declared name before curl runs.
Keeping every Vault-backed request in that one rarely-changing file is what lets an operator bless it once per mapping change; the operator procedure is in [configuration.md](configuration.md#blessing-the-automic-vault-launcher).
The helper validates a request with the launcher's `--check` mode before choosing a credential source, so a refused request never prompts for Vault approval.
Neither script places the token in argv, a child environment, or a temporary file.
The launcher sends a curl configuration on standard input containing the fixed HTTPS URL, bearer header, method, and timeouts.
Its only write is `POST /2.0/repositories/<workspace>/<repository>/pullrequests` with a JSON body file, which creates a pull request; merge code has no merge POST primitive to invoke after the atomic-head check refuses submission.
API failures remain failures and response bodies are not converted into successful observations.

`fm_detect_forge_usage` derives applicable providers from project origins and durable delivery records.
Bootstrap requires and version-checks `gh` and `gh-axi`, and runs `gh auth status`, only when that evidence includes GitHub.
Bitbucket evidence instead requires `curl` and `jq` and runs the authenticated `GET /2.0/user` probe during the deferred startup network stage.
A mixed home runs both probes; a home using neither runs neither provider probe.

## Supported lifecycle

The provider-neutral pull-request record and watcher remain unchanged.
Bitbucket Cloud supplies these provider-specific reads:

| Lifecycle operation | Bitbucket API or git evidence |
| --- | --- |
| ready registration | pull-request object; refuses drafts and records `source.commit.hash` resolved to a full hash |
| merge monitoring | pull-request `state`, with success only for exact `MERGED` |
| current task state | pull-request object, open tasks, build statuses, and reviewer `changes_requested` participation |
| review diff | `refs/pull-requests/<number>/from`, with recorded exact head only as the offline fallback |
| cleanup | live `MERGED` state plus the live source commit, then the existing ancestry/content proof; the backlog close records the URL as a `PR <url>` task-body line |
| contribution observation | pull-request object, reviewers/participants, build statuses, and reviewer comments |

The pull-request object abbreviates `source.commit.hash` to twelve hex characters, so every read of the source head, including both contribution-observation reads, resolves it through `/2.0/repositories/<workspace>/<repository>/commit/<hash>` before recording or comparing it.
`fm_pr_bitbucket_resolve_head` in [`bin/fm-pr-lib.sh`](../bin/fm-pr-lib.sh) owns that canonicalization and its refusal rules; `fm_pr_head_valid` stays strict so a stored `pr_head=` is never ambiguous.
The same repository-scoped read token covers the commit endpoint, so the credential contract does not change.

`tasks-axi` accepts only a `/pull/<number>` URL as a task's pr link, so `fm_backlog_done` in [`bin/fm-backlog-transition-lib.sh`](../bin/fm-backlog-transition-lib.sh) records any other pull-request URL as the task-body line `PR <url>`; the pending-close record keeps the `--pr` flag, so a crash replay closes the task with the same line.

Contribution reads request 100 comments and statuses.
A response with a `next` page is deliberately rejected as incomplete rather than letting bounded observation look exhaustive.
Bitbucket does not expose GitHub's mergeability verdict in the same shape, so contribution classification leaves mergeability unknown and does not invent maintainer or captain authority from it.

## Merge submission boundary

The guarded merge path validates the canonical URL, records and arms monitoring, and performs live checks for:

- exact source head;
- open and non-draft state;
- no unresolved pull-request tasks;
- no failed, stopped, or in-progress build statuses;
- no reviewer change request; and
- a second exact-source-head read immediately before submission.

The documented Bitbucket Cloud merge endpoint accepts merge strategy, message, and source-branch closure controls, but no expected source commit comparable to GitHub's `--match-head-commit` or GitLab's `--sha`.
A read followed by POST would therefore leave a race in which a changed source head could be merged after Firstmate verified the old one.
`bin/fm-pr-merge.sh` refuses before the POST and leaves exact merged-state monitoring armed.
This is intentional provider parity at the strongest invariant the API supports, not a silent downgrade.
An operator can merge in Bitbucket; the monitor then confirms `MERGED`, publishes the ordinary merge outcome, and permits cleanup.

## Verification

Run the focused provider and integration suites from the repository root:

```sh
bin/fm-test-run.sh \
  tests/fm-bitbucket-cloud.test.sh \
  tests/fm-review-diff.test.sh \
  tests/fm-contributions.test.sh \
  tests/fm-teardown.test.sh \
  tests/fm-bootstrap.test.sh
```

The fixtures prove ambient-token, `.env`, and Automic Vault transport through the launcher without argv or environment leakage, source precedence, per-repository Secret selection through the rendered launcher with no fallback to the default token, refusal of malformed mappings and undeclared Secret Names, pull-request creation, refusal of invalid requests before any Vault approval or curl call, strict URL rejection, exact merged polling, head capture, state/blocker rendering, provider git-ref selection, contribution checks/reviews/comments, cleanup of a confirmed landed head, conditional GitHub tooling, conditional Bitbucket authentication diagnostics, refusal on red builds and head movement, and the no-atomic-head merge refusal.
The tests use byte-controlled fake API responses and do not claim live Bitbucket credentials or a live destructive merge.
