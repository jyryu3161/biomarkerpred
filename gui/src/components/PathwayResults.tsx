import { useState } from "react";
import { object, strings, table, text } from "@/lib/value";
import type { RunRecord } from "@/lib/types";
import {
  DataTable,
  Facts,
  FileActions,
  JsonDetails,
  Notice,
  Section,
} from "./Common";
import { Figures, SavedCsv } from "./Artifacts";
import { NetworkView } from "./NetworkView";
import { GeneEvidence } from "./GeneEvidence";
export function PathwayResults({ run }: { run: RunRecord }) {
  const [selected, setSelected] = useState<string[]>([]);
  const summary = object(run.artifacts["summary.json"]),
    universes = object(run.artifacts["universes.json"]);
  return (
    <div className="stack">
      <Section title={`Pathway run ${text(run.manifest.run_id)}`}>
        <span className={`status-badge ${text(run.manifest.status)}`}>
          {text(run.manifest.status)}
        </span>
        <code className="path">{run.run_dir}</code>
        <p>
          {text(
            summary.interpretation,
            "Exploratory development annotation; separate from held-out performance.",
          )}
        </p>
        <Facts
          value={{
            source_run_id: run.manifest.source_run_id,
            source_run_dir: run.manifest.source_run_dir,
          }}
        />
        <Facts value={run.manifest.components} />
        {run.verification_error && (
          <Notice tone="error">
            Integrity verification failed: {run.verification_error}
          </Notice>
        )}
        {Object.entries(run.artifact_errors).map(([path, error]) => (
          <Notice key={path} tone="error">
            {path}: {error}
          </Notice>
        ))}
        {[
          ...strings(run.manifest.errors),
          ...strings(run.manifest.warnings),
        ].map((message, i) => (
          <Notice
            key={i}
            tone={i < strings(run.manifest.errors).length ? "error" : "warning"}
          >
            {message}
          </Notice>
        ))}
        <FileActions
          path={run.paths["report.html"]}
          name="pathway HTML report"
        />
      </Section>
      <Section title="Gene sets and measured backgrounds">
        <Facts
          value={{
            original_genes: strings(object(summary.gene_sets).original).length,
            expanded_genes: strings(object(summary.gene_sets).expanded).length,
            network_added: strings(object(summary.gene_sets).network_added)
              .length,
            original_tested_ids: strings(
              object(summary.gene_sets).original_tested_ids,
            ).length,
            expanded_tested_ids: strings(
              object(summary.gene_sets).expanded_tested_ids,
            ).length,
            expanded_excluded_from_assay_background: object(summary.gene_sets)
              .expanded_excluded_from_assay_background,
          }}
        />
        <div className="universe-grid">
          {[
            "raw_assay",
            "configured_assay",
            "configured_eligible",
            "development_qc",
            "annotation_mapped",
          ].map((key) => {
            const universe = object(universes[key]);
            return (
              <article key={key}>
                <h3>{key.replaceAll("_", " ")}</h3>
                <strong className="stat">{text(universe.count)}</strong>
                <p>{text(universe.policy, "")}</p>
                {universe.unavailable_reason ? (
                  <Notice>{text(universe.unavailable_reason)}</Notice>
                ) : null}
                <small>SHA-256: {text(universe.sha256)}</small>
                <details>
                  <summary>Inspect universe identifiers</summary>
                  <DataTable
                    data={strings(universe.genes).map((identifier) => ({
                      identifier,
                    }))}
                    title={key}
                  />
                </details>
              </article>
            );
          })}
        </div>
        <details>
          <summary>Background exclusions and mapping coverage</summary>
          <Facts value={summary.mapping} />
          <Facts value={universes.exclusions} />
          {run.paths["identifier_mapping.csv"] && (
            <SavedCsv
              key={run.paths["identifier_mapping.csv"]}
              path={run.paths["identifier_mapping.csv"]}
              title="identifier mapping"
            />
          )}
        </details>
        <Facts value={summary.annotation} />
      </Section>
      <Section title="Original and expanded ORA">
        <p>
          One-sided hypergeometric over-representation uses the same declared
          annotation-mapped assay background for both sets. Expanded unmeasured
          genes are excluded from tests.
        </p>
        {["ora_original.csv", "ora_expanded.csv"].map((name) => (
          <details key={name} open>
            <summary>
              {name === "ora_original.csv"
                ? "Original model genes"
                : "Network-expanded measured genes"}
            </summary>
            <Facts value={object(summary.methods)[name.replace(".csv", "")]} />
            {table(run.artifacts[name]) && (
              <DataTable data={table(run.artifacts[name])!} title={name} />
            )}
            <FileActions path={run.paths[name]} name={name} />
          </details>
        ))}
      </Section>
      <Section title="Full-ranked GSEA">
        <Facts value={object(summary.methods).gsea} />
        <p>{text(object(summary.methods).rank_policy, "")}</p>
        {table(run.artifacts["gsea.csv"]) && (
          <DataTable data={table(run.artifacts["gsea.csv"])!} title="GSEA" />
        )}
        {["ranked_genes.csv", "rank_exclusions.csv", "rank_collapsed.csv"].map(
          (name) =>
            run.paths[name] && (
              <details key={name}>
                <summary>
                  {name.replace(".csv", "").replaceAll("_", " ")}
                </summary>
                <SavedCsv
                  key={run.paths[name]}
                  path={run.paths[name]}
                  title={name}
                />
              </details>
            ),
        )}
      </Section>
      <Section title="Functional association network">
        <NetworkView
          value={run.artifacts["graph.json"]}
          onSelect={setSelected}
        />
        <details>
          <summary>Network mapping and request provenance</summary>
          <Facts value={summary.network} />
          <JsonDetails
            value={object(run.artifacts["graph.json"]).assay_mapping}
            title="Exact assay-source mapping"
          />
        </details>
      </Section>
      <Section title="Gene evidence explorer">
        <GeneEvidence
          value={run.artifacts["gene_evidence.json"]}
          selected={selected}
          onSelect={setSelected}
        />
      </Section>
      <Section title="Saved pathway figures">
        <Figures run={run} />
      </Section>
      <JsonDetails
        value={run.manifest}
        title="Pathway manifest and source hashes"
      />
    </div>
  );
}
