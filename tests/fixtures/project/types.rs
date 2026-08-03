pub trait Service {
    type Output;
    const NAME: &'static str;

    fn required(&self) -> Self::Output;

    fn defaulted(&self) -> usize {
        42
    }
}

pub struct Record {
    first: usize,
    second: String,
}

pub enum State {
    Ready,
    Failed(String),
}
