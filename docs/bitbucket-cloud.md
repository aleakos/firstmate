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

`bin/fm-bitbucket-api.sh` is the only bearer-authenticated Bitbucket client.
Credential precedence is the ambient `BITBUCKET_ACCESS_TOKEN`, then the home's gitignored `.env`, then an Automic Vault reinvocation:

```sh
av inject +BITBUCKET_ACCESS_TOKEN -- bin/fm-bitbucket-api.sh ...
```

The helper never places the token in argv or a temporary file.
It sends a curl configuration on standard input containing the fixed HTTPS URL, bearer header, GET method, and timeouts.
The transport is read-only; merge code has no POST primitive to invoke after the atomic-head check refuses submission.
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
| ready registration | pull-request object; refuses drafts and records `source.commit.hash` |
| merge monitoring | pull-request `state`, with success only for exact `MERGED` |
| current task state | pull-request object, open tasks, build statuses, and reviewer `changes_requested` participation |
| review diff | `refs/pull-requests/<number>/from`, with recorded exact head only as the offline fallback |
| cleanup | live `MERGED` state plus the live source commit, then the existing ancestry/content proof |
| contribution observation | pull-request object, reviewers/participants, build statuses, and reviewer comments |

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

The fixtures prove ambient-token and Automic Vault transport without argv leakage, strict URL rejection, exact merged polling, head capture, state/blocker rendering, provider git-ref selection, contribution checks/reviews/comments, cleanup of a confirmed landed head, conditional GitHub tooling, conditional Bitbucket authentication diagnostics, refusal on red builds and head movement, and the no-atomic-head merge refusal.
The tests use byte-controlled fake API responses and do not claim live Bitbucket credentials or a live destructive merge.
