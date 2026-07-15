use agora_a2a::{A2aSession, StreamObserver};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct CollectingObserver {
    events: Mutex<Vec<String>>,
    done: Mutex<Option<Result<(), String>>>,
}

impl StreamObserver for CollectingObserver {
    fn on_event(&self, json: String) {
        self.events.lock().unwrap().push(json);
    }
    fn on_complete(&self) {
        *self.done.lock().unwrap() = Some(Ok(()));
    }
    fn on_error(&self, message: String) {
        *self.done.lock().unwrap() = Some(Err(message));
    }
}

#[tokio::test]
async fn fetch_card_and_stream_against_env_server() {
    let base = std::env::var("A2A_BASE_URL").unwrap_or_else(|_| "http://127.0.0.1:3000".into());
    let session = A2aSession::new(base.clone(), Default::default(), None).expect("session");
    let card = session.fetch_agent_card().await.expect("card");
    assert!(card.contains("supportedInterfaces") || card.contains("name"), "card={card}");

    let observer = Arc::new(CollectingObserver {
        events: Mutex::new(Vec::new()),
        done: Mutex::new(None),
    });
    let handle = session.start_stream("hello from agora-a2a".into(), None, observer.clone());

    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        if observer.done.lock().unwrap().is_some() {
            break;
        }
        if tokio::time::Instant::now() > deadline {
            handle.cancel();
            panic!("stream timed out against {base}");
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    let done = observer.done.lock().unwrap().clone().unwrap();
    done.expect("stream error");
    let events = observer.events.lock().unwrap().clone();
    assert!(!events.is_empty(), "expected stream events");
    assert!(events.iter().any(|e| e.contains("result")), "events={events:?}");
}

