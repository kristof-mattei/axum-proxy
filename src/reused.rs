use std::convert::Infallible;
use std::sync::Arc;
use std::task::{Context, Poll};

use client::HttpConnector;
#[cfg(feature = "__rustls")]
use client::RustlsConnector;
use http::uri::{Authority, Scheme};
use http::{Error as HttpError, Request, Response};
use hyper::body::{Body as HttpBody, Incoming};
#[cfg(feature = "nativetls")]
use hyper_tls::HttpsConnector as NativeTlsConnector;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::Connect;
use tower_service::Service;

use crate::future::RevProxyFuture;
use crate::rewrite::PathRewriter;
use crate::{Error, client};

type BoxErr = Box<dyn std::error::Error + Send + Sync>;

/// The return type of [`builder()`], [`builder_http()`] and [`builder_https()`].
#[derive(Debug)]
pub struct Builder<C = HttpConnector, B = Incoming> {
    client: Arc<Client<C, B>>,
    scheme: Scheme,
    authority: Authority,
}

impl<C, B> Clone for Builder<C, B> {
    fn clone(&self) -> Self {
        Self {
            client: Arc::clone(&self.client),
            scheme: self.scheme.clone(),
            authority: self.authority.clone(),
        }
    }
}

impl<C, B> Builder<C, B> {
    pub fn build<Pr>(&self, path: Pr) -> ReusedService<Pr, C, B> {
        let Self {
            client,
            scheme,
            authority,
        } = Clone::clone(self);
        ReusedService {
            client,
            scheme,
            authority,
            path,
        }
    }
}

/// Builder of [`ReusedService`], with [`client::http_default()`].
///
/// For the meaning of "authority", refer to the documentation of [`Uri`](http::uri::Uri).
///
/// # Errors
///
/// When `authority` cannot be converted into an [`Authority`].
pub fn builder_http<B, A>(authority: A) -> Result<Builder<HttpConnector, B>, HttpError>
where
    B: HttpBody + Send,
    B::Data: Send,
    Authority: TryFrom<A>,
    <Authority as TryFrom<A>>::Error: Into<HttpError>,
{
    builder(client::http_default(), Scheme::HTTP, authority)
}

/// Builder of [`ReusedService`], with [`client::https_default()`].
///
/// This is the same as [`builder_nativetls()`].
///
/// For the meaning of "authority", refer to the documentation of [`Uri`](http::uri::Uri).
///
/// # Errors
///
/// When `authority` cannot be converted into an [`Authority`].
#[cfg(any(feature = "https", feature = "nativetls"))]
#[cfg_attr(docsrs, doc(cfg(any(feature = "https", feature = "nativetls"))))]
pub fn builder_https<B, A>(
    authority: A,
) -> Result<Builder<NativeTlsConnector<HttpConnector>, B>, HttpError>
where
    B: HttpBody + Send,
    B::Data: Send,
    Authority: TryFrom<A>,
    <Authority as TryFrom<A>>::Error: Into<HttpError>,
{
    builder(client::https_default(), Scheme::HTTPS, authority)
}

/// Builder of [`ReusedService`], with [`client::nativetls_default()`].
///
/// For the meaning of "authority", refer to the documentation of [`Uri`](http::uri::Uri).
///
/// # Errors
///
/// When `authority` cannot be converted into an [`Authority`].
#[cfg(feature = "nativetls")]
#[cfg_attr(docsrs, doc(cfg(feature = "nativetls")))]
pub fn builder_nativetls<B, A>(
    authority: A,
) -> Result<Builder<NativeTlsConnector<HttpConnector>, B>, HttpError>
where
    B: HttpBody + Send,
    B::Data: Send,
    Authority: TryFrom<A>,
    <Authority as TryFrom<A>>::Error: Into<HttpError>,
{
    builder(client::nativetls_default(), Scheme::HTTPS, authority)
}

/// Builder of [`ReusedService`], with [`client::rustls_default()`].
///
/// For the meaning of "authority", refer to the documentation of [`Uri`](http::uri::Uri).
///
/// # Errors
///
/// When `authority` cannot be converted into an [`Authority`].
#[cfg(feature = "__rustls")]
#[cfg_attr(docsrs, doc(cfg(feature = "rustls")))]
pub fn builder_rustls<B, A>(
    authority: A,
) -> Result<Builder<RustlsConnector<HttpConnector>, B>, HttpError>
where
    B: HttpBody + Send,
    B::Data: Send,
    Authority: TryFrom<A>,
    <Authority as TryFrom<A>>::Error: Into<HttpError>,
{
    builder(client::rustls_default(), Scheme::HTTPS, authority)
}

/// Builder of [`ReusedService`].
///
/// For the meaning of "scheme" and "authority", refer to the documentation of
/// [`Uri`](http::uri::Uri).
///
/// # Errors
///
/// When `scheme` or `authority` cannot be converted into a [`Scheme`] or [`Authority`].
pub fn builder<C, B, S, A>(
    client: Client<C, B>,
    scheme: S,
    authority: A,
) -> Result<Builder<C, B>, HttpError>
where
    Scheme: TryFrom<S>,
    <Scheme as TryFrom<S>>::Error: Into<HttpError>,
    Authority: TryFrom<A>,
    <Authority as TryFrom<A>>::Error: Into<HttpError>,
{
    let scheme = scheme.try_into().map_err(Into::into)?;
    let authority = authority.try_into().map_err(Into::into)?;
    Ok(Builder {
        client: Arc::new(client),
        scheme,
        authority,
    })
}

/// A [`Service<Request<B>>`] that sends a request and returns the response, sharing a [`Client`].
///
/// ```
/// # async fn run_test() {
/// # use axum_proxy::ReusedService;
/// # use axum_proxy::Static;
/// # use tower_service::Service;
/// # use http_body_util::Empty;
/// # use http::Request;
/// # use hyper::body::{Body, Bytes};
/// let svc_builder = axum_proxy::builder_http("example.com:1234").unwrap();
///
/// let mut svc1 = svc_builder.build(Static("bar"));
/// let mut svc2 = svc_builder.build(Static("baz"));
///
/// let req = Request::builder()
///     .uri("https://myserver.com/foo")
///     .body(Empty::<Bytes>::new())
///     .unwrap();
/// // http://example.com:1234/bar
/// let _res = svc1.call(req).await.unwrap();
///
/// let req = Request::builder()
///     .uri("https://myserver.com/foo")
///     .body(Empty::<Bytes>::new())
///     .unwrap();
/// // http://example.com:1234/baz
/// let _res = svc2.call(req).await.unwrap();
/// # }
/// ```
#[derive(Debug)]
pub struct ReusedService<Pr, C, B = Incoming> {
    client: Arc<Client<C, B>>,
    scheme: Scheme,
    authority: Authority,
    path: Pr,
}

impl<Pr: Clone, C, B> Clone for ReusedService<Pr, C, B> {
    #[inline]
    fn clone(&self) -> Self {
        Self {
            client: Arc::clone(&self.client),
            scheme: self.scheme.clone(),
            authority: self.authority.clone(),
            path: self.path.clone(),
        }
    }
}

impl<Pr, C, B> ReusedService<Pr, C, B> {
    /// # Errors
    ///
    /// When `scheme` or `authority` cannot be converted into a [`Scheme`] or [`Authority`].
    pub fn from<S, A>(
        client: Arc<Client<C, B>>,
        scheme: S,
        authority: A,
        path: Pr,
    ) -> Result<Self, HttpError>
    where
        Scheme: TryFrom<S>,
        <Scheme as TryFrom<S>>::Error: Into<HttpError>,
        Authority: TryFrom<A>,
        <Authority as TryFrom<A>>::Error: Into<HttpError>,
    {
        let scheme = scheme.try_into().map_err(Into::into)?;
        let authority = authority.try_into().map_err(Into::into)?;
        Ok(Self {
            client,
            scheme,
            authority,
            path,
        })
    }
}

impl<B, Pr> ReusedService<Pr, HttpConnector, B>
where
    B: HttpBody + Send,
    B::Data: Send,
{
    /// # Errors
    ///
    /// When `authority` cannot be converted into an [`Authority`].
    pub fn with_http_client<A>(
        client: Arc<Client<HttpConnector, B>>,
        authority: A,
        path: Pr,
    ) -> Result<Self, HttpError>
    where
        Authority: TryFrom<A>,
        <Authority as TryFrom<A>>::Error: Into<HttpError>,
    {
        let authority = authority.try_into().map_err(Into::into)?;
        Ok(Self {
            client,
            scheme: Scheme::HTTP,
            authority,
            path,
        })
    }
}

#[cfg(any(feature = "https", feature = "nativetls"))]
impl<Pr, B> ReusedService<Pr, NativeTlsConnector<HttpConnector>, B>
where
    B: HttpBody + Send,
    B::Data: Send,
{
    /// Alias to [`Self::with_nativetls_client()`].
    ///
    /// # Errors
    ///
    /// When `authority` cannot be converted into an [`Authority`].
    #[cfg_attr(docsrs, doc(cfg(any(feature = "https", feature = "nativetls"))))]
    pub fn with_https_client<A>(
        client: Arc<Client<NativeTlsConnector<HttpConnector>, B>>,
        authority: A,
        path: Pr,
    ) -> Result<Self, HttpError>
    where
        Authority: TryFrom<A>,
        <Authority as TryFrom<A>>::Error: Into<HttpError>,
    {
        let authority = authority.try_into().map_err(Into::into)?;
        Ok(Self {
            client,
            scheme: Scheme::HTTPS,
            authority,
            path,
        })
    }
}

#[cfg(feature = "nativetls")]
impl<Pr, B> ReusedService<Pr, NativeTlsConnector<HttpConnector>, B>
where
    B: HttpBody + Send,
    B::Data: Send,
{
    ///
    /// # Errors
    ///
    /// When `authority` cannot be converted into an [`Authority`].
    #[cfg_attr(docsrs, doc(cfg(feature = "nativetls")))]
    pub fn with_nativetls_client<A>(
        client: Arc<Client<NativeTlsConnector<HttpConnector>, B>>,
        authority: A,
        path: Pr,
    ) -> Result<Self, HttpError>
    where
        Authority: TryFrom<A>,
        <Authority as TryFrom<A>>::Error: Into<HttpError>,
    {
        let authority = authority.try_into().map_err(Into::into)?;
        Ok(Self {
            client,
            scheme: Scheme::HTTPS,
            authority,
            path,
        })
    }
}

#[cfg(feature = "__rustls")]
impl<Pr, B> ReusedService<Pr, RustlsConnector<HttpConnector>, B>
where
    B: HttpBody + Send,
    B::Data: Send,
{
    ///
    /// # Errors
    ///
    /// When `authority` cannot be converted into an [`Authority`].
    #[cfg_attr(docsrs, doc(cfg(feature = "rustls")))]
    pub fn with_rustls_client<A>(
        client: Arc<Client<RustlsConnector<HttpConnector>, B>>,
        authority: A,
        path: Pr,
    ) -> Result<Self, HttpError>
    where
        Authority: TryFrom<A>,
        <Authority as TryFrom<A>>::Error: Into<HttpError>,
    {
        let authority = authority.try_into().map_err(Into::into)?;
        Ok(Self {
            client,
            scheme: Scheme::HTTPS,
            authority,
            path,
        })
    }
}

impl<C, B, Pr> Service<Request<B>> for ReusedService<Pr, C, B>
where
    C: Connect + Clone + Send + Sync + 'static,
    B: HttpBody + Send + 'static + Unpin,
    B::Data: Send,
    B::Error: Into<BoxErr>,
    Pr: PathRewriter,
{
    type Response = Result<Response<Incoming>, Error>;
    type Error = Infallible;
    type Future = RevProxyFuture;

    fn poll_ready(&mut self, _cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, req: Request<B>) -> Self::Future {
        RevProxyFuture::new(
            &self.client,
            req,
            &self.scheme,
            &self.authority,
            &mut self.path,
        )
    }
}

#[cfg(test)]
mod test {
    use http::uri::{Parts, Uri};
    use mockito::ServerGuard;

    use super::*;
    use crate::{ReplaceAll, test_helper};

    async fn make_svc() -> (
        ServerGuard,
        ReusedService<ReplaceAll<'static>, HttpConnector, String>,
    ) {
        let server = mockito::Server::new_async().await;
        let uri = Uri::try_from(&server.url());
        assert!(uri.is_ok());
        let uri = uri.unwrap();

        let Parts {
            scheme, authority, ..
        } = uri.into_parts();

        let svc = ReusedService::from(
            Arc::new(client::http_default()),
            scheme.unwrap(),
            authority.unwrap(),
            ReplaceAll("foo", "goo"),
        );
        assert!(svc.is_ok());
        (server, svc.unwrap())
    }

    #[tokio::test]
    async fn match_path() {
        let (mut server, mut svc) = make_svc().await;
        test_helper::match_path(&mut server, &mut svc).await;
    }

    #[tokio::test]
    async fn match_query() {
        let (mut server, mut svc) = make_svc().await;
        test_helper::match_query(&mut server, &mut svc).await;
    }

    #[tokio::test]
    async fn match_post() {
        let (mut server, mut svc) = make_svc().await;
        test_helper::match_post(&mut server, &mut svc).await;
    }

    #[tokio::test]
    async fn match_header() {
        let (mut server, mut svc) = make_svc().await;
        test_helper::match_header(&mut server, &mut svc).await;
    }
}
