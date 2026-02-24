import { useState, useEffect } from "react";
import { readTextFile } from "@/lib/tauri/commands";

interface AucRow {
  iteration: number;
  trainAuc: number;
  testAuc: number;
  genes: string;
}

/** Parse auc_iterations.csv content into AucRow array.
 *
 * The CSV file produced by the R analysis scripts has a header row followed
 * by one row per iteration.  Column names are flexible but we look for:
 *   - iteration / Iteration / seed (integer)
 *   - train_auc / trainAuc / Train_AUC (numeric)
 *   - test_auc  / testAuc  / Test_AUC  (numeric)
 *   - selected_genes / genes / Selected_Genes (comma-joined gene list)
 *
 * Matching is case-insensitive and underscore/camelCase agnostic.
 */
function parseCsv(raw: string): AucRow[] {
  const lines = raw.trim().split(/\r?\n/);
  if (lines.length < 2) return [];

  // Strip surrounding quotes from a CSV field value
  const unquote = (s: string) => s.trim().replace(/^"(.*)"$/, "$1");

  const headers = lines[0].split(",").map((h) => unquote(h).toLowerCase().replace(/[_\s]/g, ""));

  const findCol = (...candidates: string[]): number => {
    for (const c of candidates) {
      const idx = headers.indexOf(c);
      if (idx !== -1) return idx;
    }
    return -1;
  };

  const iterCol = findCol("iteration", "seed", "iter");
  const trainCol = findCol("trainauc", "train_auc", "trainauc", "traianauc");
  const testCol = findCol("testauc", "test_auc", "testauc");
  const geneCol = findCol("selectedgenes", "genes", "selectedgene", "gene");

  const rows: AucRow[] = [];

  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;

    // Simple CSV split (does not handle quoted fields with commas inside)
    const fields = line.split(",").map(unquote);

    const iteration = iterCol >= 0 ? parseInt(fields[iterCol] ?? "", 10) : i;
    const trainAuc = trainCol >= 0 ? parseFloat(fields[trainCol] ?? "0") : 0;
    const testAuc = testCol >= 0 ? parseFloat(fields[testCol] ?? "0") : 0;
    const genes = geneCol >= 0 ? (fields[geneCol] ?? "").replace(/;/g, ", ") : "";

    if (isNaN(iteration)) continue;

    rows.push({ iteration, trainAuc, testAuc, genes });
  }

  return rows;
}

export function AucTable({ outputDir }: { outputDir: string }) {
  const [rows, setRows] = useState<AucRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!outputDir) {
      setRows([]);
      return;
    }

    setLoading(true);
    setError(null);

    // The R analysis scripts write auc_iterations.csv to the output directory root
    const csvPath = `${outputDir}/auc_iterations.csv`;

    readTextFile(csvPath)
      .then((content) => {
        const parsed = parseCsv(content);
        setRows(parsed);
        setError(null);
      })
      .catch(() => {
        // File may not exist yet (analysis in progress, or no output yet)
        setRows([]);
        setError(null);
      })
      .finally(() => setLoading(false));
  }, [outputDir]);

  if (loading) {
    return (
      <div className="border border-border rounded-lg p-4">
        <h3 className="text-sm font-medium mb-2">AUC Summary</h3>
        <p className="text-xs text-muted-foreground">Loading AUC data...</p>
      </div>
    );
  }

  if (rows.length === 0) {
    return (
      <div className="border border-border rounded-lg p-4">
        <h3 className="text-sm font-medium mb-2">AUC Summary</h3>
        <p className="text-xs text-muted-foreground">
          AUC iteration data will appear here after analysis completes.
          {error && <span className="text-destructive ml-1">({error})</span>}
        </p>
      </div>
    );
  }

  return (
    <div className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">AUC Summary ({rows.length} iterations)</h3>
      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="bg-muted/50">
              <th className="px-3 py-2 text-left font-medium">Iteration</th>
              <th className="px-3 py-2 text-left font-medium">Train AUC</th>
              <th className="px-3 py-2 text-left font-medium">Test AUC</th>
              <th className="px-3 py-2 text-left font-medium">Selected Genes</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.iteration} className="border-t border-border hover:bg-muted/20">
                <td className="px-3 py-2 font-mono">{row.iteration}</td>
                <td className="px-3 py-2 font-mono">{row.trainAuc.toFixed(4)}</td>
                <td className="px-3 py-2 font-mono">{row.testAuc.toFixed(4)}</td>
                <td className="px-3 py-2 text-muted-foreground truncate max-w-xs" title={row.genes}>
                  {row.genes || "-"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
