# Branch ownership

This implementation belongs to `astra/picsig-ios-privacy-studio`.
Never push to, merge into, reset, or delete `main` or another agent's branch.
Always name the branch explicitly in connector write calls. Ref updates must be non-forced.
Use the dedicated bundle identifier `com.dandibbert.picsig.astra`.

Run `swift test` for portable logic. iOS SDK tests run in the branch-scoped workflow.
After adding Swift files run `python3 scripts/generate_project.py`, then commit the deterministic Xcode project.
Never log OCR strings or add a network upload for privacy analysis. Export redactions must remain fully opaque and flattened.
