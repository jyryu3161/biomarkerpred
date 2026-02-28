import { create } from "zustand";
import type { OraStatus, EnrichmentCategory, OraSummary } from "@/types/pathway";

export type EvidenceType = "escore" | "dscore" | "tscore" | "ascore" | "nscore" | "fscore" | "pscore";

export const EVIDENCE_LABELS: Record<EvidenceType, string> = {
  escore: "Experiments",
  dscore: "Databases",
  tscore: "Textmining",
  ascore: "Co-expression",
  nscore: "Neighborhood",
  fscore: "Gene Fusion",
  pscore: "Phylogenetic",
};

interface OraState {
  status: OraStatus;
  ppiConfidence: number;
  ppiEvidenceTypes: EvidenceType[];
  organism: number;
  logs: string[];
  progress: { current: number; total: number; message: string };
  summary: OraSummary | null;
  resultDir: string;
  activeCategory: EnrichmentCategory;
  activePlotType: "dotplot" | "barplot";

  setStatus: (s: OraStatus) => void;
  setPpiConfidence: (v: number) => void;
  setPpiEvidenceTypes: (types: EvidenceType[]) => void;
  toggleEvidenceType: (type: EvidenceType) => void;
  appendLog: (line: string) => void;
  setProgress: (current: number, total: number, message: string) => void;
  setSummary: (s: OraSummary | null) => void;
  setResultDir: (dir: string) => void;
  setActiveCategory: (c: EnrichmentCategory) => void;
  setActivePlotType: (t: "dotplot" | "barplot") => void;
  reset: () => void;
}

const initialState = {
  status: "idle" as OraStatus,
  ppiConfidence: 0.7,
  ppiEvidenceTypes: ["escore", "dscore", "tscore", "ascore", "nscore", "fscore", "pscore"] as EvidenceType[],
  organism: 9606,
  logs: [] as string[],
  progress: { current: 0, total: 0, message: "" },
  summary: null as OraSummary | null,
  resultDir: "",
  activeCategory: "go_bp" as EnrichmentCategory,
  activePlotType: "dotplot" as "dotplot" | "barplot",
};

export const useOraStore = create<OraState>()((set) => ({
  ...initialState,

  setStatus: (status) => set({ status }),
  setPpiConfidence: (ppiConfidence) => set({ ppiConfidence }),
  setPpiEvidenceTypes: (ppiEvidenceTypes) => set({ ppiEvidenceTypes }),
  toggleEvidenceType: (type) =>
    set((s) => ({
      ppiEvidenceTypes: s.ppiEvidenceTypes.includes(type)
        ? s.ppiEvidenceTypes.filter((t) => t !== type)
        : [...s.ppiEvidenceTypes, type],
    })),
  appendLog: (line) => set((s) => ({ logs: [...s.logs, line] })),
  setProgress: (current, total, message) =>
    set({ progress: { current, total, message } }),
  setSummary: (summary) => set({ summary }),
  setResultDir: (resultDir) => set({ resultDir }),
  setActiveCategory: (activeCategory) => set({ activeCategory }),
  setActivePlotType: (activePlotType) => set({ activePlotType }),
  reset: () => set(initialState),
}));
