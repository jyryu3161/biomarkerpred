import { useState } from "react";
import { numeric, object, records, strings, text } from "@/lib/value";
import type { JsonObject } from "@/lib/types";
import { DataTable, Facts, Notice } from "./Common";
function GeneDetail({ gene }: { gene: JsonObject }) {
  const links = object(gene.links);
  return (
    <article className="gene-detail">
      <h3 className="identifier">{text(gene.gene)}</h3>
      <Facts
        value={{
          annotation_id: gene.annotation_id,
          mapping_status: gene.mapping_status,
          original_model_gene: gene.original,
          expanded_gene: gene.expanded,
          measured: gene.measured,
          configured_assay: gene.configured_assay,
          configured_eligible: gene.configured_eligible,
          development_qc_eligible: gene.development_qc_eligible,
        }}
      />
      <h4>Outer-fold stability and coefficient direction</h4>
      <Facts
        value={{
          selection_frequency: gene.selection_frequency,
          selected_folds: gene.selected_folds,
          completed_folds: gene.completed_folds,
          positive_frequency: gene.positive_frequency,
          negative_frequency: gene.negative_frequency,
          direction_consistency: gene.direction_consistency,
          mean_standardized_coefficient: gene.mean_standardized_coefficient,
        }}
      />
      <h4>Frozen full-development coefficients</h4>
      <DataTable
        data={records(gene.final_coefficients)}
        title={`${text(gene.gene)} coefficients`}
      />
      <h4>Exploratory full-development rank</h4>
      <Facts
        value={{
          statistic: gene.rank_statistic,
          p_value: gene.rank_p_value,
          method: gene.rank_method,
        }}
      />
      <h4>External evidence</h4>
      <p>
        Score: <strong>{numeric(gene.evidence_score)}</strong> ·{" "}
        {text(gene.evidence_status)}
      </p>
      {gene.evidence_score === null && (
        <p className="muted">
          No supplied matching evidence score. This does not imply absence of a
          biological association.
        </p>
      )}
      <DataTable
        data={records(gene.evidence_records)}
        title={`${text(gene.gene)} supplied evidence`}
      />
      <h4>Pathways and network roles</h4>
      <p>
        {strings(gene.pathways).join(" · ") ||
          "No annotated pathways recorded."}
      </p>
      <p>Network nodes: {strings(gene.graph_node_ids).join(" · ") || "None"}</p>
      <div className="row">
        {Object.entries(links)
          .filter(
            ([, url]) => typeof url === "string" && url.startsWith("https://"),
          )
          .map(([name, url]) => (
            <a key={name} href={text(url)} target="_blank" rel="noreferrer">
              {name.replaceAll("_", " ")}
            </a>
          ))}
      </div>
    </article>
  );
}
export function GeneEvidence({
  value,
  selected,
  onSelect,
}: {
  value: unknown;
  selected: string[];
  onSelect: (genes: string[]) => void;
}) {
  const evidence = object(value),
    genes = records(evidence.records);
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);
  const matches = genes.filter((gene) =>
    [
      text(gene.gene),
      text(gene.annotation_id, ""),
      ...strings(gene.pathways),
    ].some((value) =>
      value.toLocaleLowerCase().includes(query.toLocaleLowerCase()),
    ),
  );
  const last = Math.max(0, Math.ceil(matches.length / 25) - 1),
    current = Math.min(page, last);
  const details = genes.filter((gene) => selected.includes(text(gene.gene)));
  return (
    <div className="stack">
      <p>
        {text(
          evidence.interpretation,
          "Stability, fitted coefficients, exploratory ranks and external evidence describe different quantities.",
        )}
      </p>
      <details>
        <summary>External evidence source and context</summary>
        <Facts value={object(evidence.external_evidence)} omit={["context"]} />
        <Facts value={object(evidence.external_evidence).context} />
      </details>
      <label className="field">
        <span>Search gene evidence</span>
        <input
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setPage(0);
          }}
          placeholder="Exact assay identifier, annotation or pathway"
        />
      </label>
      <p>{matches.length.toLocaleString()} matching genes</p>
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Gene</th>
              <th>Role</th>
              <th>Selection frequency</th>
              <th>Direction consistency</th>
              <th>Rank statistic</th>
              <th>External score</th>
            </tr>
          </thead>
          <tbody>
            {matches.slice(current * 25, (current + 1) * 25).map((gene) => (
              <tr
                key={text(gene.gene)}
                className={
                  selected.includes(text(gene.gene)) ? "selected-row" : ""
                }
              >
                <td>
                  <button
                    className="text-button identifier"
                    onClick={() => onSelect([text(gene.gene)])}
                  >
                    {text(gene.gene)}
                  </button>
                </td>
                <td>
                  {gene.original === true
                    ? "Original model"
                    : gene.expanded === true
                      ? "Expanded"
                      : "Assay background"}
                </td>
                <td>{numeric(gene.selection_frequency)}</td>
                <td>{numeric(gene.direction_consistency)}</td>
                <td>{numeric(gene.rank_statistic)}</td>
                <td>{numeric(gene.evidence_score)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="row pager">
        <button disabled={current === 0} onClick={() => setPage(current - 1)}>
          Previous genes
        </button>
        <span>
          Page {current + 1} / {last + 1}
        </span>
        <button
          disabled={current === last}
          onClick={() => setPage(current + 1)}
        >
          Next genes
        </button>
      </div>
      {selected.length > 0 && !details.length && (
        <Notice>
          No saved gene-evidence record matches the selected node's assay source
          identifiers.
        </Notice>
      )}
      {details.map((gene) => (
        <GeneDetail key={text(gene.gene)} gene={gene} />
      ))}
    </div>
  );
}
