# Security and data handling

Do not put patient data or credentials into public issues, screenshots, commits, or release artifacts. Describe reproducible issues with synthetic fixtures. Until a private security contact is configured for the repository, report sensitive issues directly to its maintainer through an established private channel.

The native engine binds to loopback and uses a random per-process bearer token. It rejects browser-origin requests, arbitrary routes, and mismatched study/frame ownership. Its connection file is private to the current macOS user.

The clinic API requires a separate bearer token, validates input, limits body sizes, stores versioned drafts, and rejects stale revisions. It does not supply individual user authentication or multi-tenant authorization. Access logs are disabled by the supplied launch commands; application audit events remain in the private database.

The OpenAI key loads from a private local .env or a Keychain override. The build does not copy .env into the app. Release checks reject credentials and runtime patient databases. Model calls use store:false; administrators must independently confirm the data-processing arrangement appropriate for their research use.

The app and API cannot finalize, sign, or publish a clinical report. This boundary does not make generated interpretations clinically validated.
