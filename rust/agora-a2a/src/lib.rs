//! UniFFI bridge over `a2a-client` for the Agora Swift application.

uniffi::setup_scaffolding!();

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use a2a::event::StreamResponse;
use a2a::{GetTaskRequest, Message, Part, Role, SendMessageRequest, A2AError as ProtocolError};
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
    let card = resolver.resolve(&inner.base_url).await?;
    let card_json = serde_json::to_string(&card)?;

    let mut builder = A2AClientFactory::builder();
    if !inner.request_headers.is_empty() {
        builder = builder.with_interceptor(Arc::new(MultiHeaderInterceptor {
            headers: inner.request_headers.clone(),
        }));
    }

    let factory = builder.build();
    let client = Arc::new(factory.create_from_card(&card).await?);

    *inner.client.lock().unwrap() = Some(client.clone());
    *inner.card_json.lock().unwrap() = Some(card_json.clone());
    Ok((client, card_json))
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
