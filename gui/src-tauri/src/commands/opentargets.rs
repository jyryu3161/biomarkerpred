use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const OPEN_TARGETS_API: &str = "https://api.platform.opentargets.org/api/v4/graphql";
const PAGE_SIZE: usize = 3000;
const SEARCH_SIZE: usize = 20;
const CACHE_DIR: &str = "evidence/opentargets";

// --- Public types ---

#[derive(Debug, Serialize, Deserialize)]
pub struct Gene {
    pub symbol: String,
    pub score: f64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Disease {
    pub efo_id: String,
    pub name: String,
    pub description: String,
}

#[derive(Debug, Serialize)]
pub struct FetchGenesResult {
    pub file_path: String,
    pub gene_count: usize,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CachedEvidence {
    pub efo_id: String,
    pub disease_name: String,
    pub gene_count: usize,
    pub fetched_at: String,
    pub file_path: String,
}

// --- Internal deserialization types for fetch_genes ---

#[derive(Debug, Deserialize)]
struct GqlError {
    message: String,
}

#[derive(Debug, Deserialize)]
struct FetchGenesResponse {
    data: Option<FetchGenesData>,
    errors: Option<Vec<GqlError>>,
}

#[derive(Debug, Deserialize)]
struct FetchGenesData {
    disease: Option<DiseaseTargets>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DiseaseTargets {
    associated_targets: AssociatedTargets,
}

#[derive(Debug, Deserialize)]
struct AssociatedTargets {
    count: usize,
    rows: Vec<TargetRow>,
}

#[derive(Debug, Deserialize)]
struct TargetRow {
    target: TargetInfo,
    score: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TargetInfo {
    approved_symbol: String,
}

// --- Internal deserialization types for search_diseases ---

#[derive(Debug, Deserialize)]
struct SearchResponse {
    data: Option<SearchData>,
}

#[derive(Debug, Deserialize)]
struct SearchData {
    search: Option<SearchResult>,
}

#[derive(Debug, Deserialize)]
struct SearchResult {
    hits: Vec<SearchHit>,
}

#[derive(Debug, Deserialize)]
struct SearchHit {
    id: String,
    name: String,
    description: Option<String>,
    entity: String,
}

// --- Metadata stored alongside cached CSV ---

#[derive(Debug, Serialize, Deserialize)]
struct CacheMeta {
    disease_name: String,
    efo_id: String,
    gene_count: usize,
    fetched_at: String,
}

// --- Helpers ---

fn find_project_root() -> Option<PathBuf> {
    let candidates = [
        std::env::current_dir().ok(),
        std::env::current_dir()
            .ok()
            .and_then(|p| p.join("../../").canonicalize().ok()),
        std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|p| p.to_path_buf())),
        std::env::current_exe().ok().and_then(|p| {
            p.parent()
                .and_then(|p| p.parent())
                .and_then(|p| p.parent())
                .map(|p| p.to_path_buf())
        }),
    ];

    for candidate in candidates.into_iter().flatten() {
        if candidate.join("Main_Binary.R").exists() {
            return Some(candidate);
        }
    }
    None
}

fn cache_dir() -> Result<PathBuf, String> {
    // Try project root first (development mode)
    if let Some(root) = find_project_root() {
        let dir = root.join(CACHE_DIR);
        if !dir.exists() {
            std::fs::create_dir_all(&dir)
                .map_err(|e| format!("Cannot create cache directory: {}", e))?;
        }
        return Ok(dir);
    }
    // Fallback: user data directory (installed app on Windows/macOS/Linux)
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map_err(|_| "Cannot determine home directory".to_string())?;
    let dir = PathBuf::from(home).join(".biomarkerpred").join(CACHE_DIR);
    if !dir.exists() {
        std::fs::create_dir_all(&dir)
            .map_err(|e| format!("Cannot create cache directory: {}", e))?;
    }
    Ok(dir)
}

fn now_iso() -> String {
    let d = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap();
    let secs = d.as_secs();
    // Simple ISO-ish date: YYYY-MM-DD HH:MM:SS UTC
    let days = secs / 86400;
    let time_of_day = secs % 86400;
    let h = time_of_day / 3600;
    let m = (time_of_day % 3600) / 60;
    let s = time_of_day % 60;
    // Approximate date from epoch days (good enough for display)
    let (y, mo, day) = epoch_days_to_date(days);
    format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02} UTC", y, mo, day, h, m, s)
}

fn epoch_days_to_date(days: u64) -> (u64, u64, u64) {
    // Civil date from days since 1970-01-01 (Howard Hinnant algorithm)
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

// --- Commands ---

/// Search diseases on Open Targets Platform by keyword.
#[tauri::command]
pub async fn opentargets_search_diseases(query: String) -> Result<Vec<Disease>, String> {
    if query.trim().len() < 2 {
        return Ok(Vec::new());
    }

    let client = reqwest::Client::new();

    let gql = format!(
        r#"{{
  search(queryString: "{}", entityNames: ["disease"], page: {{ index: 0, size: {} }}) {{
    hits {{
      id
      name
      description
      entity
    }}
  }}
}}"#,
        query.replace('"', "\\\""),
        SEARCH_SIZE
    );

    let response = client
        .post(OPEN_TARGETS_API)
        .json(&serde_json::json!({ "query": gql }))
        .send()
        .await
        .map_err(|e| format!("HTTP request failed: {}", e))?;

    if !response.status().is_success() {
        return Err(format!(
            "Open Targets API returned status {}",
            response.status()
        ));
    }

    let body: SearchResponse = response
        .json()
        .await
        .map_err(|e| format!("Failed to parse search response: {}", e))?;

    let hits = body
        .data
        .and_then(|d| d.search)
        .map(|s| s.hits)
        .unwrap_or_default();

    let diseases: Vec<Disease> = hits
        .into_iter()
        .filter(|h| h.entity == "disease")
        .map(|h| Disease {
            efo_id: h.id,
            name: h.name,
            description: h.description.unwrap_or_default(),
        })
        .collect();

    Ok(diseases)
}

/// Fetch ALL disease-associated genes from Open Targets and cache to evidence/opentargets/.
/// Saves all genes without threshold filtering (R handles threshold at runtime).
#[tauri::command]
pub async fn opentargets_fetch_genes(
    efo_id: String,
    disease_name: String,
) -> Result<FetchGenesResult, String> {
    let client = reqwest::Client::new();
    let mut all_genes: Vec<Gene> = Vec::new();
    let mut page_index: usize = 0;

    loop {
        let gql = format!(
            r#"{{
  disease(efoId: "{}") {{
    associatedTargets(page: {{ index: {}, size: {} }}) {{
      count
      rows {{
        target {{
          approvedSymbol
        }}
        score
      }}
    }}
  }}
}}"#,
            efo_id, page_index, PAGE_SIZE
        );

        let response = client
            .post(OPEN_TARGETS_API)
            .json(&serde_json::json!({ "query": gql }))
            .send()
            .await
            .map_err(|e| format!("HTTP request failed: {}", e))?;

        if !response.status().is_success() {
            return Err(format!(
                "Open Targets API returned status {}",
                response.status()
            ));
        }

        let body: FetchGenesResponse = response
            .json()
            .await
            .map_err(|e| format!("Failed to parse API response: {}", e))?;

        // Check for GraphQL errors first
        if let Some(errors) = &body.errors {
            if let Some(err) = errors.first() {
                return Err(format!("Open Targets API error: {}", err.message));
            }
        }

        let disease_data = body
            .data
            .and_then(|d| d.disease)
            .ok_or_else(|| format!("No data found for disease ID: {}", efo_id))?;

        let targets = disease_data.associated_targets;
        let page_count = targets.rows.len();

        for row in targets.rows {
            all_genes.push(Gene {
                symbol: row.target.approved_symbol,
                score: row.score,
            });
        }

        page_index += 1;

        if page_count < PAGE_SIZE || all_genes.len() >= targets.count {
            break;
        }
    }

    // Save to cache directory
    let dir = cache_dir()?;
    let safe_id = efo_id.replace(':', "_");
    let csv_path = dir.join(format!("{}.csv", safe_id));
    let meta_path = dir.join(format!("{}.meta.json", safe_id));

    // Write CSV
    let mut wtr = csv::Writer::from_path(&csv_path)
        .map_err(|e| format!("Cannot create CSV: {}", e))?;

    wtr.write_record(["gene_symbol", "score"])
        .map_err(|e| format!("CSV write error: {}", e))?;

    for gene in &all_genes {
        wtr.serialize((&gene.symbol, gene.score))
            .map_err(|e| format!("CSV write error: {}", e))?;
    }
    wtr.flush().map_err(|e| format!("CSV flush error: {}", e))?;

    // Write metadata
    let meta = CacheMeta {
        disease_name: disease_name.clone(),
        efo_id: efo_id.clone(),
        gene_count: all_genes.len(),
        fetched_at: now_iso(),
    };
    let meta_json = serde_json::to_string_pretty(&meta)
        .map_err(|e| format!("JSON serialize error: {}", e))?;
    std::fs::write(&meta_path, meta_json)
        .map_err(|e| format!("Cannot write metadata: {}", e))?;

    Ok(FetchGenesResult {
        file_path: csv_path.to_string_lossy().to_string(),
        gene_count: all_genes.len(),
    })
}

/// List cached evidence files in evidence/opentargets/.
#[tauri::command]
pub async fn opentargets_list_cached() -> Result<Vec<CachedEvidence>, String> {
    let dir = match cache_dir() {
        Ok(d) => d,
        Err(_) => return Ok(Vec::new()), // No cache dir yet = empty list
    };

    let mut cached: Vec<CachedEvidence> = Vec::new();

    let entries = std::fs::read_dir(&dir)
        .map_err(|e| format!("Cannot read cache directory: {}", e))?;

    for entry in entries.flatten() {
        let path = entry.path();
        if path.to_string_lossy().ends_with(".meta.json")
        {
            if let Ok(content) = std::fs::read_to_string(&path) {
                if let Ok(meta) = serde_json::from_str::<CacheMeta>(&content) {
                    let safe_id = meta.efo_id.replace(':', "_");
                    let csv_path = dir.join(format!("{}.csv", safe_id));
                    if csv_path.exists() {
                        cached.push(CachedEvidence {
                            efo_id: meta.efo_id,
                            disease_name: meta.disease_name,
                            gene_count: meta.gene_count,
                            fetched_at: meta.fetched_at,
                            file_path: csv_path.to_string_lossy().to_string(),
                        });
                    }
                }
            }
        }
    }

    cached.sort_by(|a, b| a.disease_name.cmp(&b.disease_name));
    Ok(cached)
}

/// Delete a cached evidence file (CSV + metadata).
#[tauri::command]
pub async fn opentargets_delete_cached(efo_id: String) -> Result<(), String> {
    let dir = cache_dir()?;
    let safe_id = efo_id.replace(':', "_");
    let csv_path = dir.join(format!("{}.csv", safe_id));
    let meta_path = dir.join(format!("{}.meta.json", safe_id));

    if csv_path.exists() {
        std::fs::remove_file(&csv_path)
            .map_err(|e| format!("Cannot delete CSV: {}", e))?;
    }
    if meta_path.exists() {
        std::fs::remove_file(&meta_path)
            .map_err(|e| format!("Cannot delete metadata: {}", e))?;
    }

    Ok(())
}

/// Count genes in a cached CSV that pass the given score threshold.
#[tauri::command]
pub async fn opentargets_count_filtered(
    file_path: String,
    score_threshold: f64,
) -> Result<FilteredCount, String> {
    let mut rdr = csv::Reader::from_path(&file_path)
        .map_err(|e| format!("Cannot read CSV: {}", e))?;

    let mut total = 0usize;
    let mut passed = 0usize;

    for result in rdr.records() {
        let record = result.map_err(|e| format!("CSV parse error: {}", e))?;
        total += 1;
        if let Some(score_str) = record.get(1) {
            if let Ok(score) = score_str.parse::<f64>() {
                if score >= score_threshold {
                    passed += 1;
                }
            }
        }
    }

    Ok(FilteredCount { total, passed })
}

#[derive(Debug, Serialize)]
pub struct FilteredCount {
    pub total: usize,
    pub passed: usize,
}
