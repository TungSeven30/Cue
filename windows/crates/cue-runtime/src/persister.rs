//! Ports `JobRepository`'s write side: one background thread writes job
//! snapshots in the order they were queued, so the last write always wins
//! and no save ever blocks the UI or a pipeline thread.

use cue_core::jobs::{Job, JobStore};
use std::sync::mpsc::{channel, Sender};
use std::sync::Mutex;

enum Message {
    Save(Box<Job>),
    Delete(String),
    Flush(Sender<()>),
}

pub struct Persister {
    tx: Mutex<Sender<Message>>,
}

impl Persister {
    pub fn spawn(store: JobStore) -> Self {
        let (tx, rx) = channel::<Message>();
        std::thread::Builder::new()
            .name("cue-persist".into())
            .spawn(move || {
                let mut pending: Vec<Message> = Vec::new();
                while let Ok(first) = rx.recv() {
                    pending.push(first);
                    pending.extend(rx.try_iter());
                    // Coalesce: only the newest snapshot of each job is written.
                    let mut latest: Vec<(String, Option<Box<Job>>)> = Vec::new();
                    let mut flushes = Vec::new();
                    for message in pending.drain(..) {
                        match message {
                            Message::Save(job) => {
                                latest.retain(|(id, _)| id != &job.id);
                                latest.push((job.id.clone(), Some(job)));
                            }
                            Message::Delete(id) => {
                                latest.retain(|(i, _)| i != &id);
                                latest.push((id, None));
                            }
                            Message::Flush(done) => flushes.push(done),
                        }
                    }
                    for (id, job) in latest {
                        let result = match job {
                            Some(job) => store.save(&job),
                            None => store.delete(&id),
                        };
                        if let Err(e) = result {
                            eprintln!("Cue: {e}");
                        }
                    }
                    for done in flushes {
                        let _ = done.send(());
                    }
                }
            })
            .expect("spawn the persistence thread");
        Persister { tx: Mutex::new(tx) }
    }

    fn send(&self, message: Message) {
        let _ = self.tx.lock().unwrap_or_else(|e| e.into_inner()).send(message);
    }

    pub fn save(&self, job: &Job) {
        self.send(Message::Save(Box::new(job.clone())));
    }

    pub fn delete(&self, id: &str) {
        self.send(Message::Delete(id.to_string()));
    }

    pub fn flush(&self) {
        let (tx, rx) = channel();
        self.send(Message::Flush(tx));
        let _ = rx.recv();
    }
}
