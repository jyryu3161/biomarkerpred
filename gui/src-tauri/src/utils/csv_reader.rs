use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};

/// Read CSV headers and a few preview rows
pub fn read_csv_info(path: &str) -> Result<(Vec<String>, usize, HashMap<String, Vec<String>>), String> {
    let file = fs::File::open(path)
        .map_err(|e| format!("Cannot open: {}", e))?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();

    let header = lines
        .next()
        .ok_or("Empty file")?
        .map_err(|e| e.to_string())?;

    let columns: Vec<String> = header
        .split(',')
        .map(|s| s.trim().trim_matches('"').to_string())
        .collect();

    let mut preview: HashMap<String, Vec<String>> = HashMap::new();
    for col in &columns {
        preview.insert(col.clone(), Vec::new());
    }

    let mut row_count = 0;
    for line_result in lines {
        let line = line_result.map_err(|e| e.to_string())?;
        row_count += 1;
        if row_count <= 5 {
            let values: Vec<&str> = line.split(',').collect();
            for (i, col) in columns.iter().enumerate() {
                if let Some(val) = values.get(i) {
                    if let Some(pv) = preview.get_mut(col) {
                        pv.push(val.trim().trim_matches('"').to_string());
                    }
                }
            }
        }
    }

    Ok((columns, row_count, preview))
}
