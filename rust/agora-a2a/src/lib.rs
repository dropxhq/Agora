//! UniFFI bridge over `a2a-client` for the Agora Swift application.

uniffi::setup_scaffolding!();

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use a2a::event::StreamResponse;
use a2a::{
    GetTaskRequest, Message, Part, Role, SendMessageRequest, A2AError as ProtocolError,
    SVC_PARAM_VERSION, VERSION as A2A_PROTOCOL_VERSION,
};
use a2a_client::agent_card::AgentCardResolver;
use a2a_client::client::A2AClient as RustA2AClient;
use a2a_client::factory::A2AClientFactory;
use a2a_client::middleware::CallInterceptor;
use a2a_client::transport::{ServiceParams, Transport};
use async_trait::async_trait;
use futures::StreamExt;
use serde_json::Value;
use tokio::runtime::Runtime;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("agora-a2a")
            .build()
            .expect("failed to create agora-a2a Tokio runtime")
    })
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum A2aError {
    #[error("{message}")]
    Client { message: String },
}

impl From<ProtocolError> for A2aError {
    fn from(value: ProtocolError) -> Self {
        Self::Client {
            message: value.message,
        }
    }
}

impl From<serde_json::Error> for A2aError {
    fn from(value: serde_json::Error) -> Self {
        Self::Client {
            message: value.to_string(),
        }
    }
}

/// Callback interface for streaming events (JSON strings compatible with ConversationVM.apply).
#[uniffi::export(with_foreign)]
pub trait StreamObserver: Send + Sync {
    fn on_event(&self, json: String);
    fn on_complete(&self);
    fn on_error(&self, message: String);
}

struct MultiHeaderInterceptor {
    headers: HashMap<String, String>,
}

#[async_trait]
impl CallInterceptor for MultiHeaderInterceptor {
    async fn before(&self, _method: &str, params: &mut ServiceParams) -> Result<(), ProtocolError> {
        for (name, value) in &self.headers {
            params
                .entry(name.clone())
                .or_default()
                .push(value.clone());
        }
        Ok(())
    }
}

type DynClient = RustA2AClient<Box<dyn Transport>>;

struct SessionInner {
    base_url: String,
    request_headers: HashMap<String, String>,
    message_metadata: Option<HashMap<String, Value>>,
    client: Mutex<Option<Arc<DynClient>>>,
    card_json: Mutex<Option<String>>,
    /// Negotiated `A2A-Version` value sent on every SDK call.
    protocol_version: Mutex<Option<String>>,
}

#[derive(uniffi::Object)]
pub struct A2aSession {
    inner: Arc<SessionInner>,
}

#[uniffi::export]
impl A2aSession {
    #[uniffi::constructor]
    pub fn new(
        base_url: String,
        request_headers: HashMap<String, String>,
        message_metadata_json: Option<String>,
    ) -> Result<Self, A2aError> {
        let message_metadata = parse_metadata_json(message_metadata_json)?;
        Ok(Self {
            inner: Arc::new(SessionInner {
                base_url: normalize_base_url(&base_url)?,
                request_headers,
                message_metadata,
                client: Mutex::new(None),
                card_json: Mutex::new(None),
                protocol_version: Mutex::new(None),
            }),
        })
    }

    /// Returns the agent card JSON (raw wire format).
    pub async fn fetch_agent_card(&self) -> Result<String, A2aError> {
        let inner = self.inner.clone();
        runtime()
            .spawn(async move { ensure_client(&inner).await.map(|(_, card)| card) })
            .await
            .map_err(|e| A2aError::Client {
                message: e.to_string(),
            })?
    }

    /// Returns the full task JSON.
    pub async fn get_task(&self, task_id: String) -> Result<String, A2aError> {
        let inner = self.inner.clone();
        runtime()
            .spawn(async move {
                let (client, _) = ensure_client(&inner).await?;
                let task = client
                    .get_task(&GetTaskRequest {
                        id: task_id,
                        history_length: None,
                        tenant: None,
                    })
                    .await?;
                Ok::<String, A2aError>(serde_json::to_string(&task)?)
            })
            .await
            .map_err(|e| A2aError::Client {
                message: e.to_string(),
            })?
    }

    /// Start a streaming message send. Events are delivered to `observer`.
    pub fn start_stream(
        &self,
        text: String,
        context_id: Option<String>,
        observer: Arc<dyn StreamObserver>,
    ) -> Arc<StreamHandle> {
        let cancelled = Arc::new(AtomicBool::new(false));
        let (cancel_tx, cancel_rx) = oneshot::channel::<()>();
        let cancel_tx = Arc::new(Mutex::new(Some(cancel_tx)));

        let inner = self.inner.clone();
        let cancelled_flag = cancelled.clone();

        let join: JoinHandle<()> = runtime().spawn(async move {
            let result =
                run_stream(inner, text, context_id, observer.clone(), cancelled_flag, cancel_rx)
                    .await;
            match result {
                Ok(()) => observer.on_complete(),
                Err(err) => observer.on_error(err.to_string()),
            }
        });

        Arc::new(StreamHandle {
            cancelled,
            cancel_tx,
            join: Mutex::new(Some(join)),
        })
    }
}

#[derive(uniffi::Object)]
pub struct StreamHandle {
    cancelled: Arc<AtomicBool>,
    cancel_tx: Arc<Mutex<Option<oneshot::Sender<()>>>>,
    join: Mutex<Option<JoinHandle<()>>>,
}

#[uniffi::export]
impl StreamHandle {
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        if let Some(tx) = self.cancel_tx.lock().unwrap().take() {
            let _ = tx.send(());
        }
        if let Some(join) = self.join.lock().unwrap().take() {
            join.abort();
        }
    }
}

/// Keep scheme/host/port only so `/.well-known/agent-card.json` resolves correctly.
fn normalize_base_url(base_url: &str) -> Result<String, A2aError> {
    let parsed = url::Url::parse(base_url).map_err(|e| A2aError::Client {
        message: format!("invalid base URL: {e}"),
    })?;
    let origin = parsed.origin().ascii_serialization();
    if origin == "null" {
        return Err(A2aError::Client {
            message: format!("base URL has no origin: {base_url}"),
        });
    }
    Ok(origin.trim_end_matches('/').to_string())
}

fn parse_metadata_json(
    message_metadata_json: Option<String>,
) -> Result<Option<HashMap<String, Value>>, A2aError> {
    match message_metadata_json {
        Some(raw) if !raw.trim().is_empty() => {
            let value: Value = serde_json::from_str(&raw)?;
            match value {
                Value::Object(map) => Ok(Some(map.into_iter().collect())),
                Value::Null => Ok(None),
                other => Err(A2aError::Client {
                    message: format!("message metadata must be a JSON object, got {other}"),
                }),
            }
        }
        _ => Ok(None),
    }
}

async fn ensure_client(inner: &SessionInner) -> Result<(Arc<DynClient>, String), A2aError> {
    if let (Some(client), Some(card)) = (
        inner.client.lock().unwrap().clone(),
        inner.card_json.lock().unwrap().clone(),
    ) {
        return Ok((client, card));
    }

    let http = a2a_client::default_reqwest_client(None).map_err(A2aError::from)?;
    let resolver = AgentCardResolver::new(Some(http));
    let mut card = resolver.resolve(&inner.base_url).await?;
    // Remote cards often advertise localhost endpoints; rewrite to the host we actually used.
    rewrite_card_localhost(&mut card, &inner.base_url)?;

    let card_version = protocol_version_from_card(&card);
    let protocol_version = negotiate_a2a_version(&card_version);
    let card_json = serde_json::to_string(&card)?;

    let headers = effective_request_headers(&inner.request_headers, &protocol_version);
    let mut builder = A2AClientFactory::builder();
    if !headers.is_empty() {
        builder = builder.with_interceptor(Arc::new(MultiHeaderInterceptor { headers }));
    }

    let factory = builder.build();
    let client = Arc::new(factory.create_from_card(&card).await?);

    *inner.client.lock().unwrap() = Some(client.clone());
    *inner.card_json.lock().unwrap() = Some(card_json.clone());
    *inner.protocol_version.lock().unwrap() = Some(protocol_version);
    Ok((client, card_json))
}

fn protocol_version_from_card(card: &a2a::AgentCard) -> String {
    card.supported_interfaces
        .iter()
        .find(|iface| iface.protocol_binding.eq_ignore_ascii_case("JSONRPC"))
        .or_else(|| card.supported_interfaces.first())
        .map(|iface| iface.protocol_version.clone())
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| A2A_PROTOCOL_VERSION.to_string())
}

/// `a2a-client` speaks A2A 1.0. Prefer the card's v1+ version; otherwise use the SDK version.
fn negotiate_a2a_version(card_version: &str) -> String {
    let normalized = normalize_a2a_version(card_version);
    if is_a2a_v1(&normalized) {
        normalized
    } else {
        A2A_PROTOCOL_VERSION.to_string()
    }
}

/// Merge user headers with `A2A-Version` (spec: 1.0 clients MUST send it).
fn effective_request_headers(
    user_headers: &HashMap<String, String>,
    protocol_version: &str,
) -> HashMap<String, String> {
    let mut headers = user_headers.clone();
    let has_version = headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case(SVC_PARAM_VERSION));
    if !has_version {
        headers.insert(
            SVC_PARAM_VERSION.to_string(),
            normalize_a2a_version(protocol_version),
        );
    }
    headers
}

fn normalize_a2a_version(version: &str) -> String {
    let trimmed = version.trim();
    if trimmed.is_empty() {
        return A2A_PROTOCOL_VERSION.to_string();
    }
    // Agent cards / clients use Major.Minor (ignore patch if present).
    let mut parts = trimmed.split('.');
    match (parts.next(), parts.next()) {
        (Some(major), Some(minor)) => format!("{major}.{minor}"),
        (Some(major), None) => format!("{major}.0"),
        _ => trimmed.to_string(),
    }
}

fn is_a2a_v1(protocol_version: &str) -> bool {
    protocol_version
        .split('.')
        .next()
        .and_then(|major| major.parse::<u32>().ok())
        .is_some_and(|major| major >= 1)
}

/// Replace localhost/127.0.0.1 in card interface URLs with the host from `base_url`.
fn rewrite_card_localhost(card: &mut a2a::AgentCard, base_url: &str) -> Result<(), A2aError> {
    let request_host = url::Url::parse(base_url)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.to_string()));
    let Some(request_host) = request_host else {
        return Ok(());
    };
    if is_localhost(&request_host) {
        return Ok(());
    }

    for iface in &mut card.supported_interfaces {
        iface.url = rewrite_localhost_url(&iface.url, &request_host);
    }
    Ok(())
}

fn rewrite_localhost_url(endpoint: &str, host: &str) -> String {
    let Ok(mut parsed) = url::Url::parse(endpoint) else {
        return endpoint.to_string();
    };
    match parsed.host_str() {
        Some(h) if is_localhost(h) => {
            if parsed.set_host(Some(host)).is_err() {
                return endpoint.to_string();
            }
            parsed.to_string()
        }
        _ => endpoint.to_string(),
    }
}

fn is_localhost(host: &str) -> bool {
    let lower = host.to_ascii_lowercase();
    lower == "localhost" || lower == "127.0.0.1"
}

async fn run_stream(
    inner: Arc<SessionInner>,
    text: String,
    context_id: Option<String>,
    observer: Arc<dyn StreamObserver>,
    cancelled: Arc<AtomicBool>,
    mut cancel_rx: oneshot::Receiver<()>,
) -> Result<(), A2aError> {
    let (client, _) = ensure_client(&inner).await?;

    let mut message = Message::new(Role::User, vec![Part::text(text)]);
    message.context_id = context_id;
    if let Some(metadata) = &inner.message_metadata {
        message.metadata = Some(metadata.clone());
    }

    let request = SendMessageRequest {
        message,
        configuration: None,
        metadata: None,
        tenant: None,
    };

    let mut stream = client.send_streaming_message(&request).await?;

    loop {
        if cancelled.load(Ordering::SeqCst) {
            break;
        }

        tokio::select! {
            _ = &mut cancel_rx => {
                break;
            }
            next = stream.next() => {
                match next {
                    Some(Ok(event)) => {
                        observer.on_event(encode_stream_event(&event)?);
                    }
                    Some(Err(err)) => {
                        return Err(err.into());
                    }
                    None => break,
                }
            }
        }
    }

    Ok(())
}

/// Emit JSON that ConversationVM.streamPayloadData can peel into typed events.
fn encode_stream_event(event: &StreamResponse) -> Result<String, A2aError> {
    let value = serde_json::to_value(event)?;
    let envelope = serde_json::json!({ "result": value });
    Ok(serde_json::to_string(&envelope)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrites_localhost_interface_urls() {
        assert_eq!(
            rewrite_localhost_url("http://localhost:17438/a2a", "192.168.92.23"),
            "http://192.168.92.23:17438/a2a"
        );
        assert_eq!(
            rewrite_localhost_url("http://127.0.0.1:17438/a2a", "192.168.92.23"),
            "http://192.168.92.23:17438/a2a"
        );
        assert_eq!(
            rewrite_localhost_url("http://192.168.1.1:17438/a2a", "192.168.92.23"),
            "http://192.168.1.1:17438/a2a"
        );
    }

    #[test]
    fn adds_a2a_version_header_from_card() {
        let headers = effective_request_headers(&HashMap::new(), "1.0");
        assert_eq!(
            headers.get(SVC_PARAM_VERSION).map(String::as_str),
            Some("1.0")
        );

        let mut user = HashMap::new();
        user.insert(SVC_PARAM_VERSION.into(), "0.3".into());
        let headers = effective_request_headers(&user, "1.0");
        assert_eq!(
            headers.get(SVC_PARAM_VERSION).map(String::as_str),
            Some("0.3")
        );
    }

    #[test]
    fn negotiates_sdk_version_when_card_is_v03() {
        assert_eq!(negotiate_a2a_version("1.0"), "1.0");
        assert_eq!(negotiate_a2a_version("0.3"), A2A_PROTOCOL_VERSION);
    }
}
