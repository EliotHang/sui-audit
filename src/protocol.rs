use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Job {
    pub job_id: String,
    pub job_type: String,
    pub args: Value,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkerPollRequest {
    pub worker_id: String,
    pub worker_name: String,
    pub tags: Vec<String>,
    pub version: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkerPollResponse {
    pub job: Option<Job>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkerResultRequest {
    pub job_id: String,
    pub worker_id: String,
    pub status: JobStatus,
    pub summary: String,
    pub report_path: Option<String>,
    pub detail: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    Done,
    Failed,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct UserReportArgs {
    pub user: String,
    pub period: String,
    pub date: Option<String>,
}
