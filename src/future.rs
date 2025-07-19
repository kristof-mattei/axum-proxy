use std::convert::Infallible;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};

use http::uri::{Authority, Scheme};
use http::{Error as HttpError, Request, Response};
use hyper::body::{Body as HttpBody, Incoming};
use hyper_util::client::legacy::connect::Connect;
use hyper_util::client::legacy::{Client, ResponseFuture};

use crate::ProxyError;
use crate::rewrite::PathRewriter;

type BoxErr = Box<dyn std::error::Error + Send + Sync>;

pub struct RevProxyFuture {
    inner: Result<ResponseFuture, Option<HttpError>>,
}

impl RevProxyFuture {
    pub(crate) fn new<C, B, Pr>(
        client: &Client<C, B>,
        mut req: Request<B>,
        scheme: &Scheme,
        authority: &Authority,
        path: &mut Pr,
    ) -> Self
    where
        C: Connect + Clone + Send + Sync + 'static,
        B: HttpBody + Send + 'static + Unpin,
        B::Data: Send,
        B::Error: Into<BoxErr>,
        Pr: PathRewriter,
    {
        let inner = path
            .rewrite_uri(&mut req, scheme, authority)
            .map(|()| client.request(req))
            .map_err(Some);
        Self { inner }
    }
}

impl Future for RevProxyFuture {
    type Output = Result<Result<Response<Incoming>, ProxyError>, Infallible>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match self.inner {
            Ok(ref mut fut) => match Future::poll(Pin::new(fut), cx) {
                Poll::Ready(res) => Poll::Ready(Ok(res.map_err(ProxyError::RequestFailed))),
                Poll::Pending => Poll::Pending,
            },
            Err(ref mut e) => match e.take() {
                Some(e) => Poll::Ready(Ok(Err(ProxyError::InvalidUri(e)))),
                None => unreachable!("RevProxyFuture::poll() is called after ready"),
            },
        }
    }
}
