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
    pub ensembl_id: String,
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
    pub cache_key: String,
    pub file_path: String,
    pub gene_count: usize,
    pub provenance: serde_json::Value,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CachedEvidence {
    pub cache_key: String,
    pub provenance: serde_json::Value,
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
    id: String,
    approved_symbol: String,
}

// --- Internal deserialization types for search_diseases ---

#[derive(Debug, Deserialize)]
struct SearchResponse {
    data: Option<SearchData>,
    errors: Option<Vec<GqlError>>,
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
    #[serde(default)]
    csv_sha256: Option<String>,
    #[serde(default)]
    source: String,
    #[serde(default)]
    api_url: String,
    #[serde(default)]
    release: Option<String>,
    #[serde(default)]
    query_variables: serde_json::Value,
    disease_name: String,
    efo_id: String,
    gene_count: usize,
    fetched_at: String,
}

// --- Helpers ---

fn cache_dir() -> Result<PathBuf, String> {
    // Installed resources are read-only. Evidence belongs to the user's data.
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map_err(|_| "Cannot determine user data directory")?;
    let dir = PathBuf::from(home).join(".biomarkerpred").join(CACHE_DIR);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}
fn safe_id(id: &str) -> Result<String, String> {
    if id.is_empty()
        || !id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_:-".contains(&c))
    {
        return Err("Disease ID must be an ontology identifier containing letters, digits, underscores, colons or hyphens".into());
    }
    Ok(id.replace(':', "_"))
}
fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())
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
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02} UTC",
        y, mo, day, h, m, s
    )
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

    let client = client()?;

    let gql = "query SearchDiseases($query: String!, $size: Int!) { search(queryString: $query, entityNames: [\"disease\"], page: {index: 0, size: $size}) { hits { id name description entity } } }";

    let response = client
        .post(OPEN_TARGETS_API)
        .json(&serde_json::json!({ "query": gql, "variables": {"query": query, "size": SEARCH_SIZE} }))
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

    if let Some(error) = body.errors.and_then(|errors| errors.into_iter().next()) {
        return Err(format!("Open Targets API error: {}", error.message));
    }
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
    let client = client()?;
    safe_id(&efo_id)?;
    let mut all_genes: Vec<Gene> = Vec::new();
    let mut page_index: usize = 0;
    let mut expected_count = None;
    let mut identifiers = std::collections::HashSet::new();

    loop {
        let gql = "query DiseaseTargets($id: String!, $index: Int!, $size: Int!) { disease(efoId: $id) { associatedTargets(page: { index: $index, size: $size }) { count rows { target { id approvedSymbol } score } } } }";

        let response = client
            .post(OPEN_TARGETS_API)
            .json(&serde_json::json!({ "query": gql, "variables": {"id": efo_id, "index": page_index, "size": PAGE_SIZE} }))
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

        let complete = append_page(
            &mut all_genes,
            &mut identifiers,
            &mut expected_count,
            disease_data.associated_targets,
        )?;
        page_index += 1;
        if complete {
            break;
        }
    }
    publish_snapshot(
        &cache_dir()?,
        all_genes,
        efo_id,
        disease_name,
        page_index,
        expected_count,
    )
}
fn append_page(
    all_genes: &mut Vec<Gene>,
    identifiers: &mut std::collections::HashSet<String>,
    expected_count: &mut Option<usize>,
    targets: AssociatedTargets,
) -> Result<bool, String> {
    let page_count = targets.rows.len();
    if let Some(expected) = *expected_count {
        if expected != targets.count {
            return Err(
                "Open Targets count changed during pagination; retry for a consistent snapshot"
                    .into(),
            );
        }
    } else {
        *expected_count = Some(targets.count);
    }
    if page_count > PAGE_SIZE || targets.count > 1_000_000 {
        return Err("Invalid Open Targets pagination response".into());
    }
    for row in targets.rows {
        if !row.score.is_finite()
            || !(0.0..=1.0).contains(&row.score)
            || row.target.id.trim().is_empty()
            || row.target.approved_symbol.trim().is_empty()
        {
            return Err("Open Targets returned a missing target identifier/symbol or invalid association score".into());
        }
        if !identifiers.insert(row.target.id.clone()) {
            return Err(
                "Open Targets repeated a target across pages; retry for a consistent snapshot"
                    .into(),
            );
        }
        all_genes.push(Gene {
            symbol: row.target.approved_symbol,
            ensembl_id: row.target.id,
            score: row.score,
        });
    }
    if all_genes.len() > targets.count {
        return Err("Open Targets returned more targets than its recorded count".into());
    }
    if all_genes.len() == targets.count {
        return Ok(true);
    }
    if page_count < PAGE_SIZE {
        return Err("Open Targets pagination ended before its recorded total; no partial evidence was cached".into());
    }
    Ok(false)
}
fn publish_snapshot(
    dir: &std::path::Path,
    all_genes: Vec<Gene>,
    efo_id: String,
    disease_name: String,
    page_index: usize,
    expected_count: Option<usize>,
) -> Result<FetchGenesResult, String> {
    // Publish an immutable CSV+metadata pair by renaming a unique directory.
    // Existing snapshots may be in use by running analyses and are never rewritten.
    let pending = tempfile::Builder::new()
        .prefix(".pending-")
        .tempdir_in(dir)
        .map_err(|e| e.to_string())?;
    let csv_path = pending.path().join("genes.csv");
    let mut wtr = csv::Writer::from_path(&csv_path).map_err(|e| e.to_string())?;
    wtr.write_record(["gene_symbol", "score", "ensembl_id"])
        .map_err(|e| e.to_string())?;
    for gene in &all_genes {
        wtr.serialize((&gene.symbol, gene.score, &gene.ensembl_id))
            .map_err(|e| e.to_string())?;
    }
    wtr.flush().map_err(|e| e.to_string())?;
    drop(wtr);
    let meta = CacheMeta {
        csv_sha256: Some(super::artifacts::sha256(&csv_path)?),
        source: "Open Targets Platform".into(),
        api_url: OPEN_TARGETS_API.into(),
        release: None,
        query_variables: serde_json::json!({"disease_id":efo_id,"page_size":PAGE_SIZE,"pages":page_index,"expected_count":expected_count}),
        disease_name,
        efo_id: efo_id.clone(),
        gene_count: all_genes.len(),
        fetched_at: now_iso(),
    };
    let provenance = serde_json::to_value(&meta).map_err(|e| e.to_string())?;
    super::artifacts::atomic_json(&pending.path().join("metadata.json"), &provenance)?;
    let cache_key = format!(
        "{}-{}",
        safe_id(&efo_id)?,
        pending
            .path()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .trim_start_matches(".pending-")
    );
    let destination = dir.join(&cache_key);
    std::fs::rename(pending.path(), &destination).map_err(|e| e.to_string())?;
    Ok(FetchGenesResult {
        cache_key,
        file_path: destination.join("genes.csv").to_string_lossy().into_owned(),
        gene_count: all_genes.len(),
        provenance,
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

    for entry in std::fs::read_dir(&dir)
        .map_err(|e| e.to_string())?
        .flatten()
    {
        let path = entry.path();
        let filename = entry.file_name().to_string_lossy().into_owned();
        let (meta_path, csv_path, cache_key) = if path.is_dir() && !filename.starts_with('.') {
            (path.join("metadata.json"), path.join("genes.csv"), filename)
        } else if filename.ends_with(".meta.json") {
            let stem = filename.trim_end_matches(".meta.json");
            (
                path.clone(),
                dir.join(format!("{stem}.csv")),
                format!("legacy-{stem}"),
            )
        } else {
            continue;
        };
        if let Ok(content) = std::fs::read_to_string(&meta_path) {
            if let Ok(meta) = serde_json::from_str::<CacheMeta>(&content) {
                if csv_path.is_file() {
                    cached.push(CachedEvidence {
                        cache_key,
                        provenance: serde_json::to_value(&meta).map_err(|e| e.to_string())?,
                        efo_id: meta.efo_id,
                        disease_name: meta.disease_name,
                        gene_count: meta.gene_count,
                        fetched_at: meta.fetched_at,
                        file_path: csv_path.to_string_lossy().into_owned(),
                    });
                }
            }
        }
    }

    cached.sort_by(|a, b| a.disease_name.cmp(&b.disease_name));
    Ok(cached)
}

/// Delete a cached evidence file (CSV + metadata).
#[tauri::command]
pub async fn opentargets_delete_cached(cache_key: String) -> Result<(), String> {
    let dir = cache_dir()?;
    let key = safe_id(&cache_key)?;
    if let Some(stem) = key.strip_prefix("legacy-") {
        for suffix in ["csv", "meta.json"] {
            let path = dir.join(format!("{stem}.{suffix}"));
            if path.exists() {
                std::fs::remove_file(path).map_err(|e| e.to_string())?;
            }
        }
    } else {
        let path = dir.join(key);
        if !path.join("metadata.json").is_file() {
            return Err("Unknown evidence snapshot".into());
        }
        std::fs::remove_dir_all(path).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Count genes in a cached CSV that pass the given score threshold.
#[tauri::command]
pub async fn opentargets_count_filtered(
    file_path: String,
    score_threshold: f64,
) -> Result<FilteredCount, String> {
    let mut rdr =
        csv::Reader::from_path(&file_path).map_err(|e| format!("Cannot read CSV: {}", e))?;

    let score_index = rdr
        .headers()
        .map_err(|e| e.to_string())?
        .iter()
        .position(|h| h == "score")
        .ok_or("Evidence CSV has no score column")?;
    let mut total = 0usize;
    let mut passed = 0usize;

    for result in rdr.records() {
        let record = result.map_err(|e| format!("CSV parse error: {}", e))?;
        total += 1;
        if let Some(score_str) = record.get(score_index) {
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

#[cfg(test)]
mod tests {
    use super::*;
    fn page(count: usize, rows: serde_json::Value) -> AssociatedTargets {
        serde_json::from_value(serde_json::json!({"count":count,"rows":rows})).unwrap()
    }
    #[test]
    fn rejects_partial_duplicate_invalid_target_evidence() {
        let valid = serde_json::json!({"target":{"id":"ENSG1","approvedSymbol":"A"},"score":0.7});
        let mut genes = vec![];
        let mut ids = std::collections::HashSet::new();
        let mut expected = None;
        assert!(append_page(
            &mut genes,
            &mut ids,
            &mut expected,
            page(2, serde_json::json!([valid.clone()]))
        )
        .unwrap_err()
        .contains("pagination ended"));
        let mut genes = vec![];
        let mut ids = std::collections::HashSet::new();
        let mut expected = None;
        assert!(append_page(
            &mut genes,
            &mut ids,
            &mut expected,
            page(2, serde_json::json!([valid.clone(), valid.clone()]))
        )
        .unwrap_err()
        .contains("repeated"));
        let mut bad = valid.clone();
        bad["score"] = serde_json::json!(1.2);
        let mut genes = vec![];
        let mut ids = std::collections::HashSet::new();
        let mut expected = None;
        assert!(append_page(
            &mut genes,
            &mut ids,
            &mut expected,
            page(1, serde_json::json!([bad]))
        )
        .is_err());
        let mut genes = vec![];
        let mut ids = std::collections::HashSet::new();
        let mut expected = Some(2);
        assert!(append_page(
            &mut genes,
            &mut ids,
            &mut expected,
            page(1, serde_json::json!([valid]))
        )
        .unwrap_err()
        .contains("count changed"));
    }
    #[test]
    fn repeated_disease_fetches_publish_distinct_immutable_snapshots() {
        let dir = tempfile::tempdir().unwrap();
        let gene = || {
            vec![Gene {
                symbol: "A,quoted".into(),
                ensembl_id: "ENSG1".into(),
                score: 0.7,
            }]
        };
        let first = publish_snapshot(
            dir.path(),
            gene(),
            "MONDO_0004989".into(),
            "Disease".into(),
            1,
            Some(1),
        )
        .unwrap();
        let hash = super::super::artifacts::sha256(std::path::Path::new(&first.file_path)).unwrap();
        let second = publish_snapshot(
            dir.path(),
            gene(),
            "MONDO_0004989".into(),
            "Disease".into(),
            1,
            Some(1),
        )
        .unwrap();
        assert_ne!(first.cache_key, second.cache_key);
        assert_ne!(first.file_path, second.file_path);
        assert_eq!(
            hash,
            super::super::artifacts::sha256(std::path::Path::new(&first.file_path)).unwrap()
        );
        assert_eq!(first.provenance["release"], serde_json::Value::Null);
        assert_eq!(first.provenance["csv_sha256"], hash);
        let table =
            super::super::fs_ops::read_csv(std::path::Path::new(&first.file_path), None).unwrap();
        assert_eq!(table["rows"][0]["ensembl_id"], "ENSG1");
        assert_eq!(table["rows"][0]["gene_symbol"], "A,quoted");
    }
}
