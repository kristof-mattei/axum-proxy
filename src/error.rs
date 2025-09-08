use std::error::Error as StdError;
use std::fmt;

#[cfg(feature = "axum")]
use axum::response::{IntoResponse, Response};
use http::Error as HttpError;
use hyper_util::client::legacy::Error as HyperError;

#[derive(Debug)]
pub enum ProxyError {
    InvalidUri(HttpError),
    RequestFailed(HyperError),
}

impl fmt::Display for ProxyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::InvalidUri(ref e) => {
                write!(f, "Invalid uri: {}", e)
            },
            Self::RequestFailed(ref e) => {
                write!(f, "Request failed: {}", e)
            },
        }
    }
}

impl StdError for ProxyError {}

#[cfg(feature = "axum")]
#[cfg_attr(docsrs, doc(cfg(feature = "axum")))]
impl IntoResponse for ProxyError {
    fn into_response(self) -> Response {
        use http::StatusCode;
        use tracing::{Level, event};

        event!(Level::ERROR, error = %self);

        StatusCode::INTERNAL_SERVER_ERROR.into_response()
    }
}
