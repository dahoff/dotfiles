# Global instructions

## Git worktrees

Always put a repo's worktrees in a `.worktrees/` directory at the root of its
main checkout, e.g. `~/git/dotfiles/.worktrees/feature-XYZ`.

- Create them with `git worktree add <repo-root>/.worktrees/<name> -b <name>`,
  then enter with `EnterWorktree` using `path`.
- Do not call `EnterWorktree` with `name`: it creates the worktree under
  `.claude/worktrees/` instead. This overrides any skill that prefers it.
