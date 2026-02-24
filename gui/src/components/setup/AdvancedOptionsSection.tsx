import { useEffect, useRef, useState, useCallback } from "react";
import { useAnalysisStore } from "@/stores/analysisStore";
import {
  searchDiseases,
  fetchOpenTargetsGenes,
  listCachedEvidence,
  deleteCachedEvidence,
  countFilteredGenes,
} from "@/lib/tauri/commands";
import type { PAdjustMethod, OTDisease, CachedEvidence } from "@/types/analysis";

function Checkbox({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <label className="flex items-center gap-2 cursor-pointer">
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="w-4 h-4 rounded border-border accent-primary cursor-pointer"
      />
      <span className="text-sm">{label}</span>
    </label>
  );
}

function DiseaseSearch({
  onSelect,
}: {
  onSelect: (disease: OTDisease) => void;
}) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<OTDisease[]>([]);
  const [isSearching, setIsSearching] = useState(false);
  const [isOpen, setIsOpen] = useState(false);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  const doSearch = useCallback(async (q: string) => {
    if (q.trim().length < 2) {
      setResults([]);
      setIsOpen(false);
      return;
    }
    setIsSearching(true);
    try {
      const diseases = await searchDiseases(q);
      setResults(diseases);
      setIsOpen(diseases.length > 0);
    } catch {
      setResults([]);
      setIsOpen(false);
    } finally {
      setIsSearching(false);
    }
  }, []);

  const handleInputChange = (value: string) => {
    setQuery(value);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => doSearch(value), 300);
  };

  const handleSelect = (disease: OTDisease) => {
    setQuery(disease.name);
    setIsOpen(false);
    onSelect(disease);
  };

  useEffect(() => {
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, []);

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setIsOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, []);

  return (
    <div ref={containerRef} className="relative">
      <div className="flex items-center gap-2">
        <input
          type="text"
          value={query}
          onChange={(e) => handleInputChange(e.target.value)}
          onFocus={() => results.length > 0 && setIsOpen(true)}
          placeholder="Search diseases (e.g. breast cancer, glioma, leukemia)..."
          className="flex-1 h-9 px-3 rounded-md border border-border bg-background text-sm focus:outline-none focus:ring-1 focus:ring-primary"
        />
        {isSearching && (
          <span className="text-xs text-muted-foreground animate-pulse">Searching...</span>
        )}
      </div>

      {isOpen && (
        <ul className="absolute z-50 mt-1 w-full max-h-60 overflow-y-auto rounded-md border border-border bg-background shadow-lg">
          {results.map((d) => (
            <li key={d.efo_id}>
              <button
                onClick={() => handleSelect(d)}
                className="w-full text-left px-3 py-2 hover:bg-accent transition-colors"
              >
                <div className="text-sm font-medium">{d.name}</div>
                <div className="text-xs text-muted-foreground truncate">
                  {d.efo_id}
                  {d.description && ` — ${d.description}`}
                </div>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function AdvancedOptionsSection() {
  const enablePValueFilter = useAnalysisStore((s) => s.enablePValueFilter);
  const pAdjustMethod = useAnalysisStore((s) => s.pAdjustMethod);
  const pThreshold = useAnalysisStore((s) => s.pThreshold);
  const topK = useAnalysisStore((s) => s.topK);
  const enableEvidence = useAnalysisStore((s) => s.enableEvidence);
  const evidenceGeneFile = useAnalysisStore((s) => s.evidenceGeneFile);
  const evidenceScoreThreshold = useAnalysisStore((s) => s.evidenceScoreThreshold);
  const selectedDiseaseId = useAnalysisStore((s) => s.selectedDiseaseId);
  const selectedDiseaseName = useAnalysisStore((s) => s.selectedDiseaseName);
  const isFetchingGenes = useAnalysisStore((s) => s.isFetchingGenes);
  const setParam = useAnalysisStore((s) => s.setParam);

  const [fetchError, setFetchError] = useState<string | null>(null);
  const [cachedFiles, setCachedFiles] = useState<CachedEvidence[]>([]);
  const [filteredCount, setFilteredCount] = useState<{ total: number; passed: number } | null>(null);
  const thresholdDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Load cached files when evidence is enabled
  useEffect(() => {
    if (enableEvidence) {
      listCachedEvidence()
        .then(setCachedFiles)
        .catch(() => setCachedFiles([]));
    }
  }, [enableEvidence]);

  // Recount filtered genes when threshold or file changes
  useEffect(() => {
    if (!evidenceGeneFile) {
      setFilteredCount(null);
      return;
    }
    if (thresholdDebounceRef.current) clearTimeout(thresholdDebounceRef.current);
    thresholdDebounceRef.current = setTimeout(() => {
      countFilteredGenes(evidenceGeneFile, evidenceScoreThreshold)
        .then(setFilteredCount)
        .catch(() => setFilteredCount(null));
    }, 200);
    return () => {
      if (thresholdDebounceRef.current) clearTimeout(thresholdDebounceRef.current);
    };
  }, [evidenceGeneFile, evidenceScoreThreshold]);

  const refreshCache = () => {
    listCachedEvidence()
      .then(setCachedFiles)
      .catch(() => setCachedFiles([]));
  };

  const handleDiseaseSelect = (disease: OTDisease) => {
    setParam("selectedDiseaseId", disease.efo_id);
    setParam("selectedDiseaseName", disease.name);
    setParam("fetchedGeneCount", null);
    setFetchError(null);

    // Auto-select if already cached
    const cached = cachedFiles.find((c) => c.efo_id === disease.efo_id);
    if (cached) {
      setParam("evidenceGeneFile", cached.file_path);
      setParam("fetchedGeneCount", cached.gene_count);
    } else {
      setParam("evidenceGeneFile", "");
    }
  };

  const handleFetchGenes = async () => {
    if (!selectedDiseaseId) return;
    setParam("isFetchingGenes", true);
    setFetchError(null);
    try {
      const result = await fetchOpenTargetsGenes(selectedDiseaseId, selectedDiseaseName);
      setParam("evidenceGeneFile", result.file_path);
      setParam("fetchedGeneCount", result.gene_count);
      refreshCache();
    } catch (e) {
      setFetchError(String(e));
      setParam("fetchedGeneCount", null);
    } finally {
      setParam("isFetchingGenes", false);
    }
  };

  const handleSelectCached = (cached: CachedEvidence) => {
    setParam("selectedDiseaseId", cached.efo_id);
    setParam("selectedDiseaseName", cached.disease_name);
    setParam("evidenceGeneFile", cached.file_path);
    setParam("fetchedGeneCount", cached.gene_count);
    setFetchError(null);
  };

  const handleDeleteCached = async (efoId: string) => {
    try {
      await deleteCachedEvidence(efoId);
      // Clear selection if deleted item was selected
      if (selectedDiseaseId === efoId) {
        setParam("selectedDiseaseId", "");
        setParam("selectedDiseaseName", "");
        setParam("evidenceGeneFile", "");
        setParam("fetchedGeneCount", null);
      }
      refreshCache();
    } catch (e) {
      console.error("Delete failed:", e);
    }
  };

  return (
    <section className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Advanced Options</h3>

      <div className="space-y-4">
        {/* P-value filtering */}
        <div className="space-y-3">
          <Checkbox
            label="Enable P-value filtering"
            checked={enablePValueFilter}
            onChange={(v) => setParam("enablePValueFilter", v)}
          />

          {enablePValueFilter && (
            <div className="ml-6 space-y-3">
              <div className="grid grid-cols-3 gap-3">
                <div className="flex flex-col gap-1">
                  <label className="text-xs font-medium text-muted-foreground">
                    Adjustment Method
                  </label>
                  <select
                    value={pAdjustMethod}
                    onChange={(e) =>
                      setParam("pAdjustMethod", e.target.value as PAdjustMethod)
                    }
                    className="h-9 px-3 rounded-md border border-border bg-background text-sm focus:outline-none focus:ring-1 focus:ring-primary"
                  >
                    <option value="fdr">FDR (BH)</option>
                    <option value="bonferroni">Bonferroni</option>
                    <option value="none">None</option>
                  </select>
                </div>

                <div className="flex flex-col gap-1">
                  <label className="text-xs font-medium text-muted-foreground">
                    P-value Threshold
                  </label>
                  <input
                    type="number"
                    value={pThreshold}
                    min={0.001}
                    max={1}
                    step={0.01}
                    onChange={(e) => setParam("pThreshold", Number(e.target.value))}
                    className="h-9 px-3 rounded-md border border-border bg-background text-sm font-mono focus:outline-none focus:ring-1 focus:ring-primary"
                  />
                </div>

                <div className="flex flex-col gap-1">
                  <label className="text-xs font-medium text-muted-foreground">
                    Top K Genes
                  </label>
                  <input
                    type="number"
                    value={topK ?? ""}
                    min={1}
                    max={10000}
                    placeholder="All"
                    onChange={(e) =>
                      setParam("topK", e.target.value ? Number(e.target.value) : null)
                    }
                    className="h-9 px-3 rounded-md border border-border bg-background text-sm font-mono focus:outline-none focus:ring-1 focus:ring-primary"
                  />
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Evidence-based filtering */}
        <div className="space-y-3 pt-2 border-t border-border">
          <Checkbox
            label="Use evidence-based gene filtering (Open Targets)"
            checked={enableEvidence}
            onChange={(v) => setParam("enableEvidence", v)}
          />

          {enableEvidence && (
            <div className="ml-6 space-y-4">
              {/* Cached files */}
              {cachedFiles.length > 0 && (
                <div className="flex flex-col gap-1">
                  <label className="text-xs font-medium text-muted-foreground">
                    Previously Fetched
                  </label>
                  <div className="border border-border rounded-md divide-y divide-border max-h-40 overflow-y-auto">
                    {cachedFiles.map((c) => {
                      const isSelected = evidenceGeneFile === c.file_path;
                      return (
                        <div
                          key={c.efo_id}
                          className={`flex items-center px-3 py-2 text-sm transition-colors ${
                            isSelected
                              ? "bg-primary/10 text-primary"
                              : "hover:bg-accent"
                          }`}
                        >
                          <button
                            onClick={() => handleSelectCached(c)}
                            className="flex-1 text-left"
                          >
                            <div className="flex items-center justify-between">
                              <span className="font-medium">{c.disease_name}</span>
                              <span className="text-xs text-muted-foreground">
                                {c.gene_count.toLocaleString()} genes
                              </span>
                            </div>
                            <div className="text-xs text-muted-foreground">
                              {c.efo_id} &middot; {c.fetched_at}
                            </div>
                          </button>
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              handleDeleteCached(c.efo_id);
                            }}
                            className="ml-2 p-1 text-muted-foreground hover:text-destructive transition-colors shrink-0"
                            title="Delete cached evidence"
                          >
                            <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/></svg>
                          </button>
                        </div>
                      );
                    })}
                  </div>
                </div>
              )}

              {/* Search new disease */}
              <div className="flex flex-col gap-1">
                <label className="text-xs font-medium text-muted-foreground">
                  {cachedFiles.length > 0 ? "Or Search New Disease" : "Search Disease (Open Targets Platform)"}
                </label>
                <DiseaseSearch onSelect={handleDiseaseSelect} />
              </div>

              {selectedDiseaseId && (
                <div className="space-y-3">
                  <p className="text-xs text-muted-foreground">
                    Selected: <span className="font-medium text-foreground">{selectedDiseaseName}</span>{" "}
                    <span className="text-muted-foreground">({selectedDiseaseId})</span>
                  </p>

                  <button
                    onClick={handleFetchGenes}
                    disabled={isFetchingGenes}
                    className="h-9 px-4 bg-primary text-primary-foreground rounded-md text-sm font-medium hover:bg-primary/90 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    {isFetchingGenes
                      ? "Fetching all genes..."
                      : cachedFiles.some((c) => c.efo_id === selectedDiseaseId)
                        ? "Re-fetch Genes"
                        : "Fetch Genes"}
                  </button>

                  {fetchError && (
                    <p className="text-xs text-destructive">{fetchError}</p>
                  )}
                </div>
              )}

              {/* Score threshold */}
              <div className="flex flex-col gap-1 max-w-xs">
                <label className="text-xs font-medium text-muted-foreground">
                  Score Threshold
                </label>
                <input
                  type="number"
                  value={evidenceScoreThreshold}
                  min={0}
                  max={1}
                  step={0.01}
                  onChange={(e) =>
                    setParam("evidenceScoreThreshold", Number(e.target.value))
                  }
                  className="h-9 px-3 rounded-md border border-border bg-background text-sm font-mono focus:outline-none focus:ring-1 focus:ring-primary"
                />
              </div>

              {/* Filtered count display */}
              {filteredCount && (
                <p className="text-xs text-green-600">
                  {filteredCount.passed.toLocaleString()} / {filteredCount.total.toLocaleString()} genes
                  pass threshold &ge; {evidenceScoreThreshold}
                </p>
              )}
            </div>
          )}
        </div>
      </div>
    </section>
  );
}
