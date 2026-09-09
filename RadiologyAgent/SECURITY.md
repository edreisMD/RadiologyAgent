# Security and data handling

Do not put patient data or credentials into public issues, screenshots, commits, or release artifacts. Describe reproducible issues with synthetic fixtures. Until a private security contact is configured for the repository, report sensitive issues directly to its maintainer through an established private channel.

The native engine binds to loopback and uses a random per-process bearer token. It rejects browser-origin requests, arbitrary routes, and mismatched study/frame ownership. Its connection file is private to the current macOS user.

The clinic API requires a separate bearer token, validates input, limits body sizes, stores versioned drafts, and rejects stale revisions. It does not supply individual user authentication or multi-tenant authorization. Access logs are disabled by the supplied launch commands; application audit events remain in the private database.

The OpenAI key loads from a private local .env or a Keychain override. The build does not copy .env into the app. Release checks reject credentials and runtime patient databases. Model calls use store:false; administrators must independently confirm the data-processing arrangement appropriate for their research use.

The app and API cannot finalize, sign, or publish a clinical report. This boundary does not make generated interpretations clinically validated.
# Dependency audit for the research build

The monorepo pins Cornerstone3D 4.15.29 for the demonstrated DICOM workflow. Vite was patched to 7.3.6, and compatible overrides update `js-yaml` to 3.15.2 and `fflate` to 0.7.5. The checked dependency tree has no high or critical npm audit findings; it still reports the transitive `uuid` buffer-bounds advisory through the image loader and a low-severity esbuild Windows development-server advisory. The shipped viewer uses prebuilt assets served by the authenticated Python loopback service; it does not run the Vite/esbuild development server. This is not a claim that all transitive dependencies are free of vulnerabilities. Recheck `npm audit` before deployment; do not force a major imaging-engine dependency update without verifying decoding and viewer behavior.
