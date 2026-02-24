import { invoke } from "@tauri-apps/api/core";
import type { DataFileInfo, RuntimeInfo, TcgaPreset, AnalysisConfig, OTDisease, FetchGenesResult, CachedEvidence, FilteredCount, EnvStatus } from "@/types/analysis";

export interface DepCheckResult {
  package: string;
  installed: boolean;
}

// Runtime
export async function detectRuntime(): Promise<RuntimeInfo> {
  return invoke<RuntimeInfo>("runtime_detect");
}

export async function checkRuntimeDeps(): Promise<DepCheckResult[]> {
  return invoke<DepCheckResult[]>("runtime_check_deps");
}

// File system
export async function pickFile(): Promise<string | null> {
  return invoke<string | null>("fs_pick_file");
}

export async function pickDirectory(): Promise<string | null> {
  return invoke<string | null>("fs_pick_directory");
}

export async function readCsvHeader(path: string): Promise<DataFileInfo> {
  return invoke<DataFileInfo>("fs_read_csv_header", { path });
}

export async function readImageBase64(path: string): Promise<string> {
  return invoke<string>("fs_read_image", { path });
}

export async function readTextFile(path: string): Promise<string> {
  return invoke<string>("fs_read_text_file", { path });
}

export async function listOutputPlots(outputDir: string): Promise<string[]> {
  return invoke<string[]>("fs_list_output_plots", { outputDir });
}

export async function saveFile(
  sourcePath: string,
  defaultName: string,
): Promise<string | null> {
  return invoke<string | null>("fs_save_file", { sourcePath, defaultName });
}

export async function openDirectory(path: string): Promise<void> {
  return invoke("fs_open_directory", { path });
}

// Config
export async function loadYaml(path: string): Promise<unknown> {
  return invoke("config_load_yaml", { path });
}

export async function saveYaml(config: unknown, path: string): Promise<string> {
  return invoke<string>("config_save_yaml", { config, path });
}

export async function listPresets(): Promise<TcgaPreset[]> {
  return invoke<TcgaPreset[]>("config_list_presets");
}

export async function loadPreset(presetId: string): Promise<unknown> {
  return invoke("config_load_preset", { presetId });
}

export async function validateConfig(config: unknown): Promise<string[]> {
  return invoke<string[]>("config_validate", { config });
}

// Analysis
export async function runAnalysis(config: Partial<AnalysisConfig>): Promise<void> {
  return invoke("analysis_run", { config });
}

export async function cancelAnalysis(): Promise<void> {
  return invoke("analysis_cancel");
}

// Open Targets
export async function searchDiseases(query: string): Promise<OTDisease[]> {
  return invoke<OTDisease[]>("opentargets_search_diseases", { query });
}

export async function fetchOpenTargetsGenes(
  efoId: string,
  diseaseName: string
): Promise<FetchGenesResult> {
  return invoke<FetchGenesResult>("opentargets_fetch_genes", {
    efoId,
    diseaseName,
  });
}

export async function listCachedEvidence(): Promise<CachedEvidence[]> {
  return invoke<CachedEvidence[]>("opentargets_list_cached");
}

export async function deleteCachedEvidence(efoId: string): Promise<void> {
  return invoke("opentargets_delete_cached", { efoId });
}

export async function countFilteredGenes(
  filePath: string,
  scoreThreshold: number
): Promise<FilteredCount> {
  return invoke<FilteredCount>("opentargets_count_filtered", {
    filePath,
    scoreThreshold,
  });
}

// Setup / Environment
export async function checkEnv(): Promise<EnvStatus> {
  return invoke<EnvStatus>("setup_check_env");
}

export async function installEnv(): Promise<void> {
  return invoke("setup_install_env");
}

export async function cancelSetup(): Promise<void> {
  return invoke("setup_cancel");
}

export async function pullDockerImage(): Promise<void> {
  return invoke("setup_pull_docker");
}

export interface ImageUpdateStatus {
  hasUpdate: boolean;
  error?: string;
}

export async function checkImageUpdate(): Promise<ImageUpdateStatus> {
  return invoke<ImageUpdateStatus>("setup_check_image_update");
}
