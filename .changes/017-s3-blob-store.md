---
group: platform
component: Framework
impact: compatible
category: Added
---

## Summary

File uploads can now be stored in any S3-compatible object store (AWS S3, Cloudflare R2, Backblaze B2, MinIO, RustFS) with the new `Service.FileUpload.BlobStore.S3` backend. Build it in `App.hs` with `S3.createBlobStore S3Config { endpoint, bucket, region, accessKeyId, secretAccessKey }`, reading the values from your own `Config.hs`, and pass the result to `Application.withFileUpload` exactly like the local backend. Applications on the local filesystem backend are not affected.

To verify locally, run `./dev test "BlobStore.S3" nhcore-test-service`; the suite signs requests against the published AWS examples and exercises the backend against an in-process fake S3 server.
