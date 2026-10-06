---
group: platform
component: Framework
impact: compatible
category: Added
---

## Summary

`Http.Client` can now send PUT, HEAD, DELETE, POST and PATCH requests with a raw byte body and read the status code and headers of every response, including 4xx and 5xx. Use `Http.Client.sendSecure method request body` for HTTPS services and `Http.Client.Internal.sendRaw` for trusted loopback endpoints. `Http.getSecure` and `getRaw` keep working exactly as before.

Existing applications do not need code changes. To verify locally, run `./dev test "Http.Client" nhcore-test-core` and confirm the `sendRaw` and `sendSecure` examples pass.
