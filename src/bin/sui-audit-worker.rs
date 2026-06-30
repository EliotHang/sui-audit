use anyhow::{Context, Result};
use clap::Parser;
use reqwest::Client;
use serde_json::json;
use std::{process::Command, time::Duration};
use sui_audit::{
    config::{load_worker_config, resolve_secret, WorkerConfig},
    protocol::{
        Job, JobStatus, UserReportArgs, WorkerPollRequest, WorkerPollResponse, WorkerResultRequest,
    },
};
use tracing::{error, info, warn};

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Parser)]
struct Args {
    #[arg(short, long, default_value = "worker.toml")]
    config: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let args = Args::parse();
    let config = load_worker_config(&args.config)?;
    let token = resolve_secret(
        &config.master.token,
        &config.master.token_env,
        "master worker token",
    )?;
    let client = Client::new();
    let poll_interval = Duration::from_secs(config.master.poll_interval_seconds);

    loop {
        match poll_once(&client, &config, &token).await {
            Ok(Some(job)) => {
                info!("claimed job {}", job.job_id);
                let result = run_job(&config, job).await;
                if let Err(err) = result {
                    error!("job handling failed: {err:#}");
                }
            }
            Ok(None) => {}
            Err(err) => warn!("poll failed: {err:#}"),
        }
        tokio::time::sleep(poll_interval).await;
    }
}

async fn poll_once(client: &Client, config: &WorkerConfig, token: &str) -> Result<Option<Job>> {
    let url = format!(
        "{}/api/worker/poll",
        config.master.url.trim_end_matches('/')
    );
    let req = WorkerPollRequest {
        worker_id: config.worker.id.clone(),
        worker_name: config.worker.name.clone(),
        tags: config.worker.tags.clone(),
        version: VERSION.to_string(),
    };
    let resp: WorkerPollResponse = client
        .post(url)
        .bearer_auth(token)
        .json(&req)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    Ok(resp.job)
}

async fn run_job(config: &WorkerConfig, job: Job) -> Result<()> {
    let result = match job.job_type.as_str() {
        "ping" => Ok(run_ping(config, &job)),
        "user_report" => run_user_report(config, &job).await,
        other => Ok(WorkerResultRequest {
            job_id: job.job_id.clone(),
            worker_id: config.worker.id.clone(),
            status: JobStatus::Failed,
            summary: format!("unsupported job type: {other}"),
            report_path: None,
            detail: None,
        }),
    }?;

    send_result(config, result).await
}

fn run_ping(config: &WorkerConfig, job: &Job) -> WorkerResultRequest {
    WorkerResultRequest {
        job_id: job.job_id.clone(),
        worker_id: config.worker.id.clone(),
        status: JobStatus::Done,
        summary: format!("pong from {}", config.worker.name),
        report_path: None,
        detail: Some(json!({
            "worker_id": config.worker.id,
            "worker_name": config.worker.name,
            "version": VERSION
        })),
    }
}

async fn run_user_report(config: &WorkerConfig, job: &Job) -> Result<WorkerResultRequest> {
    let args: UserReportArgs =
        serde_json::from_value(job.args.clone()).context("parse user_report args")?;
    let mut command = Command::new(&config.audit.run_script);
    command.current_dir(&config.audit.repo_dir);
    command.arg("--user-report").arg(&args.user);
    command.arg("--period").arg(&args.period);
    if let Some(date) = &args.date {
        command.arg("--date").arg(date);
    }

    let output = command.output().context("run audit command")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = format!("{stdout}{stderr}");
    let report_path = extract_report_path(&combined);

    if output.status.success() {
        Ok(WorkerResultRequest {
            job_id: job.job_id.clone(),
            worker_id: config.worker.id.clone(),
            status: JobStatus::Done,
            summary: format!(
                "user_report 完成: user={} period={}",
                args.user, args.period
            ),
            report_path,
            detail: Some(json!({
                "user": args.user,
                "period": args.period,
                "date": args.date,
                "exit_code": output.status.code()
            })),
        })
    } else {
        Ok(WorkerResultRequest {
            job_id: job.job_id.clone(),
            worker_id: config.worker.id.clone(),
            status: JobStatus::Failed,
            summary: format!(
                "user_report 失败: user={} period={} exit={:?}\n{}",
                args.user,
                args.period,
                output.status.code(),
                tail_text(&combined, 1200)
            ),
            report_path,
            detail: Some(json!({
                "user": args.user,
                "period": args.period,
                "date": args.date,
                "exit_code": output.status.code()
            })),
        })
    }
}

async fn send_result(config: &WorkerConfig, result: WorkerResultRequest) -> Result<()> {
    let token = resolve_secret(
        &config.master.token,
        &config.master.token_env,
        "master worker token",
    )?;
    let client = Client::new();
    let url = format!(
        "{}/api/worker/result",
        config.master.url.trim_end_matches('/')
    );
    client
        .post(url)
        .bearer_auth(token)
        .json(&result)
        .send()
        .await?
        .error_for_status()?;
    Ok(())
}

fn extract_report_path(output: &str) -> Option<String> {
    for line in output.lines() {
        if let Some((_, path)) = line.split_once("Markdown 报告:") {
            return Some(path.trim().to_string());
        }
        if let Some((_, path)) = line.split_once("report_path=") {
            return Some(path.trim().to_string());
        }
    }
    None
}

fn tail_text(text: &str, max_chars: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= max_chars {
        text.to_string()
    } else {
        chars[chars.len() - max_chars..].iter().collect()
    }
}
