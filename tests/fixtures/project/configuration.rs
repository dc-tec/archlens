use serde::Deserialize;

#[derive(Deserialize)]
pub struct Config {
    pub token: String,
}

#[derive(Deserialize)]
pub struct Response {
    pub token: String,
}
