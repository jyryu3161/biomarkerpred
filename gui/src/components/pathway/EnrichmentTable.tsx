import { useState, useEffect } from "react";
import { readTextFile } from "@/lib/tauri/commands";
import type { EnrichmentCategory, EnrichmentTerm } from "@/types/pathway";
import { ENRICHMENT_LABELS } from "@/types/pathway";
import { useOraStore } from "@/stores/oraStore";

function parseCsv(raw: string): EnrichmentTerm[] {
  const lines = raw.trim().split(/\r?\n/);
  if (lines.length < 2) return [];

  const unquote = (s: string) => s.trim().replace(/^"(.*)"$/, "$1");
  const headers = lines[0].split(",").map((h) => unquote(h));

  const findCol = (name: string): number =>
    headers.findIndex((h) => h.toLowerCase() === name.toLowerCase());

  const idCol = findCol("ID");
  const descCol = findCol("Description");
  const grCol = findCol("GeneRatio");
  const brCol = findCol("BgRatio");
  const pvCol = findCol("pvalue");
  const paCol = findCol("p.adjust");
  const qvCol = findCol("qvalue");
  const giCol = findCol("geneID");
  const ctCol = findCol("Count");

  const rows: EnrichmentTerm[] = [];
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;

    // Handle CSV fields that may contain commas within quotes
    const fields: string[] = [];
    let current = "";
    let inQuotes = false;
    for (const ch of line) {
      if (ch === '"') {
        inQuotes = !inQuotes;
      } else if (ch === "," && !inQuotes) {
        fields.push(unquote(current));
        current = "";
      } else {
        current += ch;
      }
    }
    fields.push(unquote(current));

    const pAdj = paCol >= 0 ? parseFloat(fields[paCol] ?? "1") : 1;
    if (isNaN(pAdj)) continue;

    rows.push({
      id: idCol >= 0 ? (fields[idCol] ?? "") : "",
      description: descCol >= 0 ? (fields[descCol] ?? "") : "",
      geneRatio: grCol >= 0 ? (fields[grCol] ?? "") : "",
      bgRatio: brCol >= 0 ? (fields[brCol] ?? "") : "",
      pvalue: pvCol >= 0 ? parseFloat(fields[pvCol] ?? "1") : 1,
      pAdjust: pAdj,
      qvalue: qvCol >= 0 ? parseFloat(fields[qvCol] ?? "1") : 1,
      geneID: giCol >= 0 ? (fields[giCol] ?? "") : "",
      count: ctCol >= 0 ? parseInt(fields[ctCol] ?? "0", 10) : 0,
    });
  }

  return rows;
}

type SortKey = "pAdjust" | "count" | "description";

export function EnrichmentTable() {
  const resultDir = useOraStore((s) => s.resultDir);
  const status = useOraStore((s) => s.status);
  const activeCategory = useOraStore((s) => s.activeCategory);

  const [terms, setTerms] = useState<EnrichmentTerm[]>([]);
  const [loading, setLoading] = useState(false);
  const [sortKey, setSortKey] = useState<SortKey>("pAdjust");
  const [sortAsc, setSortAsc] = useState(true);

  useEffect(() => {
    if (!resultDir || status !== "completed") {
      setTerms([]);
      return;
    }

    setLoading(true);
    const csvPath = `${resultDir}/ora_${activeCategory}.csv`;
    readTextFile(csvPath)
      .then((content) => setTerms(parseCsv(content)))
      .catch(() => setTerms([]))
      .finally(() => setLoading(false));
  }, [resultDir, status, activeCategory]);

  const handleSort = (key: SortKey) => {
    if (sortKey === key) {
      setSortAsc(!sortAsc);
    } else {
      setSortKey(key);
      setSortAsc(key === "description" ? true : true);
    }
  };

  const sorted = [...terms].sort((a, b) => {
    const dir = sortAsc ? 1 : -1;
    if (sortKey === "pAdjust") return (a.pAdjust - b.pAdjust) * dir;
    if (sortKey === "count") return (a.count - b.count) * dir;
    return a.description.localeCompare(b.description) * dir;
  });

  if (status !== "completed") return null;

  const sortIcon = (key: SortKey) => {
    if (sortKey !== key) return "";
    return sortAsc ? " ↑" : " ↓";
  };

  return (
    <div className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">
        {ENRICHMENT_LABELS[activeCategory]} — Enrichment Results
        {terms.length > 0 && (
          <span className="font-normal text-muted-foreground ml-2">
            ({terms.length} terms)
          </span>
        )}
      </h3>

      {loading ? (
        <p className="text-xs text-muted-foreground">Loading results...</p>
      ) : terms.length === 0 ? (
        <p className="text-xs text-muted-foreground">
          No significant enrichment terms found (q-value &lt; 0.05).
        </p>
      ) : (
        <div className="overflow-x-auto max-h-80 overflow-y-auto">
          <table className="w-full text-xs">
            <thead className="sticky top-0 bg-background">
              <tr className="bg-muted/50">
                <th className="px-2 py-1.5 text-left font-medium">ID</th>
                <th
                  className="px-2 py-1.5 text-left font-medium cursor-pointer hover:text-primary"
                  onClick={() => handleSort("description")}
                >
                  Description{sortIcon("description")}
                </th>
                <th className="px-2 py-1.5 text-left font-medium">
                  GeneRatio
                </th>
                <th
                  className="px-2 py-1.5 text-left font-medium cursor-pointer hover:text-primary"
                  onClick={() => handleSort("pAdjust")}
                >
                  p.adjust{sortIcon("pAdjust")}
                </th>
                <th
                  className="px-2 py-1.5 text-left font-medium cursor-pointer hover:text-primary"
                  onClick={() => handleSort("count")}
                >
                  Count{sortIcon("count")}
                </th>
                <th className="px-2 py-1.5 text-left font-medium">Genes</th>
              </tr>
            </thead>
            <tbody>
              {sorted.map((term) => (
                <tr
                  key={term.id}
                  className="border-t border-border hover:bg-muted/20"
                >
                  <td className="px-2 py-1.5 font-mono text-muted-foreground">
                    {term.id}
                  </td>
                  <td className="px-2 py-1.5 max-w-xs truncate" title={term.description}>
                    {term.description}
                  </td>
                  <td className="px-2 py-1.5 font-mono">{term.geneRatio}</td>
                  <td className="px-2 py-1.5 font-mono">
                    {term.pAdjust < 0.001
                      ? term.pAdjust.toExponential(2)
                      : term.pAdjust.toFixed(4)}
                  </td>
                  <td className="px-2 py-1.5 font-mono">{term.count}</td>
                  <td
                    className="px-2 py-1.5 text-muted-foreground max-w-[200px] truncate"
                    title={term.geneID.replace(/\//g, ", ")}
                  >
                    {term.geneID.replace(/\//g, ", ")}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
