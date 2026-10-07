/// One error type for every authentication or validation failure.
/// Never tell a remote peer which variant occurred.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    #[error("crypto error: {0}")]
    Crypto(&'static str),
}

pub type Result<T> = core::result::Result<T, Error>;

pub(crate) fn fail<T>(msg: &'static str) -> Result<T> {
    Err(Error::Crypto(msg))
}
