# Change 020: Stop the dedup self-heal from rewriting a blob whose presence is unknown

Change 001 made file-upload deduplication self-healing: when a duplicate
upload matches an existing `FileRef`, `ensureBlobPresent` checks that the blob
is still in the `BlobStore` and re-stores it if it is gone. One branch of that
helper goes too far: when the **existence check itself errors**, it logs a
warning, treats the blob as missing and re-stores it. On a local disk an extra
rename is harmless; on a remote object store (S3, change 017) a transient
`HEAD` failure now triggers a blind `PUT` that overwrites an object nobody
looked at and pays for the transfer, for every retry. The maintainer's review
of the S3 work asked to "adjust it so that it doesn't rewrite stuff". This
change keeps the self-heal for a *confirmed* missing blob and fails the request
when presence is *unknown*.

```yaml spec
issue: adhoc:dedup-no-blind-rewrite
kind: bug
touches: [file-upload]
breaking: false
new-dependency: false
new-capability: false
new-extension-point: false
```

## Contract delta

Internal-only fix inside the non-exported helper `ensureBlobPresent` in
`Service.FileUpload.Web`. No public signature changes.

```diff signatures
```

### Behavior

| `exists` result | Before (change 001) | After |
|---|---|---|
| `Ok True` | return existing ref | unchanged |
| `Ok False` | `Log.warn`, re-`store`, return ref | unchanged |
| `Err e` | `Log.warn`, treat as missing, re-`store` | `Log.critical` with the real error, **no store call**, request fails with the generic message `"Failed to verify stored file content. Please retry."` (same S8 convention as the existing re-store failure path: detail in the server log only) |

The 23505 concurrent-race retry branches in `normalUploadFlow` are untouched;
they call the same helper and inherit the new rule. That path still writes
(and then best-effort deletes) its own provisional blob before the retry
lookup reaches the helper; the guarantee here is only that the deduplicated
existing blob is never rewritten on unknown presence.

## Criteria

`kind: bug`: C1 is the reproduction. It replaces the test
`dedup self-heals when the existence check errors` from change 001 (C4 there),
whose expectation encoded the behavior this change removes. **Rewording an
existing expectation requires maintainer approval** (AGENTS.md
non-negotiable; `scripts/guards/expectation-guard.py` flags it): the
maintainer must create `.agents/allow-expectation-edits` locally or apply the
`expectations-approved` label on the PR. Change 001's C4 row and the attested
match in `docs/changes/test-surfaces.json` are updated to the new test name so
`./dev spec-check` stays consistent.

| ID | Behavior | Proving test | Level | Boundary |
|----|----------|--------------|-------|----------|
| C1 | When `exists` errors, the upload fails with exactly the generic message `"Failed to verify stored file content. Please retry."` (no backend error leaked), `store` is never called, and the original blob is untouched | `hspec:nhcore-test-service:core/test/Service/FileUpload/ContentDedupSpec.hs#dedup fails closed when the existence check errors` | integration | filesystem:real |
| C2 | Confirmed-missing blobs still self-heal (Pending and Confirmed matches) | `hspec:nhcore-test-service:core/test/Service/FileUpload/ContentDedupSpec.hs#dedup self-heals a missing Pending blob on re-upload`<br>`hspec:nhcore-test-service:core/test/Service/FileUpload/ContentDedupSpec.hs#dedup self-heals a missing Confirmed blob on re-upload` | integration | filesystem:real |
| C3 | Healthy path preserved: a present blob returns the existing `FileRef`/`blobKey` without a store call | `hspec:nhcore-test-service:core/test/Service/FileUpload/ContentDedupSpec.hs#duplicate upload of a present blob makes no store call` | integration | filesystem:real |

## User impact

None breaking. A duplicate upload whose blob-store existence check fails now
returns an error ("Failed to verify stored file content. Please retry.")
instead of silently rewriting the blob. The client retries; the operator sees
the real backend error at `critical` level in the server log. Uploads whose
blob is present or confirmed missing behave exactly as before.

## ADR

Not required — no trigger (breaking / new-dependency / new-capability /
new-extension-point all false). The rule is the standard fail-closed one:
never write on unknown state.
