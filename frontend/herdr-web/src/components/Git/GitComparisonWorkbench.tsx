import { useEffect, useRef, useState } from "react";
import { ApiError } from "../../api/client";
import { gitComparison, type ComparisonFile, type GitComparisonResponse } from "../../api/git";
import { SharedDiffRenderer } from "./SharedDiffRenderer";
import { DiffDisplayControls, useDiffDisplayPreferences } from "./DiffDisplayControls";
import { ComparisonControls } from "./ComparisonControls";
import { comparisonSelection, type GitComparisonSelection } from "./comparison";
import { SelectionAskLauncher } from "./SelectionAskLauncher";

export function GitComparisonWorkbench({ targetKey, rootPath, initialCommit, head, onUnsupported }: {
  targetKey: string; rootPath: string; initialCommit?: string; head?: string; onUnsupported: () => void;
}) {
  const [selection, setSelection] = useState<GitComparisonSelection>(() => initialCommit
    ? { mode: "commit", start_commit: initialCommit } : { mode: "all" });
  const [result, setResult] = useState<GitComparisonResponse | null>(null);
  const [path, setPath] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [refresh, setRefresh] = useState(0);
  const { diffStyle: style, setDiffStyle: setStyle, diffOverflow: overflow, setDiffOverflow: setOverflow } = useDiffDisplayPreferences();
  const [detail, setDetail] = useState<{ key: string; file?: ComparisonFile; error?: string } | null>(null);
  const bodyRef = useRef<HTMLDivElement | null>(null);
  const unsupportedRef = useRef(onUnsupported);
  unsupportedRef.current = onUnsupported;

  useEffect(() => {
    const abort = new AbortController();
    let current = true;
    setLoading(true);
    setError(null);
    void gitComparison(targetKey, selection, rootPath, abort.signal).then((next) => {
      if (!current) return;
      setResult(next);
      setPath((previous) => next.files.some((file) => file.path === previous) ? previous : next.files[0]?.path ?? null);
    }).catch((failure: unknown) => {
      if (!current) return;
      if (failure instanceof ApiError && failure.status === 404 && failure.code !== "git_repository_not_found") {
        unsupportedRef.current();
      } else {
        setError(failure instanceof Error ? failure.message : "Could not load this comparison.");
      }
    }).finally(() => { if (current) setLoading(false); });
    return () => { current = false; abort.abort(); };
  }, [targetKey, rootPath, selection, refresh, head]);

  const catalogFile = result?.files.find((item) => item.path === path);
  const detailKey = result && path ? `${result.comparison.id}:${path}` : null;
  const needsDetail = Boolean(catalogFile && !catalogFile.binary && (catalogFile.truncated || !catalogFile.patch));
  useEffect(() => {
    if (loading || error || !result || !catalogFile || !needsDetail || !detailKey) return;
    let current = true;
    const abort = new AbortController();
    // Never install a file fetched after these endpoints or working contents change.
    void gitComparison(targetKey, selection, rootPath, abort.signal, catalogFile.path).then((next) => {
      if (!current) return;
      if (next.comparison.id !== result.comparison.id) throw new Error("The repository changed. Refresh the comparison to continue.");
      const selected = next.files.find((item) => item.path === catalogFile.path);
      if (!selected) throw new Error("This file is no longer available in the comparison. Refresh to continue.");
      setDetail({ key: detailKey, file: selected });
    }).catch((failure: unknown) => {
      if (current) setDetail({ key: detailKey, error: failure instanceof Error ? failure.message : "Could not load this file." });
    });
    return () => { current = false; abort.abort(); };
  }, [targetKey, rootPath, selection, result, catalogFile, needsDetail, detailKey, loading, error]);
  const matchingDetail = detail?.key === detailKey ? detail : null;
  const file = needsDetail ? matchingDetail?.file ?? catalogFile : catalogFile;
  const fileLoading = needsDetail && !matchingDetail;
  const fileError = needsDetail ? matchingDetail?.error : undefined;
  const ready = !loading && error === null && !fileLoading && !fileError;
  return <section className="hz-comparison-workbench" aria-label="Git comparison" aria-busy={loading}>
    <header className="hz-comparison-toolbar">
      {result ? <ComparisonControls baseline={result.baseline_sha} baselineLabel={result.baseline_label}
        commits={result.commits} before={result.comparison.before_sha} after={result.comparison.after_sha}
        disabled={loading} onChange={(before, after) => setSelection(comparisonSelection(before, after))} /> : null}
      <button type="button" disabled={loading} onClick={() => setSelection({ mode: "all" })}>Latest</button>
      <button type="button" disabled={loading} onClick={() => setRefresh((value) => value + 1)}>Refresh</button>
    </header>
    {loading ? <p className="hz-diff-state" role="status">Loading comparison…</p>
      : error ? <div className="hz-diff-state" role="alert">{error}<button onClick={() => setRefresh((value) => value + 1)}>Try again</button></div>
      : result ? <div className="hz-comparison-content">
        <nav className="hz-comparison-files" aria-label="Files in this comparison">
          <p>{result.files.length} changed files</p>
          {result.files.map((item) => <button key={item.path} type="button" aria-current={path === item.path ? "true" : undefined}
            title={item.path} onClick={() => setPath(item.path)}>
            <span>{item.path}</span><small>{item.truncated && !item.patch ? "Load to inspect changes" : `+${item.additions} −${item.deletions}`}</small>
          </button>)}
          {result.files.length === 0 ? <p>No changes between these revisions.</p> : null}
        </nav>
        <section className="hz-diff-inspector" aria-label={file ? `Diff for ${file.path}` : "Code changes"}>
          <header className="hz-diff-header">
            <span className="hz-diff-title mono">{file?.path ?? "Select a changed file"}</span>
            <DiffDisplayControls style={style} overflow={overflow} onStyle={setStyle} onOverflow={setOverflow} />
          </header>
          {file?.truncated && !fileLoading ? <p className="hz-diff-truncated-warning" role="alert">Partial comparison. Some changes are not shown.</p> : null}
          <div ref={bodyRef} className="hz-diff-body">
            {fileLoading ? <p className="hz-diff-state" role="status">Loading file…</p>
              : fileError ? <p className="hz-diff-state" role="alert">{fileError}</p>
              : file?.binary ? <p className="hz-diff-state">Binary file. A text diff is unavailable.</p>
              : file ? <SharedDiffRenderer key={`${result.comparison.id}:${file.path}`} file={file.path} patch={file.patch} diffStyle={style} overflow={overflow} /> : null}
          </div>
          {file && ready ? <SelectionAskLauncher key={`${result.comparison.id}:${file.path}`}
            paneId={targetKey} file={file.path} rootPath={rootPath} section="comparison"
            revision={result.comparison.id} containerRef={bodyRef} comparison={selection}
            availableFiles={result.files.map((item) => item.path)} onShowFile={setPath}
            viewerContext={{ comparison: { id: result.comparison.id, mode: result.comparison.mode,
              before_sha: result.comparison.before_sha, after_sha: result.comparison.after_sha }, path: file.path, fileCount: result.files.length,
              commitCount: result.commits.length, diffStyle: style, overflow, truncated: file.truncated }}
            allowsFileQuestion /> : null}
        </section>
      </div> : null}
  </section>;
}
