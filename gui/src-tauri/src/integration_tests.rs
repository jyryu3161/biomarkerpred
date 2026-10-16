use crate::commands::{
    artifacts::*,
    engine::execute,
    engine_plan::{prepare, PathMap},
    engine_process::*,
    engine_types::*,
    fs_ops::read_csv,
    model::validate_model,
};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::{atomic::Ordering, Arc},
    time::{Duration, Instant},
};
fn request(operation: Operation) -> EngineRequest {
    EngineRequest {
        operation,
        options: Default::default(),
        config: None,
        settings: None,
    }
}
fn root() -> PathBuf {
    std::env::var_os("BMP_TEST_ENGINE_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../..")
                .canonicalize()
                .unwrap()
        })
}
fn real_runtime() -> Option<(PathBuf, RuntimeSettings)> {
    let path = std::env::var("BMP_TEST_RSCRIPT").ok()?;
    Some((
        root(),
        RuntimeSettings {
            r_path: Some(path),
            ..Default::default()
        },
    ))
}
fn call(request: &EngineRequest, settings: &RuntimeSettings, root: &Path) -> EngineResponse {
    execute(
        request,
        settings,
        root,
        Arc::new(Job::new(
            "test-call".into(),
            request.operation.name().into(),
        )),
        Arc::new(|_| {}),
    )
    .unwrap()
}
#[test]
fn csv_preserves_strings_quotes_bom_and_multiline() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("quoted.csv");
    std::fs::write(&path,"\u{feff}sample,\"gene,quoted\",note\n001,2,\"line one\nline two\"\n900719925474099312345,3,ok\n").unwrap();
    let table = read_csv(&path, None).unwrap();
    assert_eq!(table["count"], 2);
    assert_eq!(table["headers"][1], "gene,quoted");
    assert_eq!(table["rows"][0]["sample"], "001");
    assert_eq!(table["rows"][1]["sample"], "900719925474099312345");
    assert_eq!(table["rows"][0]["note"], "line one\nline two");
}
#[test]
fn copy_same_path_symlink_hardlink_preserves_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("model");
    std::fs::write(&source, b"frozen model").unwrap();
    copy_preserving_source(&source, &source).unwrap();
    #[cfg(unix)]
    {
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&source, &link).unwrap();
        copy_preserving_source(&source, &link).unwrap();
        let hard = dir.path().join("hard");
        std::fs::hard_link(&source, &hard).unwrap();
        copy_preserving_source(&source, &hard).unwrap();
    }
    assert_eq!(std::fs::read(&source).unwrap(), b"frozen model");
}
fn null_model() -> Value {
    json!({"format":"BioMarkerPred","model_version":1,"analysis_type":"binary","sample_id":"id","group_column":null,"features":[],"design_columns":[],"selected_genes":[],"clinical_columns":[],"coefficients":{},"intercept":0.2,"threshold":0.6,"recipe":{"recipe_version":1,"predictors":{},"design":[]},"outcome":{"positive_class":"yes","negative_class":"no","positive_label":"Responder","negative_label":"Non-responder"}})
}
#[test]
fn portable_null_model_valid_but_legacy_encoder_missing_invalid() {
    let mut model = null_model();
    assert!(validate_model(&model).is_ok());
    model["features"] = json!(["A"]);
    assert!(validate_model(&model).unwrap_err().contains("Retrain"));
    assert!(validate_model(
        &json!({"version":"0.4","model":{"variables":["A"],"coefficients":{"A":1}}})
    )
    .unwrap_err()
    .contains("Retrain"));
}
#[test]
fn registry_reserves_before_spawn_and_preserves_finished_identity() {
    let registry = Arc::new(JobRegistry::default());
    let first = registry.reserve("first", "analyze").unwrap();
    assert!(registry.reserve("second", "predict").is_err());
    first.cancel.store(true, Ordering::SeqCst);
    assert!(registry.reserve("second", "predict").is_err());
    let response = EngineResponse {
        success: false,
        cancelled: true,
        exit_code: None,
        result: json!({}),
        verification_error: None,
        stderr_tail: vec![],
    };
    registry.finish(&first, response.clone());
    let second = registry.reserve("second", "predict").unwrap();
    registry.finish(&first, response);
    assert_eq!(registry.active().unwrap().job_id, second.id);
    assert!(
        registry
            .get("first")
            .unwrap()
            .snapshot
            .lock()
            .unwrap()
            .response
            .as_ref()
            .unwrap()
            .cancelled
    );
}
#[test]
fn argv_keeps_comma_paths_and_literal_metacharacters() {
    let root = root();
    let mut req = request(Operation::Compare);
    req.options
        .insert("run".into(), json!(["/a/run, one", "/b/$(literal); two"]));
    let plan = prepare(
        &req,
        &RuntimeSettings::default(),
        &root,
        Arc::new(Job::new("argv".into(), "compare".into())),
    )
    .unwrap();
    let args: Vec<_> = plan
        .command
        .get_args()
        .map(|s| s.to_string_lossy().into_owned())
        .collect();
    assert!(args.windows(2).any(|w| w == ["--run", "/a/run, one"]));
    assert!(args.contains(&"/b/$(literal); two".to_owned()));
    req.options.insert("output".into(), json!("x"));
    assert!(req.validate().is_err());
}
#[test]
fn windows_mapping_and_docker_mount_csv_are_reversible() {
    assert_eq!(
        PathMap::container_path("C:\\Data with spaces\\input.csv"),
        "/bmp-host/C/Data with spaces/input.csv"
    );
    let map = PathMap {
        mounts: vec![crate::commands::engine_plan::Mount {
            host: "C:\\Data with spaces".into(),
            container: "/bmp-host/C/Data with spaces".into(),
            writable: false,
        }],
    };
    assert!(map
        .to_host("/bmp-host/C/Data with spaces/a.csv")
        .contains("a.csv"));
    let dir = tempfile::Builder::new()
        .prefix(if cfg!(windows) {
            "comma, space"
        } else {
            "comma, quote\""
        })
        .tempdir()
        .unwrap();
    let mut map = PathMap::default();
    map.add(dir.path(), false).unwrap();
    let args = map.args();
    let record = csv::ReaderBuilder::new()
        .has_headers(false)
        .from_reader(args[1].as_bytes())
        .records()
        .next()
        .unwrap()
        .unwrap();
    assert_eq!(record[1], format!("source={}", dir.path().display()));
    assert_eq!(&record[3], "readonly");
}
#[cfg(unix)]
fn executable(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}
#[cfg(unix)]
#[test]
fn exited_parent_with_inherited_worker_pipes_cannot_hang() {
    let job = Arc::new(Job::new("orphan".into(), "doctor".into()));
    let mut cmd = Command::new("python3");
    cmd.args([
        "-c",
        "import os,time\npid=os.fork()\nif pid: os._exit(0)\ntime.sleep(60)",
    ]);
    let start = Instant::now();
    let result = run_process(
        cmd,
        job,
        Some(Duration::from_secs(10)),
        None,
        Arc::new(|_| {}),
    );
    assert!(result.unwrap_err().contains("worker held"));
    assert!(start.elapsed() < Duration::from_secs(10));
}
#[cfg(unix)]
#[test]
fn timeout_and_cancel_before_start_are_bounded() {
    let job = Arc::new(Job::new("timeout".into(), "doctor".into()));
    let mut cmd = Command::new("python3");
    cmd.args(["-c", "import time;time.sleep(60)"]);
    let start = Instant::now();
    let out = run_process(
        cmd,
        job,
        Some(Duration::from_millis(100)),
        None,
        Arc::new(|_| {}),
    )
    .unwrap();
    assert!(out.timed_out);
    assert!(start.elapsed() < Duration::from_secs(4));
    let job = Arc::new(Job::new("startup".into(), "analyze".into()));
    job.cancel.store(true, Ordering::SeqCst);
    let out = run_process(
        Command::new("does-not-exist"),
        job,
        None,
        None,
        Arc::new(|_| {}),
    )
    .unwrap();
    assert!(out.cancelled);
}
#[test]
fn real_r_psock_tree_cancellation_stops_parent_and_two_workers() {
    let Some((root, settings)) = real_runtime() else {
        eprintln!("SKIP real R workers: set BMP_TEST_RSCRIPT");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let job = Arc::new(Job::new("real-workers".into(), "analyze".into()));
    let run_job = job.clone();
    let mut cmd = Command::new(settings.r_path.unwrap());
    cmd.arg(root.join("tests/fixtures/worker_process_tree.R"))
        .arg(dir.path());
    let thread =
        std::thread::spawn(move || run_process(cmd, run_job, None, None, Arc::new(|_| {})));
    let start = Instant::now();
    while !dir.path().join("ready").exists() {
        assert!(start.elapsed() < Duration::from_secs(30));
        std::thread::sleep(Duration::from_millis(50));
    }
    let pids: Vec<u32> = std::fs::read_dir(dir.path())
        .unwrap()
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "pid"))
        .map(|e| {
            std::fs::read_to_string(e.path())
                .unwrap()
                .trim()
                .parse()
                .unwrap()
        })
        .collect();
    assert_eq!(pids.len(), 3);
    job.cancel.store(true, Ordering::SeqCst);
    assert!(thread.join().unwrap().unwrap().cancelled);
    for pid in pids {
        #[cfg(unix)]
        {
            let output = Command::new("ps")
                .args(["-p", &pid.to_string(), "-o", "stat="])
                .output()
                .unwrap();
            let state = String::from_utf8_lossy(&output.stdout);
            assert!(
                state.trim().is_empty() || state.trim().starts_with('Z'),
                "PID {pid} still running: {state}"
            );
        }
        #[cfg(windows)]
        {
            let output = Command::new("tasklist")
                .args(["/FI", &format!("PID eq {pid}"), "/FO", "CSV", "/NH"])
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "tasklist failed while verifying PID {pid}"
            );
            let text = String::from_utf8_lossy(&output.stdout);
            let found = csv::ReaderBuilder::new()
                .has_headers(false)
                .flexible(true)
                .from_reader(text.as_bytes())
                .records()
                .filter_map(Result::ok)
                .any(|row| row.get(1) == Some(pid.to_string().as_str()));
            assert!(!found, "PID {pid} still running: {text}");
        }
    }
}
#[test]
fn real_cli_doctor_qc_analyze_and_model_roundtrip() {
    let Some((root, settings)) = real_runtime() else {
        eprintln!("SKIP real R integration: set BMP_TEST_RSCRIPT");
        return;
    };
    let doctor = call(&request(Operation::Doctor), &settings, &root);
    assert!(doctor.success, "{doctor:?}");
    let temp = tempfile::Builder::new()
        .prefix("rust real CLI ; ")
        .tempdir()
        .unwrap();
    let mut config = read_json(&root.join("tests/fixtures/binary.json")).unwrap();
    config["data_file"] = json!(root.join("tests/fixtures/binary.csv"));
    config["output_dir"] = json!(temp.path().join("results"));
    config["models"] = json!(["stepwise"]);
    config["feature_sets"] = json!(["genes"]);
    config["clinical_columns"] = json!([]);
    config["features"] = json!(["GENE-2"]);
    config["p_threshold"] = json!(1e-300);
    config["panel_sizes"] = json!([1]);
    config["bootstrap_samples"] = json!(0);
    let mut req = request(Operation::Validate);
    req.config = Some(config.clone());
    let valid = call(&req, &settings, &root);
    assert!(valid.success, "{valid:?}");
    assert_eq!(valid.result["qc"]["status"], "passed");
    req.config.as_mut().unwrap()["outcome"] = json!("nonexistent");
    let invalid = call(&req, &settings, &root);
    assert!(!invalid.success);
    assert!(invalid.result["qc"].is_object(), "{invalid:?}");
    // Original file config lives outside invocation cwd. The production runner
    // must equal direct R normalization exactly, including source_config.
    let config_path = temp.path().join("original file config.json");
    let mut relative_config = config.clone();
    relative_config["data_file"] = json!("cohort.csv");
    std::fs::copy(
        root.join("tests/fixtures/binary.csv"),
        temp.path().join("cohort.csv"),
    )
    .unwrap();
    atomic_json(&config_path, &relative_config).unwrap();
    let mut file_req = request(Operation::Validate);
    file_req.options.insert("config".into(), json!(config_path));
    let indirect = call(&file_req, &settings, &root);
    let direct = Command::new(settings.r_path.as_ref().unwrap())
        .arg(root.join("BiomarkerCLI.R"))
        .args(["validate", "--config"])
        .arg(&config_path)
        .arg("--json")
        .output()
        .unwrap();
    let direct: Value = serde_json::from_slice(&direct.stdout).unwrap();
    assert_eq!(indirect.result["config"], direct["config"]);
    assert_eq!(indirect.result["qc"], direct["qc"]);
    req.config = Some(config);
    req.operation = Operation::Analyze;
    let analyzed = call(&req, &settings, &root);
    assert!(analyzed.success, "{analyzed:?}");
    let run = Path::new(analyzed.result["run_dir"].as_str().unwrap());
    verify_run(run, true).unwrap();
    let model = read_json(&run.join("model.bmpmodel")).unwrap();
    assert_eq!(model["features"], json!([]));
    validate_model(&model).unwrap();
    let mut resume = request(Operation::Resume);
    resume.options.insert("run".into(), json!(run));
    let resumed = call(&resume, &settings, &root);
    assert!(resumed.success, "{resumed:?}");
    assert_eq!(analyzed.result["run_id"], resumed.result["run_id"]);
    let mut predict = request(Operation::Predict);
    predict
        .options
        .insert("model".into(), json!(run.join("model.bmpmodel")));
    predict
        .options
        .insert("data".into(), json!(root.join("tests/fixtures/binary.csv")));
    predict.options.insert(
        "output".into(),
        json!(temp.path().join("prediction result.csv")),
    );
    assert!(call(&predict, &settings, &root).success);
    let mut evaluation = predict.clone();
    evaluation.operation = Operation::Evaluate;
    evaluation
        .options
        .insert("output".into(), json!(temp.path().join("external")));
    evaluation
        .options
        .insert("bootstrap-samples".into(), json!(0));
    let evaluated = call(&evaluation, &settings, &root);
    assert!(evaluated.success, "{evaluated:?}");
    let mut history = request(Operation::Runs);
    history
        .options
        .insert("output".into(), json!(temp.path().join("results")));
    assert!(call(&history, &settings, &root).success);
    let mut compare = request(Operation::Compare);
    compare
        .options
        .insert("run".into(), json!([run, evaluated.result["run_dir"]]));
    assert!(call(&compare, &settings, &root).success);
    let mut report = resume.clone();
    report.operation = Operation::Report;
    assert!(call(&report, &settings, &root).success);
    let gmt = temp.path().join("annotation.gmt");
    std::fs::write(&gmt, "term\tdescription\tGENE-2\tgene A\n").unwrap();
    let mut ora = request(Operation::Ora);
    ora.options.insert("run".into(), json!(run));
    ora.options.insert("gmt".into(), json!(gmt));
    ora.options.insert("min-size".into(), json!(1));
    ora.options.insert("permutations".into(), json!(49));
    ora.options.insert("network".into(), json!("none"));
    let pathway = call(&ora, &settings, &root);
    assert!(pathway.success, "{pathway:?}");
    let before = sha256(&run.join("manifest.json")).unwrap();
    let cancel_job = Arc::new(Job::new("cancel-pathway".into(), "ora".into()));
    let watcher = cancel_job.clone();
    let cancelled = execute(
        &ora,
        &settings,
        &root,
        cancel_job.clone(),
        Arc::new(move |event| {
            if event.payload["source_run_id"].is_string() {
                watcher.cancel.store(true, Ordering::SeqCst);
            }
        }),
    )
    .unwrap();
    assert!(cancelled.cancelled, "{cancelled:?}");
    assert_eq!(before, sha256(&run.join("manifest.json")).unwrap());
    assert!(!run.join(".mutation.lock").exists());
    for derivative in cancel_job.run_dirs.lock().unwrap().iter() {
        assert_eq!(
            read_json(&derivative.join("manifest.json")).unwrap()["status"],
            "cancelled"
        );
    }
    std::fs::write(run.join("predictions.csv"), "tampered").unwrap();
    assert!(verify_run(run, true).unwrap_err().contains("checksum"));
}
#[cfg(unix)]
#[test]
fn zero_exit_bad_protocol_and_unfinished_manifest_never_succeed() {
    let dir = tempfile::tempdir().unwrap();
    let fake = dir.path().join("fake-r");
    let runtime = RuntimeSettings {
        r_path: Some(fake.to_string_lossy().into()),
        ..Default::default()
    };
    let doctor = json!({"ok":true,"application":"BioMarkerPred","interface_version":1,"config_version":1,"model_version":1,"packages":{"yaml":"1","jsonlite":"1","digest":"1","survival":"1","glmnet":"1","pROC":"1"},"graphics":{"cairo":true,"png":true,"tiff":true}});
    let mut req = request(Operation::Analyze);
    req.config = Some(json!({"analysis_type":"binary"}));
    executable(&fake,&format!("#!/usr/bin/python3\nimport sys\nif sys.argv[2]=='doctor': print({:?})\nelse: print('not JSON')\n",doctor.to_string()));
    let result = execute(
        &req,
        &runtime,
        &root(),
        Arc::new(Job::new("fake".into(), "analyze".into())),
        Arc::new(|_| {}),
    );
    assert!(result.unwrap_err().contains("protocol"));
    atomic_json(
        &dir.path().join("manifest.json"),
        &json!({"run_id":"bad","status":"running"}),
    )
    .unwrap();
    let response = json!({"ok":true,"run_id":"bad","run_dir":dir.path(),"status":"completed"});
    executable(
        &fake,
        &format!(
            "#!/usr/bin/python3\nimport sys\nprint({:?} if sys.argv[2]=='doctor' else {:?})\n",
            doctor.to_string(),
            response.to_string()
        ),
    );
    let result = call(&req, &runtime, &root());
    assert!(!result.success);
    assert!(result.verification_error.unwrap().contains("not completed"));
    atomic_json(&dir.path().join("manifest.json"),&json!({"run_id":"bad","status":"completed","required_artifacts":["missing.csv"],"artifact_verification":{"sha256":{"missing.csv":"deadbeef"}}})).unwrap();
    let result = call(&req, &runtime, &root());
    assert!(!result.success);
    assert!(result
        .verification_error
        .unwrap()
        .contains("Missing artifact"));
}

#[cfg(unix)]
fn fake_docker(dir: &Path) -> PathBuf {
    let exe = dir.join("fake-docker");
    executable(&exe,"#!/usr/bin/python3\nimport sys\nif sys.argv[1:3]==['image','inspect']: print('sha256:'+'a'*64)\nelse: sys.exit(1)\n");
    exe
}
#[cfg(unix)]
#[test]
fn docker_plan_default_output_separate_mounts_and_second_invocation_resume() {
    let temp = tempfile::tempdir().unwrap();
    let input = temp.path().join("input, with spaces");
    let evidence = temp.path().join("evidence with spaces");
    let work = temp.path().join("workspace");
    for dir in [&input, &evidence, &work] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::write(input.join("cohort.csv"), "id,x\n01,2\n").unwrap();
    std::fs::write(evidence.join("genes.csv"), "gene_symbol,score\nA,0.5\n").unwrap();
    let settings = RuntimeSettings {
        backend: Backend::Docker,
        docker_path: Some(fake_docker(temp.path()).to_string_lossy().into_owned()),
        ..Default::default()
    };
    let mut req = request(Operation::Analyze);
    req.config = Some(
        json!({"analysis_type":"binary","workdir":work,"data_file":input.join("cohort.csv"),"evidence":{"gene_file":evidence.join("genes.csv")}}),
    );
    let plan = prepare(
        &req,
        &settings,
        &root(),
        Arc::new(Job::new("plan-first".into(), "analyze".into())),
    )
    .unwrap();
    let args: Vec<_> = plan
        .create_command
        .as_ref()
        .unwrap()
        .get_args()
        .map(|s| s.to_string_lossy().into_owned())
        .collect();
    assert_eq!(args[0], "create");
    assert!(args
        .iter()
        .any(|a| a == &format!("BMP_IMAGE_DIGEST=sha256:{}", "a".repeat(64))));
    let config_index = args.iter().position(|a| a == "--config").unwrap() + 1;
    let saved = read_json(Path::new(&args[config_index])).unwrap();
    assert_eq!(saved["output_dir"], json!(work.join("results/binary")));
    assert!(plan
        .map
        .mounts
        .iter()
        .any(|m| m.host == input.to_string_lossy() && !m.writable));
    assert!(plan
        .map
        .mounts
        .iter()
        .any(|m| m.host == evidence.to_string_lossy() && !m.writable));
    assert!(plan
        .map
        .mounts
        .iter()
        .any(|m| m.host == work.join("results/binary").to_string_lossy() && m.writable));
    let run = work.join("results/binary/runs/test");
    std::fs::create_dir_all(&run).unwrap();
    atomic_json(&run.join("config.json"), &saved).unwrap();
    let mut map = plan.map.clone();
    map.mounts
        .retain(|m| !Path::new(&m.host).starts_with(plan._temp.path()));
    atomic_json(
        &run.join(".desktop-runtime.json"),
        &json!({"path_map":map,"image_id":plan.image_id}),
    )
    .unwrap();
    let transient = plan._temp.path().to_path_buf();
    drop(plan);
    assert!(!transient.exists());
    let mut resume = request(Operation::Resume);
    resume.options.insert("run".into(), json!(run));
    let resumed = prepare(
        &resume,
        &settings,
        &root(),
        Arc::new(Job::new("plan-second".into(), "resume".into())),
    )
    .unwrap();
    assert!(resumed
        .map
        .mounts
        .iter()
        .any(|m| m.host == input.to_string_lossy()));
    assert!(!resumed
        .map
        .mounts
        .iter()
        .any(|m| Path::new(&m.host).starts_with(&transient)));
}
#[cfg(unix)]
#[test]
fn docker_cancel_during_create_never_starts_container() {
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("docker");
    let marker = temp.path().join("creating");
    let log = temp.path().join("calls");
    executable(&script,&format!("#!/usr/bin/python3\nimport sys,time\nwith open({:?},'a') as f: f.write(sys.argv[1]+'\\n')\nif sys.argv[1:3]==['image','inspect']: print('sha256:'+'a'*64)\nelif sys.argv[1]=='create':\n open({:?},'w').write('ready')\n time.sleep(60)\nelif sys.argv[1] in ['stop','rm','info']: pass\nelse: sys.exit(1)\n",log.to_string_lossy(),marker.to_string_lossy()));
    let settings = RuntimeSettings {
        backend: Backend::Docker,
        docker_path: Some(script.to_string_lossy().into_owned()),
        ..Default::default()
    };
    let job = Arc::new(Job::new("cancel-create".into(), "analyze".into()));
    let execution_job = job.clone();
    let root = root();
    let thread = std::thread::spawn(move || {
        execute(
            &request(Operation::Doctor),
            &settings,
            &root,
            execution_job,
            Arc::new(|_| {}),
        )
    });
    let start = Instant::now();
    while !marker.exists() {
        assert!(start.elapsed() < Duration::from_secs(10));
        std::thread::sleep(Duration::from_millis(30));
    }
    job.cancel.store(true, Ordering::SeqCst);
    assert!(thread.join().unwrap().unwrap().cancelled);
    assert!(!std::fs::read_to_string(log)
        .unwrap()
        .lines()
        .any(|line| line == "start"));
}
#[cfg(unix)]
#[test]
fn unknown_container_termination_is_explicit_and_recovery_can_retry() {
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("docker");
    executable(&script, "#!/usr/bin/python3\nimport sys\nsys.exit(1)\n");
    let job = Arc::new(Job::new("unverified".into(), "analyze".into()));
    let run_job = job.clone();
    let docker = DockerProcess {
        executable: script.to_string_lossy().into_owned(),
        name: "owned-container".into(),
    };
    let mut command = Command::new("python3");
    command.args(["-c", "import time;time.sleep(60)"]);
    let thread = std::thread::spawn(move || {
        run_process(command, run_job, None, Some(docker), Arc::new(|_| {}))
    });
    let start = Instant::now();
    while job.pid.load(Ordering::SeqCst) == 0 {
        assert!(start.elapsed() < Duration::from_secs(5));
        std::thread::sleep(Duration::from_millis(20));
    }
    job.cancel.store(true, Ordering::SeqCst);
    assert!(thread
        .join()
        .unwrap()
        .unwrap_err()
        .contains("[termination-unverified]"));
    executable(&script, "#!/usr/bin/python3\npass\n");
    verify_termination(&job).unwrap();
}
#[test]
fn accepted_late_cancel_wins_and_completed_response_retention_is_bounded() {
    let registry = JobRegistry::default();
    for i in 0..40 {
        let id = format!("job-{i}");
        let job = registry.reserve(&id, "analyze").unwrap();
        registry.cancel(&id).unwrap();
        let response = registry.finish(
            &job,
            EngineResponse {
                success: true,
                cancelled: false,
                exit_code: Some(0),
                result: json!({"status":"completed"}),
                verification_error: None,
                stderr_tail: vec![],
            },
        );
        assert!(!response.success && response.cancelled);
    }
    assert!(registry.get("job-0").is_err());
    assert!(registry.get("job-39").is_ok());
    assert!(registry.reserve("job-0", "analyze").is_err());
}

#[tokio::test]
async fn partial_run_inspection_keeps_qc_and_reports_integrity_failure() {
    let temp = tempfile::tempdir().unwrap();
    atomic_json(&temp.path().join("manifest.json"),&json!({"run_id":"partial","status":"failed","required_artifacts":["predictions.csv"],"engine_artifact_verification":{"sha256":{"predictions.csv":"absent"}}})).unwrap();
    atomic_json(
        &temp.path().join("qc.json"),
        &json!({"status":"failed","errors":["Invalid outcome"]}),
    )
    .unwrap();
    let result =
        crate::commands::artifacts::engine_read_run(temp.path().to_string_lossy().into_owned())
            .await
            .unwrap();
    assert_eq!(result["manifest"]["status"], "failed");
    assert_eq!(
        result["artifacts"]["qc.json"]["errors"][0],
        "Invalid outcome"
    );
    assert!(result["verification_error"]
        .as_str()
        .unwrap()
        .contains("Missing artifact"));
}
#[cfg(unix)]
#[test]
fn doctor_rejects_missing_package_and_required_graphics() {
    let temp = tempfile::tempdir().unwrap();
    let exe = temp.path().join("Rscript");
    let settings = RuntimeSettings {
        r_path: Some(exe.to_string_lossy().into_owned()),
        ..Default::default()
    };
    let mut doctor = json!({"ok":true,"application":"BioMarkerPred","interface_version":1,"config_version":1,"model_version":1,"packages":{"yaml":"1","jsonlite":"1","digest":null,"survival":"1","glmnet":"1","pROC":"1"},"graphics":{"cairo":true,"png":true,"tiff":true}});
    executable(
        &exe,
        &format!("#!/usr/bin/python3\nprint({:?})\n", doctor.to_string()),
    );
    let response = call(&request(Operation::Doctor), &settings, &root());
    assert!(!response.success);
    assert!(response.verification_error.unwrap().contains("digest"));
    doctor["packages"]["digest"] = json!("1");
    doctor["graphics"]["tiff"] = json!(false);
    executable(
        &exe,
        &format!("#!/usr/bin/python3\nprint({:?})\n", doctor.to_string()),
    );
    assert!(call(&request(Operation::Doctor), &settings, &root())
        .verification_error
        .unwrap()
        .contains("tiff"));
}
#[test]
fn real_survival_null_model_remains_portable() {
    let Some((root, settings)) = real_runtime() else {
        eprintln!("SKIP real R survival: set BMP_TEST_RSCRIPT");
        return;
    };
    let temp = tempfile::tempdir().unwrap();
    let mut config = read_json(&root.join("tests/fixtures/survival.json")).unwrap();
    config["data_file"] = json!(root.join("tests/fixtures/survival.csv"));
    config["output_dir"] = json!(temp.path().join("survival"));
    config["models"] = json!(["stepwise"]);
    config["feature_sets"] = json!(["genes"]);
    config["features"] = json!(["GENE-2"]);
    config["p_threshold"] = json!(1e-300);
    config["bootstrap_samples"] = json!(0);
    config["panel_sizes"] = json!([1]);
    let mut req = request(Operation::Analyze);
    req.config = Some(config);
    let output = call(&req, &settings, &root);
    assert!(output.success, "{output:?}");
    let model =
        read_json(&Path::new(output.result["run_dir"].as_str().unwrap()).join("model.bmpmodel"))
            .unwrap();
    assert_eq!(model["features"], json!([]));
    validate_model(&model).unwrap();
    let mut bad = model.clone();
    bad["baseline"] = Value::Null;
    assert!(validate_model(&bad).unwrap_err().contains("Retrain"));
}

#[test]
fn real_docker_cli_separate_paths_resume_and_cancellation() {
    let Ok(image) = std::env::var("BMP_TEST_DOCKER_IMAGE") else {
        eprintln!("SKIP real Docker image: set BMP_TEST_DOCKER_IMAGE and a host-visible TMPDIR");
        return;
    };
    let root = root();
    let base = root.join("tests/runtime");
    let temp = tempfile::Builder::new()
        .prefix("desktop Docker review ")
        .tempdir_in(&base)
        .unwrap();
    let input = temp.path().join("input, data");
    let evidence = temp.path().join("external evidence");
    let models = temp.path().join("frozen models");
    for p in [&input, &evidence, &models] {
        std::fs::create_dir_all(p).unwrap();
    }
    std::fs::copy(
        root.join("tests/fixtures/binary.csv"),
        input.join("cohort.csv"),
    )
    .unwrap();
    std::fs::write(
        evidence.join("genes.csv"),
        "gene_symbol,score\nGENE-2,0.8\ngene A,0.8\n\"gene,quoted\",0.8\n",
    )
    .unwrap();
    let settings = RuntimeSettings {
        backend: Backend::Docker,
        docker_image: image,
        docker_path: std::env::var("BMP_TEST_DOCKER_PATH").ok(),
        ..Default::default()
    };
    let doctor = call(&request(Operation::Doctor), &settings, &root);
    assert!(doctor.success, "{doctor:?}");
    let mut config = read_json(&root.join("tests/fixtures/binary.json")).unwrap();
    config["data_file"] = json!(input.join("cohort.csv"));
    config["output_dir"] = json!(temp.path().join("development results"));
    config["models"] = json!(["stepwise"]);
    config["feature_sets"] = json!(["genes"]);
    config["features"] = json!(["GENE-2", "gene A", "gene,quoted"]);
    config["p_threshold"] = json!(1e-300);
    config["panel_sizes"] = json!([1]);
    config["bootstrap_samples"] = json!(0);
    config["evidence"] = json!({"gene_file":evidence.join("genes.csv"),"score_threshold":0.1,"source":"Synthetic test"});
    let mut analyze = request(Operation::Analyze);
    analyze.config = Some(config);
    let developed = call(&analyze, &settings, &root);
    assert!(developed.success, "{developed:?}");
    let run = Path::new(developed.result["run_dir"].as_str().unwrap());
    assert!(run.starts_with(temp.path()));
    let manifest = verify_run(run, true).unwrap();
    let context = read_json(&run.join(".desktop-runtime.json")).unwrap();
    let image_id = context["image_id"].as_str().unwrap();
    assert!(image_id.starts_with("sha256:"));
    assert!(manifest["provenance"].to_string().contains(image_id));
    let mut resume = request(Operation::Resume);
    resume.options.insert("run".into(), json!(run));
    assert!(call(&resume, &settings, &root).success);
    let model_path = models.join("portable model.bmpmodel");
    copy_preserving_source(&run.join("model.bmpmodel"), &model_path).unwrap();
    let mut predict = request(Operation::Predict);
    predict.options.insert("model".into(), json!(model_path));
    predict
        .options
        .insert("data".into(), json!(input.join("cohort.csv")));
    predict.options.insert(
        "output".into(),
        json!(temp.path().join("prediction outputs/scores.csv")),
    );
    let predicted = call(&predict, &settings, &root);
    assert!(predicted.success, "{predicted:?}");
    assert!(Path::new(predicted.result["output"].as_str().unwrap()).is_file());
    let mut evaluate = predict;
    evaluate.operation = Operation::Evaluate;
    evaluate
        .options
        .insert("output".into(), json!(temp.path().join("external results")));
    evaluate
        .options
        .insert("bootstrap-samples".into(), json!(0));
    let evaluated = call(&evaluate, &settings, &root);
    assert!(evaluated.success, "{evaluated:?}");
    let mut evaluate_resume = request(Operation::Resume);
    evaluate_resume
        .options
        .insert("run".into(), evaluated.result["run_dir"].clone());
    let resumed = call(&evaluate_resume, &settings, &root);
    assert!(resumed.success, "{resumed:?}");
    let gmt = temp.path().join("pathway terms.gmt");
    std::fs::write(&gmt, "term\tdesc\tGENE-2\n").unwrap();
    let mut ora = request(Operation::Ora);
    ora.options.insert("run".into(), json!(run));
    ora.options.insert("gmt".into(), json!(gmt));
    ora.options.insert("network".into(), json!("none"));
    ora.options.insert("min-size".into(), json!(1));
    ora.options.insert("permutations".into(), json!(1000000));
    let before = sha256(&run.join("manifest.json")).unwrap();
    let job = Arc::new(Job::new("docker-cancel-ora".into(), "ora".into()));
    let watch = job.clone();
    let cancelled = execute(
        &ora,
        &settings,
        &root,
        job.clone(),
        Arc::new(move |event| {
            if event.payload["source_run_id"].is_string() {
                watch.cancel.store(true, Ordering::SeqCst);
            }
        }),
    )
    .unwrap();
    assert!(cancelled.cancelled, "{cancelled:?}");
    assert_eq!(before, sha256(&run.join("manifest.json")).unwrap());
    assert!(!run.join(".mutation.lock").exists());
    assert!(!job.run_dirs.lock().unwrap().is_empty());
    for derivative in job.run_dirs.lock().unwrap().iter() {
        let manifest = read_json(&derivative.join("manifest.json")).unwrap();
        assert_eq!(manifest["status"], "cancelled");
        assert!(manifest["finished_at"].is_string());
        let pointer = read_json(
            &derivative
                .parent()
                .unwrap()
                .parent()
                .unwrap()
                .join("latest.json"),
        )
        .unwrap();
        assert_eq!(pointer["status"], "cancelled");
    }
}

#[test]
fn docker_yaml_ambiguity_detects_flow_and_block_values_but_keeps_quoted_labels() {
    use crate::commands::engine_plan::ambiguous_yaml;
    assert!(ambiguous_yaml("positive_class: yes\n"));
    assert!(ambiguous_yaml("features: [A, on]\n"));
    assert!(ambiguous_yaml("features:\n  - off\n"));
    assert!(!ambiguous_yaml("positive_class: 'yes'\nnegative_class: \"no\"\nfeatures: [\"on\", 'off']\n# yes is a comment\n"));
}
