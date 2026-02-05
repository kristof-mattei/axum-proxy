mod server {
    use std::convert::Infallible;
    use std::net::SocketAddr;

    use http_body_util::Full;
    use hyper::body::Bytes;
    use hyper::server::conn::http2;
    use hyper::service::service_fn;
    use hyper::{Request, Response};
    use hyper_util::rt::{TokioExecutor, TokioIo};
    use tokio::net::TcpListener;

    async fn hello(
        request: Request<hyper::body::Incoming>,
    ) -> Result<Response<Full<Bytes>>, Infallible> {
        let uri = request.uri();

        let response = match uri.path() {
            "/healthz" => Bytes::from("We're healthy"),
            "/hello" => Bytes::from("Hello world"),
            _ => Bytes::from("Standard response"),
        };

        Ok(Response::new(Full::new(response)))
    }

    pub(super) async fn serve() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let addr = SocketAddr::from(([127, 0, 0, 1], 3000));

        // Bind to the port and listen for incoming TCP connections
        let listener = TcpListener::bind(addr).await?;

        loop {
            let (stream, _) = listener.accept().await?;
            let io = TokioIo::new(stream);

            tokio::task::spawn(async move {
                if let Err(error) = http2::Builder::new(TokioExecutor::new())
                    .serve_connection(io, service_fn(hello))
                    .await
                {
                    eprintln!("Error serving connection: {}", error);
                }
            });
        }
    }
}

mod proxy {
    use axum::Router;
    use axum_proxy::builder;
    use axum_proxy::client::Builder;
    use http::uri::Scheme;

    pub(super) async fn serve() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let proxy_service_builder = builder(
            Builder::new(hyper_util::rt::TokioExecutor::new())
                .http2_only(true)
                .build_http(),
            Scheme::HTTP,
            "127.0.0.1:3000",
        )?;

        let svc: axum_proxy::ReusedService<
            axum_proxy::Identity,
            axum_proxy::client::HttpConnector,
            axum::body::Body,
        > = proxy_service_builder.build(axum_proxy::rewrite::Identity {});

        let router = Router::new().fallback_service(svc);

        let listener = tokio::net::TcpListener::bind("127.0.0.1:2000")
            .await
            .unwrap();

        axum::serve(listener, router).await?;

        Ok(())
    }
}

#[tokio::main]
async fn main() {
    let _server = tokio::task::spawn(server::serve());

    let _proxy = tokio::task::spawn(proxy::serve());

    let text = reqwest::get("http://127.0.0.1:2000/hello")
        .await
        .unwrap()
        .text()
        .await;

    assert!(
        matches!(text.as_deref(), Ok("Hello world")),
        "Server returned response"
    );
}
