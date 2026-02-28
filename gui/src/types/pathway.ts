export type OraStatus = "idle" | "running" | "completed" | "failed";

export type EnrichmentCategory = "go_bp" | "go_mf" | "go_cc" | "kegg" | "reactome";

export const ENRICHMENT_LABELS: Record<EnrichmentCategory, string> = {
  go_bp: "GO: Biological Process",
  go_mf: "GO: Molecular Function",
  go_cc: "GO: Cellular Component",
  kegg: "KEGG",
  reactome: "Reactome",
};

export const ENRICHMENT_SHORT_LABELS: Record<EnrichmentCategory, string> = {
  go_bp: "GO:BP",
  go_mf: "GO:MF",
  go_cc: "GO:CC",
  kegg: "KEGG",
  reactome: "Reactome",
};

export interface EnrichmentTerm {
  id: string;
  description: string;
  geneRatio: string;
  bgRatio: string;
  pvalue: number;
  pAdjust: number;
  qvalue: number;
  geneID: string;
  count: number;
}

export interface OraSummary {
  candidateGenes: string[];
  candidateGeneCount: number;
  ppiInteractors: string[];
  ppiInteractorCount: number;
  totalGenesAnalyzed: number;
  ppiConfidence: number;
  organism: number;
  results: Record<
    EnrichmentCategory,
    { significantTerms: number; topTerm: string }
  >;
  timestamp: string;
}
