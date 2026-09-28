/** A comparison is a pair of trees, independent of its host (PR, pane, or feature). */
export interface GitComparisonSelection {
  mode: "all" | "commit" | "range" | "working-tree";
  start_commit?: string;
  end_commit?: string;
}

export interface GitComparison {
  id: string;
  mode: GitComparisonSelection["mode"];
  before_sha: string;
  after_sha: string;
  commit_shas: string[];
}

export interface ComparisonCommit {
  sha: string;
  parents: string[];
  subject: string;
  author_name?: string;
  authored_at?: string;
}

export const WORKING_TREE = "working-tree";

export function comparisonSelection(before: string, after: string): GitComparisonSelection {
  return after === WORKING_TREE
    ? { mode: "working-tree", start_commit: before }
    : { mode: "range", start_commit: before, end_commit: after };
}

/** Filtering options prevents an accidental reverse diff when one end moves. */
export function revisionOptions(baseline: string, commits: ComparisonCommit[]) {
  return [baseline, ...commits.map((commit) => commit.sha).filter((sha) => sha !== baseline)];
}

/** A topological list can contain sibling commits. Ordering alone is insufficient. */
export function isComparisonAncestor(before: string, after: string, baseline: string, commits: ComparisonCommit[]): boolean {
  const known = new Map(commits.map((commit) => [commit.sha, commit.parents]));
  if (before !== baseline && !known.has(before)) return false;
  if (after === WORKING_TREE) return true;
  if (after !== baseline && !known.has(after)) return false;
  if (before === baseline || before === after) return true;
  const seen = new Set<string>();
  const pending = [after];
  while (pending.length > 0) {
    const sha = pending.pop()!;
    if (sha === before) return true;
    if (seen.has(sha)) continue;
    seen.add(sha);
    pending.push(...(known.get(sha) ?? []));
  }
  return false;
}

export function questionScopeKey(server: string, target: string, root: string, file: string, section: string, revision = "") {
  return "herdr.assistant." + JSON.stringify([server, target, root, file, section, revision]);
}

/** Only exact paths available in this comparison become local navigation. */
export function referencedComparisonFiles(text: string, files: string[]) {
  return files.filter((path) => {
    const escaped = path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return new RegExp(`(?:^|[^\\w./-])${escaped}(?=$|[^\\w./-])`).test(text);
  });
}
