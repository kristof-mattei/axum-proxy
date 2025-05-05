#![cfg_attr(docsrs, feature(doc_cfg))]

//! `axum-proxy` is tower [`Service`s](tower_service::Service) that performs "reverse
//! proxy" with various rewriting rules.
//!
//! Internally these services use [`hyper::Client`] to send an incoming request to the another
//! server. The [`connector`](hyper::client::connect::Connect) for a client can be
//! [`HttpConnector`](hyper::client::HttpConnector), [`HttpsConnector`](hyper_tls::HttpsConnector),
//! or any ones whichever you want.
//!
//! # Examples
//!
//! There are two types of services, [`OneshotService`] and [`ReusedService`]. The
//! [`OneshotService`] *owns* the `Client`, while the [`ReusedService`] *shares* the `Client`
//! via [`Arc`](std::sync::Arc).
//!
//!
//! ## General usage
//!
//! ```
//! # async fn run_test() {
//! use axum_proxy::ReusedServiceBuilder;
//! use axum_proxy::{ReplaceAll, ReplaceN};
//!
//! use hyper::body::Bytes;
//! use http_body_util::Full;
//! use http::Request;
//! use tower_service::Service as _;
//!
//! let svc_builder = axum_proxy::builder_http("example.com:1234").unwrap();
//!
//! let req1 = Request::builder()
//!     .method("GET")
//!     .uri("https://myserver.com/foo/bar/foo")
//!     .body(Full::new(Bytes::new()))
//!     .unwrap();
//!
//! // Clones Arc<Client>
//! let mut svc1 = svc_builder.build(ReplaceAll("foo", "baz"));
//! // http://example.com:1234/baz/bar/baz
//! let _res = svc1.call(req1).await.unwrap();
//!
//! let req2 = Request::builder()
//!     .method("POST")
//!     .uri("https://myserver.com/foo/bar/foo")
//!     .header("Content-Type", "application/x-www-form-urlencoded")
//!     .body(Full::new(Bytes::from("key=value")))
//!     .unwrap();
//!
//! let mut svc2 = svc_builder.build(ReplaceN("foo", "baz", 1));
//! // http://example.com:1234/baz/bar/foo
//! let _res = svc2.call(req2).await.unwrap();
//! # }
//! ```
//!
//! In this example, the `svc1` and `svc2` shares the same `Client`, holding the `Arc<Client>`s
//! inside them.
//!
//! For more information of rewriting rules (`ReplaceAll`, `ReplaceN` *etc.*), see the
//! documentations of [`rewrite`].
//!
//!
//! ## With axum
//!
//! ```
//! # #[cfg(feature = "axum")] {
//! use axum_proxy::ReusedServiceBuilder;
//! use axum_proxy::{TrimPrefix, AppendSuffix, Static};
//!
//! use axum::Router;
//!
//! #[tokio::main]
//! async fn main() {
//!     let host1 = axum_proxy::builder_http("example.com").unwrap();
//!     let host2 = axum_proxy::builder_http("example.net:1234").unwrap();
//!
//!     let app = Router::new()
//!         .route_service("/healthcheck", host1.build(Static("/")))
//!         .route_service("/users/{*path}", host1.build(TrimPrefix("/users")))
//!         .route_service("/posts", host2.build(AppendSuffix("/")));
//!
//!     let listener = tokio::net::TcpListener::bind("0.0.0.0:3000")
//!        .await
//!        .unwrap();
//!
//!    axum::serve(listener, app).await.unwrap();
//! }
//! # }
//! ```
//!
//!
//! # Return Types
//!
//! The return type ([`Future::Output`](std::future::Future::Output)) of [`ReusedService`] and
//! [`OneshotService`] is `Result<Result<Response, Error>, Infallible>`. This is because axum's
//! [`Router`](axum::Router) accepts only such `Service`s.
//!
//! The [`Error`] type implements [`IntoResponse`](axum::response::IntoResponse) if you enable the
//! `axum`feature.
//! It returns an empty body, with the status code `INTERNAL_SERVER_ERROR`. The description of this
//! error will be logged out at [error](`log::error`) level in the
//! [`into_response()`](axum::response::IntoResponse::into_response()) method.
//!
//!
//! # Features
//!
//! By default only `http1` is enabled.
//!
//! - `http1`: uses `hyper/http1`
//! - `http2`: uses `hyper/http2`
//! - `https`: alias to `nativetls`
//! - `nativetls`: uses the `hyper-tls` crate
//! - `rustls`: alias to `rustls-webpki-roots`
//! - `rustls-webpki-roots`: uses the `hyper-rustls` crate, with the feature `webpki-roots`
//! - `rustls-native-roots`: uses the `hyper-rustls` crate, with the feature `rustls-native-certs`
//! - `rustls-http2`: `http2` plus `rustls`, and `rustls/http2` is enabled
//! - `axum`: implements [`IntoResponse`](axum::response::IntoResponse) for [`Error`]
//!
//! You must turn on either `http1`or `http2`. You cannot use the services if, for example, only
//! the `https` feature is on.
//!
//! Through this document, we use `rustls` to mean *any* of `rustls*` features unless otherwise
//! specified.

mod error;
pub use error::Error;

#[cfg(any(feature = "http1", feature = "http2"))]
#[cfg_attr(docsrs, doc(cfg(any(feature = "http1", feature = "http2"))))]
pub mod client;

pub mod rewrite;
pub use rewrite::*;

mod future;
pub use future::RevProxyFuture;

#[cfg(any(feature = "http1", feature = "http2"))]
mod oneshot;
#[cfg(any(feature = "http1", feature = "http2"))]
#[cfg_attr(docsrs, doc(cfg(any(feature = "http1", feature = "http2"))))]
pub use oneshot::OneshotService;

#[cfg(any(feature = "http1", feature = "http2"))]
mod reused;
#[cfg(any(feature = "http1", feature = "http2"))]
#[cfg_attr(docsrs, doc(cfg(any(feature = "http1", feature = "http2"))))]
pub use reused::Builder as ReusedServiceBuilder;
#[cfg(any(feature = "http1", feature = "http2"))]
#[cfg_attr(docsrs, doc(cfg(any(feature = "http1", feature = "http2"))))]
pub use reused::ReusedService;
#[cfg(all(
    any(feature = "http1", feature = "http2"),
    any(feature = "https", feature = "nativetls")
))]
#[cfg_attr(
    docsrs,
    doc(cfg(all(
        any(feature = "http1", feature = "http2"),
        any(feature = "https", feature = "nativetls")
    )))
)]
pub use reused::builder_https;
#[cfg(all(any(feature = "http1", feature = "http2"), feature = "nativetls"))]
#[cfg_attr(
    docsrs,
    doc(cfg(all(any(feature = "http1", feature = "http2"), feature = "nativetls")))
)]
pub use reused::builder_nativetls;
#[cfg(all(any(feature = "http1", feature = "http2"), feature = "__rustls"))]
#[cfg_attr(
    docsrs,
    doc(cfg(all(any(feature = "http1", feature = "http2"), feature = "rustls")))
)]
pub use reused::builder_rustls;
#[cfg(any(feature = "http1", feature = "http2"))]
#[cfg_attr(docsrs, doc(cfg(any(feature = "http1", feature = "http2"))))]
pub use reused::{builder, builder_http};

#[cfg(not(feature = "http1"))]
compile_error!("http1 is a mandatory feature");

#[cfg(all(
    any(feature = "rustls-ring", feature = "rustls-aws-lc"),
    not(any(feature = "rustls-webpki-roots", feature = "rustls-native-roots"))
))]
compile_error!(
    "When enabling rustls-ring and/or rustls-aws-lc, you must enable rustls-webpki-roots and/or rustls-native-roots"
);

#[cfg(test)]
mod test_helper {
    use std::convert::Infallible;

    use http::{Request, Response, StatusCode};
    use http_body_util::BodyExt;
    use hyper::body::Incoming;
    use mockito::{Matcher, ServerGuard};
    use tower_service::Service;

    use super::{Error, RevProxyFuture};

    async fn call<S, B>(
        service: &mut S,
        (method, suffix, content_type, body): (&str, &str, Option<&str>, B),
        expected: (StatusCode, &str),
    ) where
        S: Service<
                Request<String>,
                Response = Result<Response<Incoming>, Error>,
                Error = Infallible,
                Future = RevProxyFuture,
            >,
        B: Into<String>,
    {
        let mut builder = Request::builder()
            .method(method)
            .uri(format!("https://test.com{}", suffix));

        if let Some(content_type) = content_type {
            builder = builder.header("Content-Type", content_type);
        };

        let request = builder.body(body.into()).unwrap();

        let result = service.call(request).await.unwrap();
        assert!(result.is_ok());

        let response = result.unwrap();
        assert_eq!(response.status(), expected.0);

        let body = response.into_body().collect().await;
        assert!(body.is_ok());

        assert_eq!(body.unwrap().to_bytes(), expected.1);
    }

    pub async fn match_path<S>(server: &mut ServerGuard, svc: &mut S)
    where
        S: Service<
                Request<String>,
                Response = Result<Response<Incoming>, Error>,
                Error = Infallible,
                Future = RevProxyFuture,
            >,
    {
        let _mk = server
            .mock("GET", "/goo/bar/goo/baz/goo")
            .with_body("ok")
            .create_async()
            .await;

        call(
            svc,
            ("GET", "/foo/bar/foo/baz/foo", None, ""),
            (StatusCode::OK, "ok"),
        )
        .await;

        call(
            svc,
            ("GET", "/foo/bar/foo/baz", None, ""),
            (StatusCode::NOT_IMPLEMENTED, ""),
        )
        .await;
    }

    pub async fn match_query<S>(server: &mut ServerGuard, svc: &mut S)
    where
        S: Service<
                Request<String>,
                Response = Result<Response<Incoming>, Error>,
                Error = Infallible,
                Future = RevProxyFuture,
            >,
    {
        let _mk = server
            .mock("GET", "/goo")
            .match_query(Matcher::UrlEncoded("greeting".into(), "good day".into()))
            .with_body("ok")
            .create_async()
            .await;

        call(
            svc,
            ("GET", "/foo?greeting=good%20day", None, ""),
            (StatusCode::OK, "ok"),
        )
        .await;

        call(
            svc,
            ("GET", "/foo", None, ""),
            (StatusCode::NOT_IMPLEMENTED, ""),
        )
        .await;
    }

    pub async fn match_post<S>(server: &mut ServerGuard, svc: &mut S)
    where
        S: Service<
                Request<String>,
                Response = Result<Response<Incoming>, Error>,
                Error = Infallible,
                Future = RevProxyFuture,
            >,
    {
        let _mk = server
            .mock("POST", "/goo")
            .match_body("test")
            .with_body("ok")
            .create_async()
            .await;

        call(svc, ("POST", "/foo", None, "test"), (StatusCode::OK, "ok")).await;

        call(
            svc,
            ("PUT", "/foo", None, "test"),
            (StatusCode::NOT_IMPLEMENTED, ""),
        )
        .await;

        call(
            svc,
            ("POST", "/foo", None, "tests"),
            (StatusCode::NOT_IMPLEMENTED, ""),
        )
        .await;
    }

    pub async fn match_header<S>(server: &mut ServerGuard, svc: &mut S)
    where
        S: Service<
                Request<String>,
                Response = Result<Response<Incoming>, Error>,
                Error = Infallible,
                Future = RevProxyFuture,
            >,
    {
        let _mk = server
            .mock("POST", "/goo")
            .match_header("content-type", "application/json")
            .match_body(r#"{"key":"value"}"#)
            .with_body("ok")
            .create_async()
            .await;

        call(
            svc,
            (
                "POST",
                "/foo",
                Some("application/json"),
                r#"{"key":"value"}"#,
            ),
            (StatusCode::OK, "ok"),
        )
        .await;

        call(
            svc,
            ("POST", "/foo", None, r#"{"key":"value"}"#),
            (StatusCode::NOT_IMPLEMENTED, ""),
        )
        .await;

        call(
            svc,
            (
                "POST",
                "/foo",
                Some("application/json"),
                r#"{"key":"values"}"#,
            ),
            (StatusCode::NOT_IMPLEMENTED, ""),
        )
        .await;
    }
}
