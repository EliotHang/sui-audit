use anyhow::{Context, Result};
use serde::Deserialize;
use std::{env, fs, path::Path};

#[derive(Debug, Deserialize, Clone)]
pub struct MasterConfig {
    pub server: MasterServerConfig,
    pub telegram: MasterTelegramConfig,
    pub worker_auth: WorkerAuthConfig,
    pub state: MasterStateConfig,
}

#[derive(Debug, Deserialize, Clone)]
pub struct MasterServerConfig {
    pub bind: String,
    pub public_base_url: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct MasterTelegramConfig {
    #[serde(default = "default_telegram_mode")]
    pub mode: String,
    pub bot_token: Option<String>,
    pub bot_token_env: Option<String>,
    #[serde(default)]
    pub allowed_chat_ids: Vec<String>,
    #[serde(default)]
    pub allowed_user_ids: Vec<String>,
    #[serde(default = "default_telegram_poll_seconds")]
    pub poll_timeout_seconds: u64,
}

#[derive(Debug, Deserialize, Clone)]
pub struct WorkerAuthConfig {
    pub token: Option<String>,
    pub token_env: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct MasterStateConfig {
    pub db_path: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct WorkerConfig {
    pub worker: WorkerIdentityConfig,
    pub master: WorkerMasterConfig,
    pub audit: WorkerAuditConfig,
    #[serde(default)]
    pub telegram: WorkerTelegramConfig,
}

#[derive(Debug, Deserialize, Clone)]
pub struct WorkerIdentityConfig {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub tags: Vec<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct WorkerMasterConfig {
    pub url: String,
    pub token: Option<String>,
    pub token_env: Option<String>,
    #[serde(default = "default_worker_poll_seconds")]
    pub poll_interval_seconds: u64,
}

#[derive(Debug, Deserialize, Clone)]
pub struct WorkerAuditConfig {
    pub repo_dir: String,
    pub run_script: String,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct WorkerTelegramConfig {
    #[serde(default)]
    pub send_direct: bool,
}

fn default_telegram_mode() -> String {
    "long_poll".to_string()
}

fn default_telegram_poll_seconds() -> u64 {
    20
}

fn default_worker_poll_seconds() -> u64 {
    15
}

pub fn load_master_config(path: impl AsRef<Path>) -> Result<MasterConfig> {
    let content = fs::read_to_string(path.as_ref())
        .with_context(|| format!("read master config {}", path.as_ref().display()))?;
    toml::from_str(&content).context("parse master config")
}

pub fn load_worker_config(path: impl AsRef<Path>) -> Result<WorkerConfig> {
    let content = fs::read_to_string(path.as_ref())
        .with_context(|| format!("read worker config {}", path.as_ref().display()))?;
    toml::from_str(&content).context("parse worker config")
}

pub fn resolve_secret(
    value: &Option<String>,
    env_name: &Option<String>,
    label: &str,
) -> Result<String> {
    if let Some(value) = value {
        if !value.is_empty() {
            return Ok(value.clone());
        }
    }
    if let Some(env_name) = env_name {
        let value = env::var(env_name).with_context(|| {
            format!("missing required environment variable {env_name} for {label}")
        })?;
        if !value.is_empty() {
            return Ok(value);
        }
    }
    anyhow::bail!("missing {label}; set direct value or *_env in config")
}
