import { create } from "zustand";
import type { TcgaPreset, RuntimeInfo, EnvStatus, ExecutionBackend } from "@/types/analysis";

export type SetupStatus = "idle" | "installing" | "completed" | "failed" | "cancelled";

interface ConfigState {
  runtime: RuntimeInfo;
  presets: TcgaPreset[];
  runtimeChecked: boolean;
  rPathOverride: string;
  pixiPathOverride: string;

  // Environment setup state
  envStatus: EnvStatus | null;
  envChecking: boolean;
  backend: ExecutionBackend;
  setupStatus: SetupStatus;
  setupLogs: string[];
  setupStep: { step: number; total: number; message: string };
  setupError: string;

  setRuntimeInfo: (info: RuntimeInfo) => void;
  setPresets: (presets: TcgaPreset[]) => void;
  setRPathOverride: (path: string) => void;
  setPixiPathOverride: (path: string) => void;

  setEnvStatus: (status: EnvStatus) => void;
  setEnvChecking: (checking: boolean) => void;
  setBackend: (backend: ExecutionBackend) => void;
  setSetupStatus: (status: SetupStatus) => void;
  appendSetupLog: (line: string) => void;
  clearSetupLogs: () => void;
  setSetupStep: (step: number, total: number, message: string) => void;
  setSetupError: (error: string) => void;
}

export const useConfigStore = create<ConfigState>()((set) => ({
  runtime: { rPath: null, pixiPath: null, rVersion: null },
  presets: [],
  runtimeChecked: false,
  rPathOverride: "",
  pixiPathOverride: "",

  envStatus: null,
  envChecking: false,
  backend: "docker",
  setupStatus: "idle",
  setupLogs: [],
  setupStep: { step: 0, total: 0, message: "" },
  setupError: "",

  setRuntimeInfo: (info) => set({ runtime: info, runtimeChecked: true }),
  setPresets: (presets) => set({ presets }),
  setRPathOverride: (path) => set({ rPathOverride: path }),
  setPixiPathOverride: (path) => set({ pixiPathOverride: path }),

  setEnvStatus: (status) => set({ envStatus: status }),
  setEnvChecking: (checking) => set({ envChecking: checking }),
  setBackend: (backend) => set({ backend }),
  setSetupStatus: (status) => set({ setupStatus: status }),
  appendSetupLog: (line) => set((s) => ({ setupLogs: [...s.setupLogs, line] })),
  clearSetupLogs: () => set({ setupLogs: [], setupError: "" }),
  setSetupStep: (step, total, message) => set({ setupStep: { step, total, message } }),
  setSetupError: (error) => set({ setupError: error }),
}));
