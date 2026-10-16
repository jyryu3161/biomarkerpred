mod commands;
#[cfg(test)]
mod integration_tests;
mod models;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            Ok(())
        })
        .manage(commands::engine::EngineState::default())
        .invoke_handler(tauri::generate_handler![
            commands::engine::engine_call,
            commands::engine::engine_start,
            commands::engine::engine_cancel,
            commands::engine::engine_job_status,
            commands::artifacts::engine_read_run,
            commands::runtime::engine_schema,
            commands::runtime::engine_get_settings,
            commands::runtime::engine_save_settings,
            commands::runtime::runtime_pull_image,
            commands::fs_ops::fs_pick_file,
            commands::fs_ops::fs_pick_directory,
            commands::fs_ops::fs_read_csv_header,
            commands::fs_ops::fs_read_csv,
            commands::fs_ops::fs_read_image,
            commands::fs_ops::fs_read_text_file,
            commands::fs_ops::fs_list_output_plots,
            commands::fs_ops::fs_save_file,
            commands::fs_ops::fs_open_directory,
            commands::config::config_load_yaml,
            commands::config::config_save_yaml,
            commands::config::config_list_presets,
            commands::config::config_load_preset,
            commands::opentargets::opentargets_search_diseases,
            commands::opentargets::opentargets_fetch_genes,
            commands::opentargets::opentargets_list_cached,
            commands::opentargets::opentargets_delete_cached,
            commands::opentargets::opentargets_count_filtered,
            commands::model::model_load,
            commands::model::model_save,
            commands::model::model_check_exists,
            commands::model::prediction_read_results,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
