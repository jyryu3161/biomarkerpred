import { useState } from "react";
import { errorText, object, strings, table, text } from "@/lib/value";
import type { RunRecord } from "@/lib/types";
import { startJob, useJob } from "@/stores/job";
import { navigate, openRun, useWorkspace } from "@/stores/workspace";
import {
  DataTable,
  Facts,
  FileActions,
  JsonDetails,
  Notice,
  Section,
} from "./Common";
import { QcView } from "./QcView";
import { MetricsView } from "./MetricsView";
import { DriftView, Figures, SavedCsv, SavedModel } from "./Artifacts";
export function RunDetails({ run }: { run: RunRecord }) {
  const busy = useJob((s) => s.busy);
  const settings = useWorkspace((s) => s.settings);
  const [error, setError] = useState("");
  const manifest = run.manifest,
    operation = text(manifest.operation, "analyze"),
    pathway = operation === "ora";
  const verifiedDevelopment =
    manifest.status === "completed" &&
    !run.verification_error &&
    !pathway &&
    operation !== "evaluate";
  const mutate = async (operation: "resume" | "report") => {
    try {
      setError("");
      await startJob({
        operation,
        options: { run: run.run_dir },
        ...(settings ? { settings } : {}),
      });
    } catch (e) {
      setError(errorText(e));
    }
  };
  return (
    <div className="stack">
      <Section title={`Run ${text(manifest.run_id)}`}>
        <div className="row">
          <span className={`status-badge ${text(manifest.status)}`}>
            {text(manifest.status)}
          </span>
          <span>
            {operation === "evaluate"
              ? "External evaluation"
              : pathway
                ? "Exploratory pathway derivative"
                : "Development analysis"}
          </span>
          <button onClick={() => void openRun(run.run_dir)}>
            Reload selected run
          </button>
        </div>
        <code className="path">{run.run_dir}</code>
        {run.verification_error && (
          <Notice tone="error">
            Integrity verification failed: {run.verification_error}. Inspect
            available files cautiously; performance cannot be trusted as
            verified.
          </Notice>
        )}
        {Object.entries(run.artifact_errors).map(([name, message]) => (
          <Notice key={name} tone="error">
            {name}: {message}
          </Notice>
        ))}
        {strings(manifest.errors).map((message, i) => (
          <Notice tone="error" key={i}>
            {message}
          </Notice>
        ))}
        {strings(manifest.warnings).map((message, i) => (
          <Notice tone="warning" key={i}>
            {message}
          </Notice>
        ))}
        <Facts
          value={{
            created_at: manifest.created_at,
            finished_at: manifest.finished_at,
            analysis_type: manifest.analysis_type,
            stage: manifest.stage,
            completed_folds: manifest.completed_folds,
            failed_folds: manifest.failed_folds,
            workers_used: manifest.workers_used,
            source_run_id: manifest.source_run_id,
          }}
        />
        <Facts value={manifest.cohort} />
        <Facts value={manifest.validation} />
        {manifest.interpretation ? (
          <Notice>{text(manifest.interpretation)}</Notice>
        ) : null}
        <div className="row">
          <FileActions path={run.paths["report.html"]} name="HTML report" />
          <FileActions path={run.paths["report.pdf"]} name="PDF report" />
          <FileActions path={run.paths["model.bmpmodel"]} name="model" />
          {!pathway && (
            <>
              <button
                disabled={busy || !!run.verification_error}
                onClick={() => void mutate("resume")}
              >
                Resume selected run
              </button>
              <button
                disabled={busy || !!run.verification_error}
                onClick={() => void mutate("report")}
              >
                Regenerate reports
              </button>
            </>
          )}
          {pathway && (
            <button onClick={() => navigate("pathway")}>
              View pathway evidence
            </button>
          )}
          {verifiedDevelopment && (
            <button onClick={() => navigate("pathway")}>
              Use for pathway analysis
            </button>
          )}
        </div>
        {error && <Notice tone="error">{error}</Notice>}
      </Section>
      {run.artifacts["qc.json"] !== undefined && (
        <Section title="Cohort QC and exclusions">
          <QcView value={run.artifacts["qc.json"]} />
        </Section>
      )}
      {run.artifacts["metrics.json"] !== undefined && (
        <Section
          title={
            operation === "evaluate"
              ? "External evaluation performance"
              : "Assessment performance"
          }
        >
          <MetricsView
            value={run.artifacts["metrics.json"]}
            external={operation === "evaluate"}
          />
        </Section>
      )}
      {run.paths["drift.json"] && (
        <Section title="External distribution and overlap audit">
          <DriftView
            key={run.paths["drift.json"]}
            path={run.paths["drift.json"]}
          />
        </Section>
      )}
      {["panel_comparison.csv", "stability.csv", "model_comparison.csv"]
        .filter((name) => table(run.artifacts[name]))
        .map((name) => (
          <Section
            key={name}
            title={
              name === "stability.csv"
                ? "Outer-fold selection and coefficient direction stability"
                : name === "panel_comparison.csv"
                  ? "Small-panel tradeoffs (descriptive fixed arms)"
                  : "Model arms on common outer folds"
            }
          >
            <DataTable data={table(run.artifacts[name])!} title={name} />
            <FileActions path={run.paths[name]} name={name} />
          </Section>
        ))}
      {run.paths["gene_ranking.csv"] && (
        <details className="card">
          <summary>Full-development exploratory gene ranking</summary>
          <p>
            These ranks use the development cohort and do not estimate held-out
            predictive performance.
          </p>
          <SavedCsv
            key={run.paths["gene_ranking.csv"]}
            path={run.paths["gene_ranking.csv"]}
            title="gene ranking"
          />
        </details>
      )}
      {run.paths["panel_overlap.csv"] && (
        <details className="card">
          <summary>Panel overlap</summary>
          <SavedCsv
            key={run.paths["panel_overlap.csv"]}
            path={run.paths["panel_overlap.csv"]}
            title="panel overlap"
          />
        </details>
      )}
      {run.paths["model.bmpmodel"] && (
        <details className="card">
          <summary>Frozen final model</summary>
          <SavedModel
            key={run.paths["model.bmpmodel"]}
            path={run.paths["model.bmpmodel"]}
          />
        </details>
      )}
      {run.paths["predictions.csv"] && (
        <details className="card">
          <summary>Saved predictions (identifier strings preserved)</summary>
          <SavedCsv
            key={run.paths["predictions.csv"]}
            path={run.paths["predictions.csv"]}
            title="predictions"
          />
        </details>
      )}
      {run.artifacts["figures/index.json"] !== undefined && (
        <Section title="Saved research figures">
          <Figures key={run.run_dir} run={run} />
        </Section>
      )}
      <details className="card">
        <summary>Provenance, exact configuration and manifest</summary>
        <Facts value={object(manifest.provenance).input} />
        <Facts value={object(manifest.provenance).environment} />
        <JsonDetails
          value={manifest.provenance}
          title="Full provenance and hashes"
        />
        <JsonDetails
          value={run.artifacts["config.json"]}
          title="Saved normalized configuration"
        />
        <JsonDetails value={manifest} title="Saved manifest" />
      </details>
    </div>
  );
}
