# Git and post-export orchestration

`Get-ReadOnlyGitAudit.ps1` is the deterministic Git input for the offline
post-export consumer. It disables Git optional locks and collects only:

- repository root, HEAD and branch;
- porcelain working-tree status;
- staged and unstaged name/status diffs;
- untracked paths and a normalized changed-path set.

It never stages, restores, commits or otherwise mutates the repository. The
subsequent live workflow remains: review offline report, PLC text snapshot,
ownership/hook audit, I/O and Symbol audit, controlled repair, offline compile,
readback report and an explicit commit.
