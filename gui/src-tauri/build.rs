use std::{fs, path::Path};
fn copy_file(source: &Path, dest: &Path) {
    println!("cargo:rerun-if-changed={}", source.display());
    fs::create_dir_all(dest.parent().unwrap()).unwrap();
    fs::copy(source, dest).unwrap();
}
fn main() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let staged = Path::new(env!("CARGO_MANIFEST_DIR")).join("resources/engine");
    println!("cargo:rerun-if-changed={}", root.display());
    if staged.exists() {
        fs::remove_dir_all(&staged).unwrap();
    }
    // Provenance hashes every root R script and every R/*.R module. Bundle that
    // exact set, including compatibility scripts, rather than selected entrypoints.
    for sub in ["", "R"] {
        for entry in fs::read_dir(root.join(sub)).unwrap().flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "R") {
                copy_file(&path, &staged.join(sub).join(path.file_name().unwrap()));
            }
        }
    }
    copy_file(
        &root.join("config/schema.json"),
        &staged.join("config/schema.json"),
    );
    tauri_build::build()
}
