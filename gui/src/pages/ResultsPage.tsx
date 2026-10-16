import { useState } from "react";
import { api } from "@/lib/api";
import {
  errorText,
  object,
  records,
  responseError,
  strings,
  text,
} from "@/lib/value";
import type { JsonObject } from "@/lib/types";
import { openRun, useWorkspace } from "@/stores/workspace";
import { Facts, Notice, PathField, Section } from "@/components/Common";
import { MetricScope } from "@/components/MetricsView";
import { RunDetails } from "@/components/RunDetails";
export function ResultsPage() {
  const { settings, config, run, runLoading, runError } = useWorkspace();
  const [root, setRoot] = useState(
    settings?.outputRoot || text(config.output_dir, ""),
  );
  const [manual, setManual] = useState("");
  const [history, setHistory] = useState<JsonObject[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [comparison, setComparison] = useState<JsonObject | null>(null);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");
  const [searched, setSearched] = useState(false);
  const act = async (fn: () => Promise<void>) => {
    setWorking(true);
    setError("");
    try {
      await fn();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setWorking(false);
    }
  };
  const refresh = () =>
    act(async () => {
      const result = await api.call({
        operation: "runs",
        options: { output: root },
        ...(settings ? { settings } : {}),
      });
      if (!result.success) throw new Error(responseError(result));
      setHistory(records(result.result.runs));
      setSearched(true);
    });
  return (
    <div className="stack">
      <header>
        <p className="eyebrow">RECORDED EXPERIMENTS</p>
        <h1>Results & history</h1>
        <p>
          Inspect completed and unfinished runs, compare compatible cohorts and
          reopen their saved reports.
        </p>
      </header>
      <Section title="Run history">
        <PathField
          label="History output root"
          value={root}
          onChange={(value) => {
            setRoot(value);
            setSelected([]);
            setComparison(null);
            setHistory([]);
            setSearched(false);
          }}
          directory
        />
        <div className="row">
          <button disabled={working || !root} onClick={() => void refresh()}>
            Refresh run history
          </button>
          <button
            disabled={working || selected.length < 2}
            onClick={() =>
              void act(async () => {
                const response = await api.call({
                  operation: "compare",
                  options: { run: selected },
                  ...(settings ? { settings } : {}),
                });
                if (!response.success) throw new Error(responseError(response));
                setComparison(response.result);
              })
            }
          >
            Compare selected runs ({selected.length})
          </button>
        </div>
        {working && <p>Reading recorded runs…</p>}
        {error && <Notice tone="error">{error}</Notice>}
        {searched && !history.length && (
          <p>No run manifests found under this root.</p>
        )}
        <div className="history-list">
          {history.map((item) => {
            const path = text(item.run_dir);
            return (
              <article key={path}>
                <label className="check">
                  <input
                    type="checkbox"
                    aria-label={`Compare ${text(item.run_id)}`}
                    checked={selected.includes(path)}
                    disabled={item.operation === "ora"}
                    onChange={(e) => {
                      setComparison(null);
                      setSelected(
                        e.target.checked
                          ? [...selected, path]
                          : selected.filter((entry) => entry !== path),
                      );
                    }}
                  />
                  <span>
                    <strong>{text(item.run_id)}</strong>
                    <small>
                      {text(item.analysis_type, "pathway")} ·{" "}
                      {text(item.operation, "development")} ·{" "}
                      {text(item.created_at, "")}
                    </small>
                  </span>
                </label>
                <span className={`status-badge ${text(item.status)}`}>
                  {text(item.status)}
                </span>
                <button onClick={() => void openRun(path)}>Open run</button>
                <code>{path}</code>
              </article>
            );
          })}
        </div>
        <details>
          <summary>Open a run directory directly</summary>
          <PathField
            label="Run directory"
            value={manual}
            onChange={setManual}
            directory
          />
          <button
            disabled={!manual || runLoading}
            onClick={() => void openRun(manual)}
          >
            Open run directory
          </button>
        </details>
      </Section>
      {comparison && (
        <Section title="Recorded comparison">
          <p>{text(comparison.interpretation)}</p>
          {records(comparison.runs).map((item) => (
            <details key={text(item.run_dir)} open>
              <summary>
                {text(item.run_id)} ·{" "}
                {item.comparable_to_first === true
                  ? "Compatible with first run"
                  : "Separate comparison group"}
              </summary>
              <Facts
                value={{
                  comparison_group: item.comparison_group,
                  incompatibilities: item.incompatibilities,
                  analysis_type: item.analysis_type,
                  status: item.status,
                }}
              />
              {strings(item.incompatibilities).length > 0 && (
                <Notice tone="warning">
                  Do not rank this run together with the first:{" "}
                  {strings(item.incompatibilities).join(", ")}.
                </Notice>
              )}
              <Facts value={item.panel} />
              <MetricScope value={item.primary} />
              <details>
                <summary>Compatibility criteria</summary>
                <Facts value={object(item.criteria)} />
              </details>
            </details>
          ))}
        </Section>
      )}
      {runLoading && <p role="status">Verifying and reading selected run…</p>}
      {runError && <Notice tone="error">{runError}</Notice>}
      {run && <RunDetails key={run.run_dir} run={run} />}
    </div>
  );
}
