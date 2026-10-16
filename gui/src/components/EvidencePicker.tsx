import { useState } from "react";
import { useJob } from "@/stores/job";
import { api } from "@/lib/api";
import { errorText, number, object, text } from "@/lib/value";
import type { Disease, EvidenceSnapshot, JsonObject } from "@/lib/types";
import { Field, Facts, Notice, PathField } from "./Common";
export function EvidencePicker({
  value,
  onChange,
}: {
  value: unknown;
  onChange: (value: JsonObject | null) => void;
}) {
  const evidence = object(value);
  const jobBusy = useJob((state) => state.busy);
  const [query, setQuery] = useState("");
  const [diseases, setDiseases] = useState<Disease[]>([]);
  const [cache, setCache] = useState<EvidenceSnapshot[]>([]);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");
  const [selectedSnapshot, setSnapshot] = useState<EvidenceSnapshot | null>(
    null,
  );
  const action = async (fn: () => Promise<void>) => {
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
  const patch = (update: JsonObject) => onChange({ ...evidence, ...update });
  const select = (snapshot: EvidenceSnapshot, disease?: Disease) => {
    const meta = snapshot.provenance;
    onChange({
      gene_file: snapshot.file_path,
      score_threshold: number(evidence.score_threshold) ?? 0,
      source: text(meta.source, "Open Targets Platform"),
      disease_name: snapshot.disease_name ?? disease?.name ?? meta.disease_name,
      efo_id: snapshot.efo_id ?? disease?.efo_id ?? meta.efo_id,
      retrieved_at: snapshot.fetched_at ?? meta.fetched_at,
      ...(typeof meta.release === "string" ? { version: meta.release } : {}),
    });
    setSnapshot(snapshot);
  };
  return (
    <div className="stack">
      <p className="muted">
        Optional external evidence restricts the candidate genes before nested
        training. Scores retain their source and disease context. Missing
        evidence is never a zero score.
      </p>
      <PathField
        label="Evidence CSV"
        value={text(evidence.gene_file, "")}
        onChange={(gene_file) => {
          setSnapshot(null);
          onChange(
            gene_file
              ? {
                  gene_file,
                  score_threshold: number(evidence.score_threshold) ?? 0,
                  source: "user_supplied_evidence",
                }
              : null,
          );
        }}
        hint="CSV columns: gene_symbol, score, and optional ensembl_id. Select exact assay identifiers."
      />
      {Object.keys(evidence).length > 0 && (
        <>
          <div className="form-grid">
            <Field label="Evidence score threshold">
              <input
                type="number"
                min="0"
                max="1"
                step="0.01"
                value={text(evidence.score_threshold, "0")}
                onChange={(e) =>
                  patch({ score_threshold: number(e.target.value) })
                }
              />
            </Field>
            {[
              ["source", "Evidence source"],
              ["disease_name", "Disease / context"],
              ["efo_id", "Disease / ontology ID"],
              ["version", "Evidence release (if known)"],
              ["retrieved_at", "Evidence retrieved at"],
            ].map(([key, name]) => (
              <Field key={key} label={name}>
                <input
                  value={text(evidence[key], "")}
                  onChange={(e) => patch({ [key]: e.target.value || null })}
                />
              </Field>
            ))}
          </div>
          <button
            onClick={() => {
              onChange(null);
              setSnapshot(null);
            }}
          >
            Remove evidence restriction
          </button>
        </>
      )}
      <details>
        <summary>Open Targets disease evidence</summary>
        <p>
          Search the public disease catalogue or reuse an immutable local
          snapshot. Fetching requests public target associations only.
        </p>
        <div className="row">
          <Field label="Disease search">
            <input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="e.g. breast carcinoma"
            />
          </Field>
          <button
            disabled={working || !query.trim()}
            onClick={() =>
              void action(async () =>
                setDiseases(await api.searchDisease(query)),
              )
            }
          >
            Search diseases
          </button>
          <button
            disabled={working}
            onClick={() =>
              void action(async () => setCache(await api.cachedEvidence()))
            }
          >
            Refresh evidence cache
          </button>
        </div>
        {working && <p role="status">Loading evidence…</p>}
        {error && <Notice tone="error">{error}</Notice>}
        <div className="search-results">
          {diseases.map((disease) => (
            <article key={disease.efo_id}>
              <strong>{disease.name}</strong>
              <code>{disease.efo_id}</code>
              <p>{disease.description}</p>
              <button
                disabled={working}
                onClick={() =>
                  void action(async () => {
                    const snapshot = await api.fetchEvidence(
                      disease.efo_id,
                      disease.name,
                    );
                    select(snapshot, disease);
                    setCache(await api.cachedEvidence());
                  })
                }
              >
                Fetch {disease.name}
              </button>
            </article>
          ))}
        </div>
        {cache.length > 0 && <h3>Immutable cached snapshots</h3>}
        {cache.map((snapshot) => (
          <article className="cache-row" key={snapshot.cache_key}>
            <div>
              <strong>{snapshot.disease_name}</strong>
              <span>
                {" "}
                {snapshot.efo_id} · {snapshot.gene_count.toLocaleString()} genes
                · {snapshot.fetched_at}
              </span>
              <code>{snapshot.file_path}</code>
            </div>
            <button disabled={working} onClick={() => select(snapshot)}>
              Use snapshot
            </button>
            <button
              disabled={
                working || jobBusy || evidence.gene_file === snapshot.file_path
              }
              onClick={() =>
                void action(async () => {
                  await api.deleteEvidence(snapshot.cache_key);
                  setCache(await api.cachedEvidence());
                })
              }
            >
              Delete snapshot
            </button>
          </article>
        ))}
        {selectedSnapshot && (
          <div>
            <h3>Selected snapshot provenance</h3>
            <Facts value={selectedSnapshot.provenance} />
          </div>
        )}
      </details>
    </div>
  );
}
