# Repository instructions for coding agents

These instructions apply to the entire repository and to Codex, Claude Code,
other coding agents, and any delegated workers. This repository is public.

## Keep private information out of the repository

- Never write real credentials into source, examples, tests, documentation,
  plans, commit messages, PRs, issues, screenshots, or generated artifacts.
  This includes API keys, bearer tokens, OAuth client secrets, passwords,
  pairing codes, APNs tokens/private keys, SSH keys, and signing material.
- Never record a real installation's server IP, tailnet/MagicDNS namespace,
  SSH alias, internal hostname/domain, cloud resource/account ID, personal
  email, home directory, private project path, device UDID/nickname, Apple
  signing team/profile ID, or native session/request/turn identifiers.
- User-provided private values are inputs for authorized local operations,
  not permission to publish those values. Do not copy them from terminal
  output, logs, conversations, machine configuration, or previous history.
- Read private configuration only when necessary for the requested task.
  Do not print secret contents, environment dumps, full authenticated URLs,
  or raw diagnostic records. Report field names, redacted paths, and status.

## Use safe examples and local configuration

- Use explicit placeholders such as `REPLACE_LOCALLY_DEVICE_SECRET`,
  `YOUR_TEAM_ID`, `/absolute/private/...`, and `/srv/example-project`.
  Use `example.com`, `example.invalid`, loopback, or RFC 5737 documentation
  addresses. Tailnet examples must clearly contain `example` or `fixture`.
- Test credentials must be unmistakably artificial public fixtures and must
  never be provisioned on a real service. Do not paste a live credential into
  a test merely because the test is called a fixture.
- Keep installation configuration in ignored `config/*.local.json`,
  `deploy/*.local.*`, `.env` files, or an appropriate OS secret store.
  Require operators to supply signing teams and other deployment values.
- Derive repository paths from the script location; use temporary-directory
  APIs or explicit local output options for test evidence. Do not hardcode a
  developer's home directory or private workspace.
- Existing `dev.matianyi.agentinbox` bundle IDs and their App Group/Keychain
  identifiers are intentional public product identities. Preserve their
  compatibility unless an identity migration is explicitly requested.
  Preserve public third-party license and attribution metadata as well.

## Logs, builds, backups, and history

- `evidence/`, `.superpowers/`, `.publication-private/`, `dist/`, local
  configuration, databases, keys, and provisioning files must remain ignored.
  Never force-add them or weaken ignore rules to make a commit succeed.
- Keep private backups and raw deployment/test evidence local. Public docs
  may contain only sanitized summaries. Do not publish backup bundles.
- Before releasing a binary, remove private build paths with compiler path
  remapping and inspect the resulting artifact for sensitive strings.
  Stripping symbols alone is insufficient. Do not commit compiled binaries.
- Ignoring or deleting a file does not remove old Git objects, PR diffs,
  release attachments, or CI artifacts. If a leak was committed, stop public
  pushes, report its type and location without reproducing the value, remove
  it locally, and arrange history/hosting cleanup. A real leaked credential
  also requires revocation or rotation by its authorized owner.

## Mandatory checks before commits and public writes

1. Inspect `git status`, the exact staged diff, and the target remote. Stage
   only intended files; inspect untracked/generated files before adding them.
2. Check candidate content for secret literals, live endpoints/IPs, personal
   paths/emails, signing/account/device IDs, and unsanitized operational logs.
   Inspect binary files separately. Do not print matched secret values.
3. Verify ignored sensitive paths are absent from the index. Check commit
   author and committer names/emails; use the owner's public GitHub identity
   and GitHub noreply email instead of a private mailbox.
4. Before the first push of a branch or migrated repository, inspect all
   reachable commits and refs being published. Push explicit reviewed refs;
   never use `--mirror`, `--all`, or `--tags` to publish an old private history.
5. Run relevant syntax/tests and review the final diff. If privacy remains
   uncertain, keep the material local and resolve it before public upload.

The archived private predecessor is for historical recovery only. Do not
reconnect it as a writable remote, merge its unsanitized history, or push its
objects into this public repository. Repository instructions are a required
review workflow, not a substitute for checking the actual publication bytes.
