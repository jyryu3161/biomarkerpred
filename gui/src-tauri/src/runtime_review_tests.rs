//! Independent regressions for the Windows Docker Desktop connection report.
#[cfg(unix)]
mod tests {
    use crate::commands::{
        engine_plan::prepare,
        engine_process::Job,
        engine_types::{Backend, EngineRequest, Operation, RuntimeSettings},
    };
    use std::{os::unix::fs::PermissionsExt, path::Path, sync::Arc};

    fn inspect_failure(mode: &str) -> (String, Vec<Vec<String>>) {
        let temp = tempfile::Builder::new()
            .prefix("Docker runtime review 한글 ")
            .tempdir()
            .unwrap();
        let executable = temp.path().join("configured docker");
        let calls = temp.path().join("calls.jsonl");
        let script = format!(
            "#!/usr/bin/python3\nimport json,sys\nwith open({calls},'a') as stream: stream.write(json.dumps(sys.argv[1:])+'\\n')\nmode={mode}\nif sys.argv[1:] == ['--version']:\n print('Docker version 29.0.0'); sys.exit(0)\nif mode == 'unreachable':\n print('failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified.', file=sys.stderr); sys.exit(1)\nif sys.argv[1] == 'info':\n print(json.dumps('linux') if 'json' in sys.argv[-1] else 'linux'); sys.exit(0)\nif sys.argv[1:3] == ['image','inspect']:\n print('Error response from daemon: No such image: review:missing' if mode == 'missing' else 'authorization denied by plugin for image inspection',file=sys.stderr); sys.exit(1)\nraise SystemExit(99)\n",
            calls = serde_json::to_string(&calls.to_string_lossy()).unwrap(),
            mode = serde_json::to_string(mode).unwrap(),
        );
        std::fs::write(&executable, script).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o755)).unwrap();
        let settings = RuntimeSettings {
            backend: Backend::Docker,
            docker_path: Some(executable.to_string_lossy().into_owned()),
            docker_image: "review:missing".into(),
            ..Default::default()
        };
        let request = EngineRequest {
            operation: Operation::Doctor,
            options: Default::default(),
            config: None,
            settings: None,
        };
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let failure = match prepare(
            &request,
            &settings,
            &root,
            Arc::new(Job::new("docker-review".into(), "doctor".into())),
        ) {
            Ok(_) => panic!("A failed Docker prerequisite must not produce an executable plan"),
            Err(error) => error,
        };
        let calls = std::fs::read_to_string(calls)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        (failure, calls)
    }

    #[test]
    fn reported_windows_pipe_error_is_connection_failure_without_image_inspection() {
        let (error, calls) = inspect_failure("unreachable");
        assert!(error.contains("dockerDesktopLinuxEngine"), "{error}");
        assert!(error.contains("Docker Desktop"), "{error}");
        assert!(
            !error.contains("Configured Docker image is unavailable"),
            "{error}"
        );
        assert!(!calls.iter().any(|args| matches!(
            args.first().map(String::as_str),
            Some("image" | "pull" | "create")
        )));
    }

    #[test]
    fn missing_image_on_live_engine_offers_explicit_download_without_pulling() {
        let (error, calls) = inspect_failure("missing");
        assert!(error.to_ascii_lowercase().contains("download"), "{error}");
        assert!(calls
            .iter()
            .any(|args| args.first().map(String::as_str) == Some("info")));
        assert!(calls
            .iter()
            .any(|args| args.starts_with(&["image".into(), "inspect".into()])));
        assert!(!calls
            .iter()
            .any(|args| matches!(args.first().map(String::as_str), Some("pull" | "create"))));
    }

    #[test]
    fn denied_image_inspection_is_not_a_missing_image() {
        let (error, calls) = inspect_failure("denied");
        assert!(error.contains("authorization denied"), "{error}");
        assert!(
            !error.to_ascii_lowercase().contains("not downloaded"),
            "{error}"
        );
        assert!(
            !error.contains("Configured Docker image is unavailable"),
            "{error}"
        );
        assert!(!calls
            .iter()
            .any(|args| args.first().map(String::as_str) == Some("pull")));
    }

    #[test]
    fn real_docker_distinguishes_available_missing_and_unreachable_engines() {
        use crate::commands::runtime::{inspect_docker, DockerState};
        let Ok(image) = std::env::var("BMP_TEST_DOCKER_IMAGE") else {
            eprintln!("SKIP real Docker prerequisite review: BMP_TEST_DOCKER_IMAGE is unset");
            return;
        };
        let executable = std::env::var("BMP_TEST_DOCKER_PATH").unwrap_or_else(|_| "docker".into());
        let mut settings = RuntimeSettings {
            backend: Backend::Docker,
            docker_path: Some(executable.clone()),
            docker_image: image,
            ..Default::default()
        };
        let inspect = |value: &RuntimeSettings| {
            inspect_docker(
                value,
                Arc::new(Job::new("actual-docker-review".into(), "doctor".into())),
            )
            .unwrap()
        };
        let ready = inspect(&settings);
        assert_eq!(ready.state, DockerState::Ready, "{}", ready.error_message());
        assert!(ready.image_id.as_deref().unwrap().starts_with("sha256:"));
        settings.docker_image = format!(
            "biomarkerpred-review-do-not-pull:{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let missing = inspect(&settings);
        assert_eq!(
            missing.state,
            DockerState::ImageMissing,
            "{}",
            missing.error_message()
        );

        let temp = tempfile::Builder::new()
            .prefix("Docker context 한글 ")
            .tempdir()
            .unwrap();
        let wrapper = temp.path().join("selected docker");
        let absent_socket = format!("unix://{}", temp.path().join("absent.sock").display());
        let quote = |value: &str| format!("'{}'", value.replace('\'', "'\\''"));
        std::fs::write(
            &wrapper,
            format!(
                "#!/bin/sh\nexec {} --host {} \"$@\"\n",
                quote(&executable),
                quote(&absent_socket)
            ),
        )
        .unwrap();
        std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
        settings.docker_path = Some(wrapper.to_string_lossy().into_owned());
        let unreachable = inspect(&settings);
        assert_eq!(
            unreachable.state,
            DockerState::EngineUnreachable,
            "{}",
            unreachable.error_message()
        );
        assert!(unreachable.image_id.is_none());
        assert!(unreachable.error_message().contains("absent.sock"));
        assert!(!unreachable.error_message().contains("not downloaded"));
    }
}
