mod worker;

use crate::worker::Worker;

pub fn run(worker: &Worker) {
    worker.run();
}
