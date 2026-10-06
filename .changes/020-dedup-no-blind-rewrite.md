---
group: platform
component: Framework
impact: compatible
category: Fixed
---

## Summary

A duplicate file upload no longer rewrites the stored blob when the blob store cannot say whether the blob exists. Before, a failed existence check was treated as "missing" and the content was re-stored blindly; on a remote object store that overwrote data nobody had looked at. Now the upload fails with "Failed to verify stored file content. Please retry.", the real backend error is logged at `critical`, and nothing is written. Uploads whose blob is present, or confirmed missing, behave exactly as before (the confirmed-missing case still self-heals).

No code or data changes are needed in applications. To verify locally, run `./dev test "ContentDedup" nhcore-test-service` and confirm `dedup fails closed when the existence check errors` passes.
