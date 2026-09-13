# PicSig · Astra branch

Dedicated branch: `astra/picsig-ios-privacy-studio`.

**Do not merge or push to main. Another agent may be working independently.**

## Actual repository status

This branch currently contains the portable Swift core, not a complete installable iOS application:

- Codable project, layout, crop, annotation and privacy-mask models.
- Vertical / horizontal composition geometry, overlap cuts, rotation and segmented export coordinates.
- Grayscale screenshot overlap matching, duplicate filtering and fixed-edge detection.
- Local privacy rules for phone numbers, email, identity documents, bank cards, addresses, names, accounts, secrets, IP addresses and literal custom keywords.
- 32 passing XCTest regression tests, run with Swift 6.2.1 on Linux.

```sh
swift test
```

The uploaded source blobs were checked byte-for-byte against the tested local files.

## Incomplete delivery

The iOS application source, native editor, photo / recording import, Vision detection, renderer, storage, Xcode project, iOS tests and branch-scoped build workflow were also written in the task's working directory. However, the GitHub connector blocked the upload batch containing App/Storage.swift, App/Renderer.swift and App/PrivacyScanner.swift with the message that OpenAI could not determine the request's safety status. An identical retry was blocked as well. The blocked upload was not routed through a different write channel.

The full source snapshot is attached to the originating ChatGPT conversation. It has passed Swift syntax parsing and project/plist validation, but **iOS SDK compilation, simulator tests and device archive have NOT run**. No IPA is available. Do not treat the presence of the portable core as delivery of the complete app.

The intended app uses iOS 17+, independent bundle identifier `com.dandibbert.picsig.astra`, and display name PicSig Astra. Complete application upload and macOS CI verification remain outstanding.
