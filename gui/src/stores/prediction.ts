import { create } from "zustand";
import type { EngineResponse, LoadedModel } from "@/lib/types";
interface PredictionState {
  modelPath: string;
  model: LoadedModel | null;
  dataPath: string;
  output: string;
  operation: "predict" | "evaluate";
  timeUnit: string;
  bootstrap: number | null;
  seed: number | null;
  result: EngineResponse | null;
}
export const usePrediction = create<PredictionState>(() => ({
  modelPath: "",
  model: null,
  dataPath: "",
  output: "",
  operation: "predict",
  timeUnit: "",
  bootstrap: 200,
  seed: 1,
  result: null,
}));
