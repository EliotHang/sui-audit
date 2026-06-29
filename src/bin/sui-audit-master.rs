use anyhow::{Context, Result};
use axum::{
    extract::State,
    http::HeaderMap,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use clap::Parser;
use reqwest::Client;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    net::SocketAddr,
    path::Path,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};
use sui_audit::{
    config::{load_master_config, resolve_secret, MasterConfig},
    protocol::{Job, UserReportArgs, WorkerPollRequest, WorkerPollResponse, WorkerResultRequest},
};
use tokio::task::JoinHandle;
use tracing::{error, info, warn};
use uuid::Uuid;

#[derive(Parser)]
struct Args {
    #[arg(short, long, default_value = "master.toml")]
    config: String,
}

#[derive(Clone)]
struct AppState {
    db: Arc<Mutex<Connection>>,
    worker_token: String,
    telegram: TelegramClient,
}

#[derive(Clone)]
struct TelegramClient {
    client: Client,
    token: Option<String>,
    allowed_chat_ids: Vec<String>,
    allowed_user_ids: Vec<String>,
    poll_timeout_seconds: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let args = Args::parse();
    let config = load_master_config(&args.config)?;
    let worker_token = resolve_secret(
        &config.worker_auth.token,
        &config.worker_auth.token_env,
        "worker auth token",
    )?;

    let conn = open_db(&config.state.db_path)?;
    let telegram = TelegramClient::from_config(&config)?;
    let state = AppState {
        db: Arc::new(Mutex::new(conn)),
        worker_token,
        telegram: telegram.clone(),
    };

    let telegram_task = if config.telegram.mode == "long_poll" {
        Some(spawn_telegram_loop(state.clone()))
    } else {
        warn!(
            "telegram mode {} is not implemented yet",
            config.telegram.mode
        );
        None
    };

    let app = Router::new()
        .route("/health", get(health))
        .route("/api/worker/poll", post(worker_poll))
        .route("/api/worker/result", post(worker_result))
        .with_state(state);

    let addr: SocketAddr = config.server.bind.parse().context("parse server.bind")?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!("sui-audit-master listening on {}", addr);
    axum::serve(listener, app).await?;

    if let Some(task) = telegram_task {
        task.abort();
    }
    Ok(())
}

fn spawn_telegram_loop(state: AppState) -> JoinHandle<()> {
    tokio::spawn(async move {
        if let Err(err) = telegram_loop(state).await {
            error!("telegram loop stopped: {err:#}");
        }
    })
}

async fn health() -> &'static str {
    "ok"
}

async fn worker_poll(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<WorkerPollRequest>,
) -> Result<Json<WorkerPollResponse>, AppError> {
    authorize_worker(&state, bearer_token(&headers)?)?;
    let db = state.db.lock().map_err(|_| AppError::internal("db lock"))?;
    let now = now_ts();
    db.execute(
        "insert into workers(worker_id, name, tags_json, version, last_seen_at)
         values(?1, ?2, ?3, ?4, ?5)
         on conflict(worker_id) do update set
           name=excluded.name,
           tags_json=excluded.tags_json,
           version=excluded.version,
           last_seen_at=excluded.last_seen_at",
        params![
            req.worker_id,
            req.worker_name,
            serde_json::to_string(&req.tags).unwrap_or_else(|_| "[]".to_string()),
            req.version,
            now
        ],
    )?;

    let job = claim_next_job(&db, &req.worker_id, now)?;
    Ok(Json(WorkerPollResponse { job }))
}

async fn worker_result(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<WorkerResultRequest>,
) -> Result<Json<Value>, AppError> {
    authorize_worker(&state, bearer_token(&headers)?)?;

    let (chat_id, message) = {
        let db = state.db.lock().map_err(|_| AppError::internal("db lock"))?;
        let status =
            serde_json::to_string(&req.status).unwrap_or_else(|_| "\"failed\"".to_string());
        db.execute(
            "update jobs set status=?1, result_summary=?2, report_path=?3, finished_at=?4 where job_id=?5",
            params![status.trim_matches('"'), req.summary, req.report_path, now_ts(), req.job_id],
        )?;
        let chat_id: Option<String> = db
            .query_row(
                "select reply_chat_id from jobs where job_id=?1",
                params![req.job_id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        let mut message = format!(
            "任务完成\njob: {}\nworker: {}\nstatus: {:?}\n{}",
            req.job_id, req.worker_id, req.status, req.summary
        );
        if let Some(path) = &req.report_path {
            message.push_str(&format!("\nreport: {path}"));
        }
        (chat_id, message)
    };

    if let Some(chat_id) = chat_id {
        if let Err(err) = state.telegram.send_message(&chat_id, &message).await {
            warn!("telegram send result failed: {err:#}");
        }
    }

    Ok(Json(json!({"ok": true})))
}

fn authorize_worker(state: &AppState, token: &str) -> Result<(), AppError> {
    if token == state.worker_token {
        Ok(())
    } else {
        Err(AppError::unauthorized("invalid worker token"))
    }
}

fn bearer_token(headers: &HeaderMap) -> Result<&str, AppError> {
    let value = headers
        .get(axum::http::header::AUTHORIZATION)
        .ok_or_else(|| AppError::unauthorized("missing authorization header"))?
        .to_str()
        .map_err(|_| AppError::unauthorized("invalid authorization header"))?;
    value
        .strip_prefix("Bearer ")
        .ok_or_else(|| AppError::unauthorized("authorization must use Bearer token"))
}

fn open_db(path: &str) -> Result<Connection> {
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent)?;
    }
    let conn = Connection::open(path).with_context(|| format!("open sqlite db {path}"))?;
    conn.execute_batch(
        "
        create table if not exists workers(
          worker_id text primary key,
          name text not null,
          tags_json text not null,
          version text not null,
          last_seen_at integer not null
        );
        create table if not exists jobs(
          job_id text primary key,
          job_type text not null,
          args_json text not null,
          assigned_worker text,
          status text not null,
          reply_chat_id text,
          reply_message_id integer,
          result_summary text,
          report_path text,
          created_at integer not null,
          claimed_at integer,
          finished_at integer
        );
        ",
    )?;
    Ok(conn)
}

fn claim_next_job(db: &Connection, worker_id: &str, now: i64) -> Result<Option<Job>, AppError> {
    let row: Option<(String, String, String)> = db
        .query_row(
            "select job_id, job_type, args_json from jobs
             where status='queued' and (assigned_worker is null or assigned_worker=?1)
             order by created_at asc limit 1",
            params![worker_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;

    let Some((job_id, job_type, args_json)) = row else {
        return Ok(None);
    };

    db.execute(
        "update jobs set status='claimed', assigned_worker=?1, claimed_at=?2 where job_id=?3",
        params![worker_id, now, job_id],
    )?;

    let args =
        serde_json::from_str(&args_json).map_err(|err| AppError::internal(err.to_string()))?;
    Ok(Some(Job {
        job_id,
        job_type,
        args,
    }))
}

fn create_job(
    db: &Connection,
    job_type: &str,
    assigned_worker: Option<&str>,
    args: Value,
    reply_chat_id: Option<&str>,
    reply_message_id: Option<i64>,
) -> Result<String> {
    let job_id = format!("job_{}", Uuid::new_v4().simple());
    db.execute(
        "insert into jobs(job_id, job_type, args_json, assigned_worker, status, reply_chat_id, reply_message_id, created_at)
         values(?1, ?2, ?3, ?4, 'queued', ?5, ?6, ?7)",
        params![
            job_id,
            job_type,
            serde_json::to_string(&args)?,
            assigned_worker,
            reply_chat_id,
            reply_message_id,
            now_ts()
        ],
    )?;
    Ok(job_id)
}

fn now_ts() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

impl TelegramClient {
    fn from_config(config: &MasterConfig) -> Result<Self> {
        let token = match resolve_secret(
            &config.telegram.bot_token,
            &config.telegram.bot_token_env,
            "telegram bot token",
        ) {
            Ok(token) => Some(token),
            Err(err) => {
                warn!("telegram disabled: {err:#}");
                None
            }
        };
        Ok(Self {
            client: Client::new(),
            token,
            allowed_chat_ids: config.telegram.allowed_chat_ids.clone(),
            allowed_user_ids: config.telegram.allowed_user_ids.clone(),
            poll_timeout_seconds: config.telegram.poll_timeout_seconds,
        })
    }

    async fn send_message(&self, chat_id: &str, text: &str) -> Result<()> {
        let Some(token) = &self.token else {
            return Ok(());
        };
        let url = format!("https://api.telegram.org/bot{token}/sendMessage");
        self.client
            .post(url)
            .form(&[("chat_id", chat_id), ("text", text)])
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    fn allowed(&self, chat_id: i64, user_id: Option<i64>) -> bool {
        let chat_ok = self.allowed_chat_ids.is_empty()
            || self
                .allowed_chat_ids
                .iter()
                .any(|id| id == &chat_id.to_string());
        let user_ok = match user_id {
            Some(user_id) => {
                self.allowed_user_ids.is_empty()
                    || self
                        .allowed_user_ids
                        .iter()
                        .any(|id| id == &user_id.to_string())
            }
            None => self.allowed_user_ids.is_empty(),
        };
        chat_ok && user_ok
    }
}

async fn telegram_loop(state: AppState) -> Result<()> {
    let Some(token) = &state.telegram.token else {
        return Ok(());
    };
    let mut offset: Option<i64> = None;
    loop {
        let url = format!("https://api.telegram.org/bot{token}/getUpdates");
        let mut body = json!({
            "timeout": state.telegram.poll_timeout_seconds,
            "allowed_updates": ["message"]
        });
        if let Some(offset) = offset {
            body["offset"] = json!(offset);
        }
        let resp: TelegramUpdates = state
            .telegram
            .client
            .post(&url)
            .json(&body)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        if !resp.ok {
            warn!("telegram getUpdates returned ok=false");
            continue;
        }
        for update in resp.result {
            offset = Some(update.update_id + 1);
            if let Some(message) = update.message {
                handle_telegram_message(&state, message).await?;
            }
        }
    }
}

async fn handle_telegram_message(state: &AppState, message: TelegramMessage) -> Result<()> {
    let Some(text) = message.text.as_deref() else {
        return Ok(());
    };
    let user_id = message.from.as_ref().map(|user| user.id);
    if !state.telegram.allowed(message.chat.id, user_id) {
        warn!("ignored telegram message from unauthorized chat/user");
        return Ok(());
    }

    let reply =
        match build_job_from_command(state, text, message.chat.id.to_string(), message.message_id)
            .await
        {
            Ok(reply) => reply,
            Err(err) => format!("命令失败: {err:#}"),
        };
    state
        .telegram
        .send_message(&message.chat.id.to_string(), &reply)
        .await?;
    Ok(())
}

async fn build_job_from_command(
    state: &AppState,
    text: &str,
    chat_id: String,
    message_id: i64,
) -> Result<String> {
    let parts: Vec<&str> = text.split_whitespace().collect();
    match parts.as_slice() {
        ["/status"] => Ok("master online".to_string()),
        ["/workers"] => {
            let db = state.db.lock().map_err(|_| anyhow::anyhow!("db lock"))?;
            let mut stmt =
                db.prepare("select worker_id, name, last_seen_at from workers order by worker_id")?;
            let rows = stmt.query_map([], |row| {
                Ok(format!(
                    "- {} ({}) last_seen={}",
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?
                ))
            })?;
            let workers: Result<Vec<_>, _> = rows.collect();
            let workers = workers?;
            if workers.is_empty() {
                Ok("暂无 worker".to_string())
            } else {
                Ok(format!("Workers:\n{}", workers.join("\n")))
            }
        }
        ["/jobs"] => {
            let db = state.db.lock().map_err(|_| anyhow::anyhow!("db lock"))?;
            let mut stmt = db.prepare(
                "select job_id, job_type, status, coalesce(assigned_worker, '-') from jobs order by created_at desc limit 10",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok(format!(
                    "- {} {} {} worker={}",
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?
                ))
            })?;
            let jobs: Result<Vec<_>, _> = rows.collect();
            let jobs = jobs?;
            if jobs.is_empty() {
                Ok("暂无 job".to_string())
            } else {
                Ok(format!("Jobs:\n{}", jobs.join("\n")))
            }
        }
        ["/report_user", worker, user] => {
            enqueue_user_report(state, worker, user, "day", None, chat_id, message_id)
        }
        ["/report_user", worker, user, period] => {
            enqueue_user_report(state, worker, user, period, None, chat_id, message_id)
        }
        ["/report_user", worker, user, period, date] => enqueue_user_report(
            state,
            worker,
            user,
            period,
            Some(*date),
            chat_id,
            message_id,
        ),
        _ => Ok(
            "支持命令: /status /workers /jobs /report_user WORKER USER [day|week] [YYYY-MM-DD]"
                .to_string(),
        ),
    }
}

fn enqueue_user_report(
    state: &AppState,
    worker: &str,
    user: &str,
    period: &str,
    date: Option<&str>,
    chat_id: String,
    message_id: i64,
) -> Result<String> {
    if period != "day" && period != "week" {
        anyhow::bail!("period 只能是 day 或 week");
    }
    let args = serde_json::to_value(UserReportArgs {
        user: user.trim_matches(['[', ']']).to_string(),
        period: period.to_string(),
        date: date.map(ToString::to_string),
    })?;
    let db = state.db.lock().map_err(|_| anyhow::anyhow!("db lock"))?;
    let job_id = create_job(
        &db,
        "user_report",
        Some(worker),
        args,
        Some(&chat_id),
        Some(message_id),
    )?;
    Ok(format!("已创建任务 {job_id}，等待 worker {worker} 领取"))
}

#[derive(Debug, Deserialize)]
struct TelegramUpdates {
    ok: bool,
    result: Vec<TelegramUpdate>,
}

#[derive(Debug, Deserialize)]
struct TelegramUpdate {
    update_id: i64,
    message: Option<TelegramMessage>,
}

#[derive(Debug, Deserialize)]
struct TelegramMessage {
    message_id: i64,
    from: Option<TelegramUser>,
    chat: TelegramChat,
    text: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TelegramUser {
    id: i64,
}

#[derive(Debug, Deserialize)]
struct TelegramChat {
    id: i64,
}

#[derive(Debug)]
struct AppError {
    status: StatusCode,
    message: String,
}

impl AppError {
    fn unauthorized(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: message.into(),
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: message.into(),
        }
    }
}

impl From<rusqlite::Error> for AppError {
    fn from(value: rusqlite::Error) -> Self {
        Self::internal(value.to_string())
    }
}

impl From<serde_json::Error> for AppError {
    fn from(value: serde_json::Error) -> Self {
        Self::internal(value.to_string())
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
        (
            self.status,
            Json(json!({"ok": false, "error": self.message})),
        )
            .into_response()
    }
}
