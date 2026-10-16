use super::{
    artifacts::{atomic_json, read_json},
    engine_process::{run_process, DockerProcess, Job},
    engine_types::{scalar, Backend, EngineRequest, Operation, RuntimeSettings},
    runtime::r_executable,
};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::Arc,
    time::Duration,
};
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct Mount {
    pub host: String,
    pub container: String,
    pub writable: bool,
}
#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct PathMap {
    pub mounts: Vec<Mount>,
}
impl PathMap {
    pub fn container_path(host: &str) -> String {
        let mut normal = host.replace('\\', "/");
        if let Some(unc) = normal.strip_prefix("//?/UNC/") {
            normal = format!("//{unc}");
        } else if let Some(drive) = normal.strip_prefix("//?/") {
            normal = drive.to_owned();
        }
        if normal.as_bytes().get(1) == Some(&b':') {
            format!(
                "/bmp-host/{}/{}",
                normal[..1].to_uppercase(),
                normal[2..].trim_start_matches('/')
            )
        } else if normal.starts_with("//") {
            format!("/bmp-host/UNC/{}", normal.trim_start_matches('/'))
        } else {
            normal
        }
    }
    pub fn add(&mut self, path: &Path, writable: bool) -> Result<String, String> {
        let host = path
            .canonicalize()
            .map_err(|e| format!("Cannot mount {}: {e}", path.display()))?
            .to_string_lossy()
            .into_owned();
        let host = if let Some(unc) = host.strip_prefix(r"\\?\UNC\") {
            format!(r"\\{unc}")
        } else {
            host.strip_prefix(r"\\?\").unwrap_or(&host).to_owned()
        };
        let container = Self::container_path(&host);
        if let Some(m) = self.mounts.iter_mut().find(|m| m.host == host) {
            m.writable |= writable;
        } else {
            self.mounts.push(Mount {
                host,
                container: container.clone(),
                writable,
            });
        }
        Ok(container)
    }
    pub fn to_host(&self, path: &str) -> String {
        let mut maps = self.mounts.iter().collect::<Vec<_>>();
        maps.sort_by_key(|m| std::cmp::Reverse(m.container.len()));
        for m in maps {
            if path == m.container {
                return m.host.clone();
            }
            if let Some(rest) = path.strip_prefix(&(m.container.clone() + "/")) {
                return Path::new(&m.host).join(rest).to_string_lossy().into_owned();
            }
        }
        path.into()
    }
    pub fn map_result(&self, v: &mut Value) {
        match v {
            Value::String(s) => *s = self.to_host(s),
            Value::Array(a) => {
                for x in a {
                    self.map_result(x)
                }
            }
            Value::Object(o) => {
                for x in o.values_mut() {
                    self.map_result(x)
                }
            }
            _ => {}
        }
    }
    pub fn args(&self) -> Vec<String> {
        let mut mounts = self.mounts.clone();
        mounts.sort_by_key(|m| m.container.len());
        mounts
            .into_iter()
            .flat_map(|m| {
                // Docker --mount uses CSV fields. Quoting the entire key=value field
                // preserves commas and double quotes without shell interpretation.
                let q = |s: String| {
                    if s.contains(',') || s.contains('"') {
                        format!("\"{}\"", s.replace('"', "\"\""))
                    } else {
                        s
                    }
                };
                let mut spec = format!(
                    "type=bind,{},{}",
                    q(format!("source={}", m.host)),
                    q(format!("target={}", m.container))
                );
                if !m.writable {
                    spec.push_str(",readonly");
                }
                vec!["--mount".into(), spec]
            })
            .collect()
    }
}
pub struct Plan {
    pub command: Command,
    pub create_command: Option<Command>,
    pub map: PathMap,
    pub docker: Option<DockerProcess>,
    pub image_id: Option<String>,
    pub _temp: tempfile::TempDir,
}
fn absolute(path: &str, base: &Path) -> PathBuf {
    let p = Path::new(path);
    if p.is_absolute() {
        p.into()
    } else {
        base.join(p)
    }
}
pub(crate) fn ambiguous_yaml(text: &str) -> bool {
    // Inspect plain tokens only; quoted YAML strings retain their exact meaning.
    // This includes flow arrays and block list entries, not only key: scalar lines.
    let mut plain = String::new();
    let mut quote = None;
    let mut escaped = false;
    let mut comment = false;
    for c in text.chars() {
        if comment {
            if c == '\n' {
                comment = false;
                plain.push('\n');
            }
            continue;
        }
        if let Some(q) = quote {
            if q == '"' && c == '\\' && !escaped {
                escaped = true;
                continue;
            }
            if c == q && !escaped {
                quote = None;
            }
            escaped = false;
            continue;
        }
        match c {
            '"' | '\'' => {
                quote = Some(c);
                plain.push(' ');
            }
            '#' => {
                comment = true;
                plain.push(' ');
            }
            _ => plain.push(c),
        }
    }
    plain
        .split(|c: char| c.is_whitespace() || ":,[]{}".contains(c))
        .any(|token| {
            ["yes", "no", "on", "off", "y", "n"].contains(&token.to_ascii_lowercase().as_str())
        })
}
fn resolve_existing_parent(path: &Path) -> Result<PathBuf, String> {
    if path.exists() {
        return path.canonicalize().map_err(|e| e.to_string());
    }
    let parent = path.parent().ok_or("Path has no parent")?;
    let parent = resolve_existing_parent(parent)?;
    Ok(parent.join(path.file_name().ok_or("Path has no file name")?))
}
fn map_path(
    value: &str,
    base: &Path,
    output: bool,
    directory: bool,
    map: &mut PathMap,
) -> Result<String, String> {
    let path = resolve_existing_parent(&absolute(value, base))?;
    let mount = if directory {
        path.clone()
    } else {
        path.parent().ok_or("Path has no parent")?.into()
    };
    if output {
        std::fs::create_dir_all(&mount).map_err(|e| e.to_string())?;
    }
    map.add(&mount, output)?;
    Ok(PathMap::container_path(&path.to_string_lossy()))
}
fn map_config(config: &mut Value, base: &Path, map: &mut PathMap) -> Result<(), String> {
    let workdir = config
        .get("workdir")
        .and_then(Value::as_str)
        .map(|s| absolute(s, base))
        .unwrap_or_else(|| base.to_path_buf());
    fn visit(v: &mut Value, base: &Path, map: &mut PathMap) -> Result<(), String> {
        if let Some(obj) = v.as_object_mut() {
            for (k, value) in obj {
                if let Some(s) = value.as_str() {
                    if [
                        "data_file",
                        "dataFile",
                        "gene_file",
                        "geneFile",
                        "model_path",
                    ]
                    .contains(&k.as_str())
                    {
                        let p = map_path(s, base, false, false, map)?;
                        *value = json!(p);
                    } else if ["output_dir", "outputDir"].contains(&k.as_str()) {
                        let p = map_path(s, base, true, true, map)?;
                        *value = json!(p);
                    }
                } else if value.is_object() {
                    visit(value, base, map)?;
                }
            }
        }
        Ok(())
    }
    visit(config, &workdir, map)?;
    // All known paths are absolute. Preserve workdir identity through the same
    // reversible mapping; do not change frozen scientific settings or labels.
    config["workdir"] = json!(PathMap::container_path(
        &resolve_existing_parent(&workdir)?.to_string_lossy()
    ));
    Ok(())
}
pub fn prepare(
    request: &EngineRequest,
    settings: &RuntimeSettings,
    root: &Path,
    job: Arc<Job>,
) -> Result<Plan, String> {
    request.validate()?;
    let temp = tempfile::Builder::new()
        .prefix("biomarkerpred-job-")
        .tempdir()
        .map_err(|e| e.to_string())?;
    let mut request = request.clone();
    let mut map = PathMap::default();
    let base = std::env::current_dir().map_err(|e| e.to_string())?;
    let mut config = request.config.take();
    let mut config_base = base.clone();
    if let Some(file) = request.options.get("config").cloned() {
        if settings.backend == Backend::Docker {
            request.options.remove("config");
            let path = absolute(&scalar(&file), &base);
            config_base = path
                .parent()
                .ok_or("Config path has no parent")?
                .to_path_buf();
            let text = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
            // YAML 1.1 (R) and 1.2 (serde) disagree on these unquoted scalar values.
            // Require explicit quoting rather than silently changing outcome coding.
            if !path.extension().is_some_and(|e| e == "json") && ambiguous_yaml(&text) {
                return Err("Docker YAML contains an ambiguous unquoted yes/no/on/off/y/n scalar. Quote text values or use JSON so R and desktop preserve the same classes/labels.".into());
            }
            config = Some(
                serde_yaml::from_str::<Value>(&text).map_err(|e| format!("Invalid config: {e}"))?,
            );
        } else {
            request
                .options
                .insert("config".into(), json!(absolute(&scalar(&file), &base)));
        }
    }
    if config.is_some() && !matches!(request.operation, Operation::Analyze | Operation::Validate) {
        return Err("Unexpected config".into());
    }
    // Resume reconstructs every recorded input/evidence path and mount from the
    // original run. Sidecar is separate from the frozen manifest/config hashes.
    if let Some(run) = request.options.get("run").and_then(Value::as_str) {
        let run = absolute(run, &base);
        let sidecar = run.join(".desktop-runtime.json");
        if sidecar.exists() {
            let saved = read_json(&sidecar)?;
            if settings.backend == Backend::Docker {
                map =
                    serde_json::from_value(saved["path_map"].clone()).map_err(|e| e.to_string())?;
                for mount in &map.mounts {
                    if !Path::new(&mount.host).exists() {
                        return Err(format!(
                            "Original Docker mount is unavailable: {}",
                            mount.host
                        ));
                    }
                }
            }
        }
        if settings.backend == Backend::Docker {
            if run.join("config.json").exists() {
                let mut saved = read_json(&run.join("config.json"))?;
                map.map_result(&mut saved);
                map_config(&mut saved, &base, &mut map)?;
            }
        }
    }
    if let Some(mut value) = config {
        if let Some(workdir) = value.get("workdir").and_then(Value::as_str) {
            value["workdir"] = json!(absolute(workdir, &base));
        }
        if settings.backend == Backend::Docker {
            let kind = value
                .get("analysis_type")
                .or_else(|| value.get("analysisType"))
                .or_else(|| value.get("type"))
                .and_then(Value::as_str)
                .unwrap_or(if value.get("survival").is_some() {
                    "survival"
                } else {
                    "binary"
                })
                .to_owned();
            let section = value.get(&kind).unwrap_or(&value);
            if section.get("output_dir").is_none() && section.get("outputDir").is_none() {
                let schema = read_json(&root.join("config/schema.json"))?;
                let property = &schema["$defs"]["analysis"]["properties"]["output_dir"];
                let default = property
                    .get(format!("x-{kind}-default"))
                    .unwrap_or(&property["default"])
                    .clone();
                if value.get(&kind).is_some() {
                    value[&kind]["output_dir"] = default;
                } else {
                    value["output_dir"] = default;
                }
            }
        }
        if settings.backend == Backend::Docker {
            map_config(&mut value, &config_base, &mut map)?;
        } else if value.get("workdir").is_none() {
            value["workdir"] = json!(config_base);
        }
        let path = temp.path().join("config.json");
        atomic_json(&path, &value)?;
        request.options.insert("config".into(), json!(path));
    }
    if settings.backend == Backend::Docker {
        for (key, value) in &mut request.options {
            if ![
                "config", "model", "data", "output", "run", "gmt", "term-map", "mapping",
                "evidence",
            ]
            .contains(&key.as_str())
            {
                continue;
            }
            let writable = key == "output" || (key == "run" && request.operation.mutates());
            if let Some(paths) = value.as_array_mut() {
                for p in paths {
                    *p = json!(map_path(
                        p.as_str().unwrap(),
                        &base,
                        writable,
                        true,
                        &mut map
                    )?);
                }
            } else {
                let s = scalar(value);
                let is_dir = key == "run"
                    || (key == "output"
                        && !(request.operation == Operation::Predict
                            && s.to_lowercase().ends_with(".csv")));
                *value = json!(map_path(&s, &base, writable, is_dir, &mut map)?);
            }
        }
    }
    let mut cli = vec![request.operation.name().to_owned()];
    for (key, value) in &request.options {
        if let Some(a) = value.as_array() {
            for v in a {
                cli.extend([format!("--{key}"), scalar(v)]);
            }
        } else {
            cli.extend([format!("--{key}"), scalar(value)]);
        }
    }
    cli.push("--json".into());
    let (command, create_command, docker, image_id) = if settings.backend == Backend::Local {
        let mut c = Command::new(r_executable(settings, root));
        c.arg(root.join("BiomarkerCLI.R"))
            .args(cli)
            .current_dir(&base);
        (c, None, None, None)
    } else {
        let executable = settings
            .docker_path
            .clone()
            .unwrap_or_else(super::find_docker);
        let mut inspect = Command::new(&executable);
        inspect.args([
            "image",
            "inspect",
            "--format",
            "{{.Id}}",
            &settings.docker_image,
        ]);
        let inspected = run_process(
            inspect,
            job.clone(),
            Some(Duration::from_secs(20)),
            None,
            Arc::new(|_| {}),
        )?;
        if inspected.cancelled {
            return Err("Operation cancelled during Docker inspection".into());
        }
        let id = inspected.stdout.trim().to_string();
        if inspected.code != Some(0) || !id.starts_with("sha256:") {
            return Err(format!("Configured Docker image is unavailable: {}. Build/install the compatible engine image or choose local R. {}",settings.docker_image,inspected.stderr.join("\n")));
        }
        let token_hash = {
            use sha2::{Digest, Sha256};
            format!("{:x}", Sha256::digest(job.id.as_bytes()))
        };
        let name = format!("bmp-{}-{}", std::process::id(), &token_hash[..20]);
        let mut c = Command::new(&executable);
        c.args(["create", "--rm", "--name", &name, "--hostname", &name]);
        #[cfg(unix)]
        {
            c.args([
                "--user",
                &format!("{}:{}", unsafe { libc::geteuid() }, unsafe {
                    libc::getegid()
                }),
            ]);
        }
        c.args(map.args())
            .args(["--env", &format!("BMP_IMAGE_DIGEST={id}")]);
        // Execute the inspected immutable identity, never race a mutable tag.
        c.arg(&id).args(cli);
        let mut start = Command::new(&executable);
        start.args(["start", "--attach", &name]);
        (
            start,
            Some(c),
            Some(DockerProcess { executable, name }),
            Some(id),
        )
    };
    Ok(Plan {
        command,
        create_command,
        map,
        docker,
        image_id,
        _temp: temp,
    })
}
