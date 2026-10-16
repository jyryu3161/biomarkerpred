import { useState } from "react";
import { cancelJob, refreshJob, useJob } from "@/stores/job";
import { openRun } from "@/stores/workspace";
import { errorText, number, object, responseError, text } from "@/lib/value";
import { FileActions, Notice } from "./Common";
export function JobPanel() {
  const job = useJob();
  const [error, setError] = useState("");
  if (!job.jobId) return null;
  const result = job.response?.result,
    path = text(result?.run_dir || job.progress.run_dir, "");
  const current = number(job.progress.current),
    total = number(job.progress.total);
  const action = async (fn: () => Promise<unknown>) => {
    try {
      setError("");
      await fn();
    } catch (e) {
      setError(errorText(e));
    }
  };
  return (
    <aside className="job-panel" aria-label="Global operation status">
      <div className="row spread">
        <strong>
          {job.operation} · {job.phase.replaceAll("_", " ")}
        </strong>
        <div className="row">
          {job.busy && (
            <>
              <button onClick={() => void action(refreshJob)}>
                Refresh job status
              </button>
              <button onClick={() => void action(cancelJob)}>
                {job.phase === "cancellation_unverified"
                  ? "Retry cancellation"
                  : "Cancel operation"}
              </button>
            </>
          )}
          {path && (
            <button
              onClick={() =>
                void openRun(
                  path,
                  job.operation === "ora" ? "pathway" : "results",
                )
              }
            >
              Inspect actual run
            </button>
          )}
        </div>
      </div>
      {job.progress.message ? <p>{text(job.progress.message)}</p> : null}
      {job.busy && current !== null && total !== null && total > 0 && (
        <progress value={current} max={total} aria-label="Operation progress" />
      )}
      {path && <code className="path">{path}</code>}
      {job.phase === "cancellation_unverified" && (
        <Notice tone="error">
          Termination has not been verified. The operation remains active and
          new mutations are blocked. Retry cancellation after restoring runtime
          connectivity.
        </Notice>
      )}
      {job.error && <Notice tone="error">{job.error}</Notice>}
      {error && <Notice tone="error">{error}</Notice>}
      {job.phase === "finished" && job.response && (
        <Notice
          tone={
            job.response.cancelled
              ? "warning"
              : job.response.success
                ? "success"
                : "error"
          }
        >
          {job.response.cancelled
            ? `Cancellation acknowledged. ${result?.status === "completed" ? "The engine had already completed; its completed artifacts are retained for inspection." : "Inspect retained partial output if a run directory is available."}`
            : job.response.success
              ? `Engine verified ${job.operation} output${result?.status ? ` · artifact status: ${text(result.status)}` : ""}.`
              : responseError(job.response)}
        </Notice>
      )}
      {job.phase === "finished" && job.operation === "predict" && (
        <FileActions
          path={text(object(result?.paths).predictions, "")}
          name="prediction CSV"
        />
      )}
      <details>
        <summary>Operation log ({job.logs.length} recent messages)</summary>
        <pre className="job-log">
          {job.logs.join("\n") || "No log messages yet."}
        </pre>
        <small>
          Job ID: {job.jobId}. Up to 300 recent messages are retained in this
          view.
        </small>
      </details>
    </aside>
  );
}
