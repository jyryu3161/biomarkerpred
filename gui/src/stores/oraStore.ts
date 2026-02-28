import { create } from "zustand";
import type { OraStatus, EnrichmentCategory, OraSummary } from "@/types/pathway";

interface OraState {
  status: OraStatus;
  ppiConfidence: number;
  organism: number;
  logs: string[];
  progress: { current: number; total: number; message: string };
  summary: OraSummary | null;
  resultDir: string;
  activeCategory: EnrichmentCategory;
  activePlotType: "dotplot" | "barplot";

  setStatus: (s: OraStatus) => void;
  setPpiConfidence: (v: number) => void;
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
  appendLog: (line) => set((s) => ({ logs: [...s.logs, line] })),
  setProgress: (current, total, message) =>
    set({ progress: { current, total, message } }),
  setSummary: (summary) => set({ summary }),
  setResultDir: (resultDir) => set({ resultDir }),
  setActiveCategory: (activeCategory) => set({ activeCategory }),
  setActivePlotType: (activePlotType) => set({ activePlotType }),
  reset: () => set(initialState),
}));
