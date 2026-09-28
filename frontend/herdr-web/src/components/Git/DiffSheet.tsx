import { useRef } from "react";
import { FileCode2, TriangleAlert } from "lucide-react";
import {
  EMPTY_GIT_ENTRY,
  useGitStore,
  type DiffSheetState,
} from "../../store/gitStore";
import {
  SharedDiffRenderer,
} from "./SharedDiffRenderer";
import { SelectionAskLauncher } from "./SelectionAskLauncher";
import "./git.css";

import { DiffDisplayControls, useDiffDisplayPreferences } from "./DiffDisplayControls";

/**
 * The persistent diff half of the Git workbench.
 *
 * Diff state keeps its original `diffSheet` name in the store because that is
 * an internal loading model used by the API and store tests. It is no longer
 * presented as a sheet: the inspector stays beside the repository navigator.
 */
export function DiffInspector({ paneId, allowsAsk = true }: { paneId: string; allowsAsk?: boolean }) {
  const { diffStyle, setDiffStyle, diffOverflow, setDiffOverflow } = useDiffDisplayPreferences();
  const diffBodyRef = useRef<HTMLDivElement | null>(null);
  const sheet = useGitStore((state) =>
    state.diffSheet?.paneId === paneId ? state.diffSheet : null,
  );
  const entry = useGitStore((state) => state.byPane[paneId] ?? EMPTY_GIT_ENTRY);

  if (sheet === null) {
    return (
      <section className="hz-diff-inspector hz-diff-inspector-empty" aria-label="Code changes">
        <FileCode2 size={22} aria-hidden />
        <span className="hz-git-state-title">Select a changed file</span>
        <span className="hz-git-state-sub">Its diff will stay open here while you browse the repository.</span>
      </section>
    );
  }

  const revisionLabel =
    sheet.section === "commit" && sheet.commitHash !== null
      ? `commit ${sheet.commitHash.slice(0, 8)}`
      : sheet.section;

  return (
    <section className="hz-diff-inspector" aria-label={`Diff for ${sheet.file}`}>
      <header className="hz-diff-header">
        <div className="hz-diff-heading">
          <span className="hz-diff-eyebrow">{revisionLabel}</span>
          <span className="hz-diff-title mono" title={sheet.file}>
            {sheet.file}
          </span>
        </div>
        <DiffDisplayControls style={diffStyle} overflow={diffOverflow} onStyle={setDiffStyle} onOverflow={setDiffOverflow} />
        {entry.loading ? <span className="hz-diff-refreshing">Refreshing repository…</span> : null}
      </header>
      {sheet.truncated ? (
        <div className="hz-diff-truncated-warning" role="alert" aria-atomic="true">
          <TriangleAlert size={16} aria-hidden />
          <div>
            <strong>Diff truncated</strong>
            <span>The server returned only part of this patch. This review may be incomplete.</span>
          </div>
        </div>
      ) : null}
      <div className="hz-diff-body" ref={diffBodyRef}>
        {sheet.isLoading ? (
          <p className="hz-diff-state" role="status">Loading diff…</p>
        ) : sheet.error !== null ? (
          <div className="hz-diff-state hz-diff-error">
            <span>Diff unavailable</span>
            <small>{sheet.error}</small>
            <button type="button" onClick={() => retryDiff(sheet)}>Try again</button>
          </div>
        ) : sheet.diff === "" ? (
          <p className="hz-diff-state hz-diff-empty">(empty diff)</p>
        ) : (
          <SharedDiffRenderer
            file={sheet.file}
            patch={sheet.diff}
            diffStyle={diffStyle}
            overflow={diffOverflow}
          />
        )}
      </div>
      {allowsAsk ? (
        <SelectionAskLauncher paneId={paneId} file={sheet.file} section={sheet.section} rootPath={entry.snapshot?.rootPath} revision={sheet.commitHash ?? undefined} containerRef={diffBodyRef} />
      ) : null}
    </section>
  );
}
function retryDiff(sheet: DiffSheetState) {
  if (sheet.section === "commit" && sheet.commitHash !== null) {
    useGitStore.getState().commitDiff(sheet.paneId, sheet.commitHash, sheet.file);
  } else if (sheet.section !== "commit") {
    useGitStore.getState().diff(sheet.paneId, sheet.file, sheet.section);
  }
}
