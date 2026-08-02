pub struct Worker;

impl Worker {
    pub fn run(&self) -> usize {
        self.helper()
    }

    fn helper(&self) -> usize {
        42
    }
}
