import type { ComparisonCommit } from "./comparison";
import { isComparisonAncestor, revisionOptions, WORKING_TREE } from "./comparison";

/** Both hosts compare earlier code on the left with later code on the right. */
export function ComparisonControls({ baseline, baselineLabel, commits, before, after, disabled, onChange }: {
  baseline: string; baselineLabel: string; commits: ComparisonCommit[];
  before: string; after: string; disabled?: boolean;
  onChange: (before: string, after: string) => void;
}) {
  const revisions = revisionOptions(baseline, commits);
  const label = (sha: string) => sha === baseline
    ? `${baselineLabel} · ${sha.slice(0, 8)}`
    : `${sha.slice(0, 8)} · ${commits.find((commit) => commit.sha === sha)?.subject ?? "Commit"}`;
  return <div className="hz-comparison-controls" aria-label="Compared revisions">
    <label>Before
      <select aria-label="Earlier revision" value={before} disabled={disabled}
        onChange={(event) => onChange(event.target.value, after)}>
        {revisions.filter((sha) => isComparisonAncestor(sha, after, baseline, commits)).map((sha) => <option key={sha} value={sha}>{label(sha)}</option>)}
      </select>
    </label>
    <span aria-hidden="true">→</span>
    <label>After
      <select aria-label="Later revision" value={after} disabled={disabled}
        onChange={(event) => onChange(before, event.target.value)}>
        {revisions.filter((sha) => isComparisonAncestor(before, sha, baseline, commits)).map((sha) => <option key={sha} value={sha}>{label(sha)}</option>)}
        <option value={WORKING_TREE}>Working tree (including uncommitted changes)</option>
      </select>
    </label>
  </div>;
}
