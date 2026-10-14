# Changelog

## 1.0.0

First public release.

- Resumes dropped or stalled downloads with HTTP range requests, with no overall time limit; prefers the zstd build.
- Before switching: GPG signature of the manifest against the pinned Anthropic release key (with `gpgv`), the manifest's version, sha256 of the download and the unpacked binary, the Anthropic Developer ID signature on macOS, and a `--version` smoke test.
- Switches by rename, never deletes a version, and `--rollback` goes back to the previous version offline.
- Respects `DISABLE_UPDATES`, `minimumVersion`, `requiredMinimumVersion` and `requiredMaximumVersion`; stops if the settings can't be read; leaves custom launchers alone; one run at a time.
- `--hook` for a SessionStart note when a newer version is out (network check at most once a day).
