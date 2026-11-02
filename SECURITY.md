# Security

People trust Strata with their files, so security reports come first. Please report a vulnerability privately, not
in a public issue, discussion or pull request.

## Report a vulnerability

Use GitHub's private reporting: open the repository's **Security** tab and choose **Report a vulnerability**, or go
straight to <https://github.com/cristipufu/strata-files/security/advisories/new>. Your report becomes a private
security advisory that only you and the maintainer can see, and the conversation stays there until a fix is released.

Include what you can:

- the Strata version (**Strata ▸ About Strata**) and the macOS version;
- the steps, or the file, folder or archive, that trigger it, and what happens;
- the impact you expect: what someone could read, change or run.

## What's in scope

- The Strata app, the `strata` command-line tool that comes with it, and its update feed.
- Changes to the wrong files: deleting, trashing, moving, renaming or overwriting anything other than what was chosen,
  or getting past a refusal, such as for a disk, a read-only copy or a folder moved into itself.
- Code that runs because a folder was browsed or a file was previewed, such as a downloaded repository's git hooks.
- Files or archives made to crash or take over a preview, archive browsing or indexing.
- Exposure of server credentials, the encrypted search index or History, or the files Strata copies from a server or
  container.
- Tampering with updates. Releases are signed and notarized by Apple, and Strata checks each update's signature before
  installing it.

Out of scope: problems that need someone who already controls your Mac or your account, issues in macOS or other apps
(report those to their makers, but tell us if Strata makes them worse), and automated scan results without a working
impact.

## Supported versions

Fixes ship in a new release. Strata updates itself, so only the latest release is supported; please check that the
issue still happens there before reporting it.

## After you report

The report is reviewed in its advisory, where you can follow progress and answer questions. A confirmed issue is fixed
in a new release, and the advisory is then published with credit to you, unless you'd rather not be named.
