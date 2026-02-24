import { useState } from "react";
import { useAnalysisStore } from "@/stores/analysisStore";

export function FeatureSelectionAccordion() {
  const [open, setOpen] = useState(false);
  const [includeText, setIncludeText] = useState("");
  const [excludeText, setExcludeText] = useState("");
  const dataInfo = useAnalysisStore((s) => s.dataInfo);
  const includeFeatures = useAnalysisStore((s) => s.includeFeatures);
  const excludeFeatures = useAnalysisStore((s) => s.excludeFeatures);
  const setParam = useAnalysisStore((s) => s.setParam);

  const availableColumns = dataInfo?.columns ?? [];

  const addInclude = () => {
    const genes = includeText
      .split(/[,\n]/)
      .map((s) => s.trim())
      .filter(Boolean);
    if (genes.length > 0) {
      setParam("includeFeatures", [
        ...new Set([...includeFeatures, ...genes]),
      ]);
      setIncludeText("");
    }
  };

  const addExclude = () => {
    const genes = excludeText
      .split(/[,\n]/)
      .map((s) => s.trim())
      .filter(Boolean);
    if (genes.length > 0) {
      setParam("excludeFeatures", [
        ...new Set([...excludeFeatures, ...genes]),
      ]);
      setExcludeText("");
    }
  };

  const removeInclude = (gene: string) => {
    setParam(
      "includeFeatures",
      includeFeatures.filter((g) => g !== gene),
    );
  };

  const removeExclude = (gene: string) => {
    setParam(
      "excludeFeatures",
      excludeFeatures.filter((g) => g !== gene),
    );
  };

  return (
    <section className="border border-border rounded-lg">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="w-full flex items-center justify-between p-4 text-sm font-medium hover:bg-muted/30 transition-colors"
      >
        <span>
          Feature Selection
          {(includeFeatures.length > 0 || excludeFeatures.length > 0) && (
            <span className="ml-2 text-xs text-muted-foreground font-normal">
              ({includeFeatures.length} include, {excludeFeatures.length}{" "}
              exclude)
            </span>
          )}
        </span>
        <span className="text-muted-foreground">{open ? "-" : "+"}</span>
      </button>

      {open && (
        <div className="px-4 pb-4 space-y-4">
          {/* Quick select from data columns */}
          {availableColumns.length > 0 && (
            <div>
              <label className="text-xs font-medium text-muted-foreground block mb-1">
                Quick exclude columns from data
              </label>
              <div className="flex flex-wrap gap-1 max-h-24 overflow-y-auto">
                {availableColumns.map((col) => {
                  const isExcluded = excludeFeatures.includes(col);
                  return (
                    <button
                      key={col}
                      onClick={() =>
                        isExcluded ? removeExclude(col) : setParam("excludeFeatures", [...excludeFeatures, col])
                      }
                      className={`px-2 py-0.5 text-xs rounded-full border transition-colors ${
                        isExcluded
                          ? "border-destructive/50 bg-destructive/10 text-destructive"
                          : "border-border hover:border-muted-foreground/40"
                      }`}
                    >
                      {col}
                    </button>
                  );
                })}
              </div>
            </div>
          )}

          {/* Include list */}
          <div className="space-y-2">
            <label className="text-xs font-medium text-muted-foreground">
              Include Features (comma-separated)
            </label>
            <div className="flex gap-2">
              <input
                type="text"
                value={includeText}
                onChange={(e) => setIncludeText(e.target.value)}
                placeholder="GENE1, GENE2, ..."
                className="flex-1 h-8 px-3 rounded-md border border-border bg-background text-xs focus:outline-none focus:ring-1 focus:ring-primary"
                onKeyDown={(e) => e.key === "Enter" && addInclude()}
              />
              <button
                onClick={addInclude}
                className="px-3 h-8 bg-secondary text-secondary-foreground rounded-md text-xs hover:bg-secondary/80 transition-colors"
              >
                Add
              </button>
            </div>
            {includeFeatures.length > 0 && (
              <div className="flex flex-wrap gap-1">
                {includeFeatures.map((gene) => (
                  <span
                    key={gene}
                    className="inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-primary/10 text-primary border border-primary/20"
                  >
                    {gene}
                    <button
                      onClick={() => removeInclude(gene)}
                      className="hover:text-destructive"
                    >
                      x
                    </button>
                  </span>
                ))}
              </div>
            )}
          </div>

          {/* Exclude list */}
          <div className="space-y-2">
            <label className="text-xs font-medium text-muted-foreground">
              Exclude Features (comma-separated)
            </label>
            <div className="flex gap-2">
              <input
                type="text"
                value={excludeText}
                onChange={(e) => setExcludeText(e.target.value)}
                placeholder="GENE1, GENE2, ..."
                className="flex-1 h-8 px-3 rounded-md border border-border bg-background text-xs focus:outline-none focus:ring-1 focus:ring-primary"
                onKeyDown={(e) => e.key === "Enter" && addExclude()}
              />
              <button
                onClick={addExclude}
                className="px-3 h-8 bg-secondary text-secondary-foreground rounded-md text-xs hover:bg-secondary/80 transition-colors"
              >
                Add
              </button>
            </div>
            {excludeFeatures.length > 0 && (
              <div className="flex flex-wrap gap-1">
                {excludeFeatures.map((gene) => (
                  <span
                    key={gene}
                    className="inline-flex items-center gap-1 px-2 py-0.5 text-xs rounded-full bg-destructive/10 text-destructive border border-destructive/20"
                  >
                    {gene}
                    <button
                      onClick={() => removeExclude(gene)}
                      className="hover:text-foreground"
                    >
                      x
                    </button>
                  </span>
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </section>
  );
}
