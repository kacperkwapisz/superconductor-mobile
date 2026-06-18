/** Superconductor worktree actions (same keys as Mac UI / ai_routing.defaults). */

export type WorktreeActionId =
  | "create_pr"
  | "commit_push"
  | "inline_commit"
  | "resolve_conflicts"
  | "fix_ci"
  | "fix_merge_blocked"
  | "fix_comments"
  | "fix_changes"
  | "squash_merge"
  | "merge_commit"
  | "rebase_merge";

export type WorktreeActionDef = {
  id: WorktreeActionId;
  title: string;
  prompt: string;
  kind: "orchestrate" | "gh_merge";
  mergeMethod?: "squash" | "merge" | "rebase";
};

export const WORKTREE_ACTIONS: WorktreeActionDef[] = [
  { id: "create_pr", title: "Create PR", kind: "orchestrate", prompt: "Open a high-signal pull request or merge request from the current branch. Inspect git status and diff first, then create the review request with a clear title and markdown body. Push to origin if needed." },
  { id: "commit_push", title: "Commit & push", kind: "orchestrate", prompt: "Commit all intended changes on this branch with a clear conventional message, then push to the configured upstream on origin." },
  { id: "inline_commit", title: "Commit message", kind: "orchestrate", prompt: "Create a commit for the currently staged changes with an appropriate message, then push if upstream is configured." },
  { id: "resolve_conflicts", title: "Resolve conflicts", kind: "orchestrate", prompt: "Resolve merge conflicts between this branch and its target branch. Fetch latest base, resolve carefully, then push." },
  { id: "fix_ci", title: "Fix CI", kind: "orchestrate", prompt: "Inspect failing CI for this branch's open review request, fix the root cause, commit, and push." },
  { id: "fix_merge_blocked", title: "Fix blocked merge", kind: "orchestrate", prompt: "Determine why the review request is merge-blocked and fix it from this worktree when possible." },
  { id: "fix_comments", title: "Fix comments", kind: "orchestrate", prompt: "Address unresolved review comments on this branch's open review request." },
  { id: "fix_changes", title: "Fix changes", kind: "orchestrate", prompt: "Address requested changes from review on this branch. Commit and push fixes." },
  { id: "squash_merge", title: "Squash & merge", kind: "gh_merge", mergeMethod: "squash", prompt: "" },
  { id: "merge_commit", title: "Create a merge commit", kind: "gh_merge", mergeMethod: "merge", prompt: "" },
  { id: "rebase_merge", title: "Rebase & merge", kind: "gh_merge", mergeMethod: "rebase", prompt: "" },
];

export function actionById(id: string): WorktreeActionDef | undefined {
  return WORKTREE_ACTIONS.find((a) => a.id === id);
}
