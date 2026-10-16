import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type {
  AnalysisConfig,
  CsvTable,
  DataInfo,
  Disease,
  EngineEvent,
  EngineRequest,
  EngineResponse,
  EvidenceSnapshot,
  JobSnapshot,
  JsonObject,
  LoadedModel,
  RunRecord,
  RuntimeSettings,
} from "./types";
export const api = {
  schema: () => invoke<JsonObject>("engine_schema"),
  settings: () => invoke<RuntimeSettings>("engine_get_settings"),
  saveSettings: (settings: RuntimeSettings) =>
    invoke<RuntimeSettings>("engine_save_settings", { settings }),
  call: (request: EngineRequest) =>
    invoke<EngineResponse>("engine_call", { request }),
  start: (request: EngineRequest, jobId: string) =>
    invoke("engine_start", { request, jobId }),
  status: (jobId: string | null = null) =>
    invoke<JobSnapshot | null>("engine_job_status", { jobId }),
  cancel: (jobId: string) => invoke<JobSnapshot>("engine_cancel", { jobId }),
  listen: (callback: (event: EngineEvent) => void) =>
    listen<EngineEvent>("engine://event", (event) => callback(event.payload)),
  run: (runDir: string) => invoke<RunRecord>("engine_read_run", { runDir }),
  model: (path: string) => invoke<LoadedModel>("model_load", { path }),
  header: (path: string) => invoke<DataInfo>("fs_read_csv_header", { path }),
  csv: (path: string, limit: number | null = null) =>
    invoke<CsvTable>("fs_read_csv", { path, limit }),
  readText: (path: string) => invoke<string>("fs_read_text_file", { path }),
  image: (path: string) => invoke<string>("fs_read_image", { path }),
  pickFile: () => invoke<string | null>("fs_pick_file"),
  pickDirectory: () => invoke<string | null>("fs_pick_directory"),
  open: (path: string) => invoke<void>("fs_open_directory", { path }),
  save: (sourcePath: string, defaultName: string) =>
    invoke<string | null>("fs_save_file", { sourcePath, defaultName }),
  saveConfig: (config: AnalysisConfig, path: string) =>
    invoke<string>("config_save_yaml", { config, path }),
  pull: (settings: RuntimeSettings) =>
    invoke<string>("runtime_pull_image", { settings }),
  searchDisease: (query: string) =>
    invoke<Disease[]>("opentargets_search_diseases", { query }),
  fetchEvidence: (efoId: string, diseaseName: string) =>
    invoke<EvidenceSnapshot>("opentargets_fetch_genes", { efoId, diseaseName }),
  cachedEvidence: () => invoke<EvidenceSnapshot[]>("opentargets_list_cached"),
  deleteEvidence: (cacheKey: string) =>
    invoke<void>("opentargets_delete_cached", { cacheKey }),
};
