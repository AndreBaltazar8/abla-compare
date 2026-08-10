use axum::{
    Router,
    http::{HeaderValue, header},
    response::IntoResponse,
    routing::get,
};
use std::net::{Ipv4Addr, SocketAddr};

async fn plaintext() -> impl IntoResponse {
    (
        [
            (
                header::CONTENT_TYPE,
                HeaderValue::from_static("text/plain; charset=utf-8"),
            ),
            (header::CONTENT_LENGTH, HeaderValue::from_static("14")),
        ],
        "hello, world!\n",
    )
}

#[tokio::main]
async fn main() {
    let port = std::env::args()
        .nth(1)
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(18080);
    let app = Router::new().route("/plaintext", get(plaintext));
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .expect("bind benchmark server");
    axum::serve(listener, app)
        .await
        .expect("serve benchmark requests");
}
