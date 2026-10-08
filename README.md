# Windows 10 Codex Computer Use capture repair

This release contains one byte-guarded compatibility profile for Windows 10 x64 build 19045, Codex Desktop 26.1002.7124.0, and `@oai/sky` 0.7.6. It targets the native capture helper only when its complete original SHA-256 matches the profile. It refuses unknown builds and hashes.

## What it changes

The profile routes Windows Graphics Capture `FrameArrived` work to an MTA worker so the frame callback can return before the asynchronous surface copy runs. The profile also carries x64 unwind data for the wrapper. This is a community repair, not an official OpenAI update. The modified helper loses the original Authenticode signature and an application update may replace it.

## Included files

- `profile-win10-codex-26.1002.7124-sky-0.7.6.json`: full input and output hashes plus byte-level guards and replacements for the exact helper tested locally.
- The original helper is not included. Do not download or distribute proprietary helper binaries as part of this profile.

The profile is adapted from [the Windows 10 capture analysis](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/blob/main/references/win10-computer-use-screenshot-backend.md) and issues [#46435](https://github.com/openai/codex/issues/46435) and [#51245](https://github.com/openai/codex/issues/51245). The referenced project does not publish a license file; this release includes attribution and keeps the profile separate from any asserted license for that project’s code.

## Validation

On the exact helper named by the profile, the original timed out on a blank Notepad window. The patched profile returned repeated screenshots and supported a coordinate click. Accessibility-tree reading continued to work. The candidate passed PE structure checks and Windows x64 unwind tests at 47 instruction boundaries and 10 live caller frames. The original binary and rollback path were verified locally.

This validation applies only to the exact Windows 10 build and helper hashes in the profile. It is not evidence for Windows 11, other Windows builds, future Codex versions, or other `@oai/sky` binaries. Start with an exact-hash check and retain a verified original backup before replacing anything.
