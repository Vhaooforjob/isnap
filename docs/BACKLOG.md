# Backlog

## Cloud integrations

**Status: backlog — not available starting with v1.0.4.**

The following capabilities are deferred:

- Cloudflare R2, Google Drive and DocVault configuration and authentication.
- Uploading from the editor, Library or Capture Line; copying hosted links.
- Upload progress, cancellation, retry and link history.
- Automatic uploads as part of capture workflows.
- DocVault workspace/account selection and quota refresh.

Cloud controls are hidden and connection/upload entry points are disabled, including startup checks and settings polling. Previously saved workflows continue to capture, style, save and copy locally, ignoring their cloud destination. Existing settings, credentials and local link history are retained without being used.

Before introducing cloud as a product feature, review the scope and validate authentication, explicit upload consent, provider errors, cancellation/retry, credential handling and workflow behavior. There is no committed release date.

Local export and macOS sharing services remain available. Historical release notes describe their respective published builds; this backlog records the scope of current development.
