import { useState } from "react";
import { api } from "@/lib/api";
import {
  errorText,
  joinPath,
  number,
  object,
  records,
  responseError,
  text,
} from "@/lib/value";
import type { JsonObject, RunRecord } from "@/lib/types";
import { startJob, useJob } from "@/stores/job";
import { openRun, useWorkspace } from "@/stores/workspace";
import { Facts, Field, Notice, PathField, Section } from "@/components/Common";
import { PathwayResults } from "@/components/PathwayResults";
function eligible(run: RunRecord | null) {
  return (
    !!run &&
    run.manifest.status === "completed" &&
    !run.verification_error &&
    run.manifest.operation !== "evaluate" &&
    run.manifest.operation !== "ora"
  );
}
export function PathwayPage() {
  const { run, settings, doctor, runLoading, runError } = useWorkspace();
  const busy = useJob((s) => s.busy);
  const [sourcePath, setSourcePath] = useState(
    eligible(run) ? run!.run_dir : text(run?.manifest.source_run_dir, ""),
  );
  const [source, setSource] = useState<RunRecord | null>(
    eligible(run) ? run : null,
  );
  const [annotation, setAnnotation] = useState("gmt");
  const [annotationFile, setAnnotationFile] = useState("");
  const [version, setVersion] = useState("");
  const [mapping, setMapping] = useState("");
  const [evidence, setEvidence] = useState("");
  const [output, setOutput] = useState("");
  const [options, setOptions] = useState<JsonObject>({
    network: "none",
    "add-nodes": 0,
    "string-score": 400,
    species: 9606,
    permutations: 1000,
    seed: 1,
    "min-size": 5,
    "max-size": 500,
  });
  const [historyRoot, setHistoryRoot] = useState(
    sourcePath ? joinPath(sourcePath, "pathway") : "",
  );
  const [manualRun, setManualRun] = useState("");
  const [history, setHistory] = useState<JsonObject[]>([]);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");
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
  const selectSource = (selected: RunRecord) => {
    if (!eligible(selected))
      throw new Error(
        "Select a verified, completed development run. External evaluation and pathway derivatives cannot supply development ranks.",
      );
    setSource(selected);
    setSourcePath(selected.run_dir);
    if (!output) setHistoryRoot(joinPath(selected.run_dir, "pathway"));
  };
  const start = () =>
    act(async () => {
      if (!source || !eligible(source) || source.run_dir !== sourcePath)
        throw new Error("Verify the selected development source first.");
      const requestOptions: Record<string, string | number> = {
        run: source.run_dir,
      };
      for (const [key, value] of Object.entries(options)) {
        if (typeof value !== "number" && typeof value !== "string")
          throw new Error(`Provide ${key}.`);
        requestOptions[key] = value;
      }
      if (annotation === "gmt" || annotation === "term-map") {
        if (!annotationFile) throw new Error("Choose a local annotation file.");
        requestOptions[annotation] = annotationFile;
      } else requestOptions.annotation = annotation;
      if (version) requestOptions["annotation-version"] = version;
      if (mapping) requestOptions.mapping = mapping;
      if (evidence) requestOptions.evidence = evidence;
      if (output) requestOptions.output = output;
      await startJob({
        operation: "ora",
        options: requestOptions,
        ...(settings ? { settings } : {}),
      });
    });
  return (
    <div className="stack">
      <header>
        <p className="eyebrow">EXPLORATORY BIOLOGY</p>
        <h1>Pathways & gene evidence</h1>
        <p>
          Combine measured-background ORA, full development ranks, explicit
          STRING expansion and source-preserving evidence in a separate pathway
          run.
        </p>
      </header>
      {error && <Notice tone="error">{error}</Notice>}
      <Section title="Development source">
        <PathField
          label="Development run directory"
          value={sourcePath}
          onChange={(value) => {
            setSourcePath(value);
            setSource(null);
          }}
          directory
        />
        <div className="row">
          <button
            disabled={working || !sourcePath}
            onClick={() =>
              void act(async () => selectSource(await api.run(sourcePath)))
            }
          >
            Verify development source
          </button>
          {eligible(run) && (
            <button onClick={() => void act(async () => selectSource(run!))}>
              Use selected development run
            </button>
          )}
        </div>
        {source && (
          <Notice tone="success">
            Verified development source: {text(source.manifest.run_id)}
          </Notice>
        )}
      </Section>
      <Section title="Annotation and network settings">
        <div className="form-grid">
          <Field label="Annotation source">
            <select
              value={annotation}
              onChange={(e) => setAnnotation(e.target.value)}
            >
              <option value="gmt">Versioned local GMT</option>
              <option value="term-map">Local term-map CSV</option>
              <option value="go-bp">Optional GO Biological Process</option>
              <option value="go-mf">Optional GO Molecular Function</option>
              <option value="go-cc">Optional GO Cellular Component</option>
            </select>
          </Field>
          {annotation.startsWith("go-") ? (
            <div>
              <p>
                Optional native GO requires AnnotationDbi, GO.db and the species
                organism package. Otherwise supply a versioned local export.
              </p>
              <Facts
                value={
                  object(object(doctor?.result).pathway_capabilities)
                    .optional_packages
                }
              />
            </div>
          ) : (
            <PathField
              label="Annotation file"
              value={annotationFile}
              onChange={setAnnotationFile}
              hint={
                annotation === "gmt"
                  ? "GMT may contain a supplied KEGG / Reactome annotation export."
                  : "CSV: term_id,gene_id[,description]."
              }
            />
          )}
          <Field label="Annotation version">
            <input
              value={version}
              onChange={(e) => setVersion(e.target.value)}
              placeholder="Source release / export version"
            />
          </Field>
          <PathField
            label="Identifier mapping CSV (optional)"
            value={mapping}
            onChange={setMapping}
            hint="CSV: source_id,target_id. Ambiguous mappings are excluded and documented."
          />
          <PathField
            label="Pathway evidence CSV (optional)"
            value={evidence}
            onChange={setEvidence}
            hint="Empty uses evidence retained by the development run, when available."
          />
          <Field label="Network retrieval">
            <select
              value={text(options.network)}
              onChange={(e) =>
                setOptions({
                  ...options,
                  network: e.target.value,
                  "add-nodes":
                    e.target.value === "none" ? 0 : options["add-nodes"],
                })
              }
            >
              <option value="none">None (offline)</option>
              <option value="string">STRING functional associations</option>
            </select>
          </Field>
        </div>
        {options.network === "string" && (
          <Notice>
            STRING retrieval sends the selected public gene identifiers to
            STRING. Expansion is explicit; zero requests no added nodes.
            Unmeasured added nodes remain outside the enrichment background.
          </Notice>
        )}
        <div className="form-grid">
          {[
            ["add-nodes", "STRING added nodes", 0, 1000],
            ["string-score", "STRING required score", 0, 1000],
            ["species", "Species taxonomy ID", 1, undefined],
            ["permutations", "GSEA permutations", 1, undefined],
            ["seed", "Pathway seed", 0, undefined],
            ["min-size", "Minimum term size", 1, undefined],
            ["max-size", "Maximum term size", 1, undefined],
          ].map(([key, name, min, max]) => (
            <Field key={String(key)} label={String(name)}>
              <input
                type="number"
                step="1"
                min={min as number}
                max={max as number | undefined}
                disabled={
                  options.network === "none" &&
                  ["add-nodes", "string-score"].includes(String(key))
                }
                value={text(options[String(key)], "")}
                onChange={(e) =>
                  setOptions({
                    ...options,
                    [String(key)]: number(e.target.value),
                  })
                }
              />
            </Field>
          ))}
        </div>
        <PathField
          label="Pathway output root (optional)"
          value={output}
          onChange={(value) => {
            setOutput(value);
            setHistoryRoot(
              value || (sourcePath ? joinPath(sourcePath, "pathway") : ""),
            );
          }}
          directory
          hint="Default: DEVELOPMENT_RUN/pathway. Each invocation creates its own derivative run."
        />
        <button
          className="primary"
          disabled={busy || working || !doctor?.success || !source}
          onClick={() => void start()}
        >
          Run pathway analysis
        </button>
      </Section>
      <Section title="Pathway run history">
        <PathField
          label="Pathway history root"
          value={historyRoot}
          onChange={setHistoryRoot}
          directory
          hint="Use the development source's pathway directory or the explicit pathway output root; development history does not scan derivatives recursively."
        />
        <button
          disabled={working || !historyRoot}
          onClick={() =>
            void act(async () => {
              const response = await api.call({
                operation: "runs",
                options: { output: historyRoot },
                ...(settings ? { settings } : {}),
              });
              if (!response.success) throw new Error(responseError(response));
              setHistory(records(response.result.runs));
            })
          }
        >
          Refresh pathway history
        </button>
        {history.map((item) => (
          <article className="cache-row" key={text(item.run_id)}>
            <strong>{text(item.run_id)}</strong>
            <span>{text(item.status)}</span>
            <button onClick={() => void openRun(text(item.run_dir))}>
              Open pathway run
            </button>
          </article>
        ))}
        <details>
          <summary>Open a saved pathway directory</summary>
          <PathField
            label="Saved pathway run directory"
            value={manualRun}
            onChange={setManualRun}
            directory
          />
          <button
            disabled={!manualRun || runLoading}
            onClick={() => void openRun(manualRun)}
          >
            Open saved pathway run
          </button>
        </details>
      </Section>
      {runLoading && <p role="status">Reading pathway artifacts…</p>}
      {runError && <Notice tone="error">{runError}</Notice>}
      {run?.manifest.operation === "ora" && (
        <PathwayResults key={run.run_dir} run={run} />
      )}
    </div>
  );
}
