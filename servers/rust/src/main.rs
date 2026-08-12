use axum::{
    Router,
    body::Bytes,
    extract::{Extension, Path, Query, Request},
    http::{HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use std::{
    collections::HashMap,
    net::{Ipv4Addr, SocketAddr},
};

#[derive(Clone)]
struct User {
    id: &'static str,
    name: &'static str,
    tier: &'static str,
}

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

async fn parameters(
    Path((account, item)): Path<(String, String)>,
    Query(query): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    format!(
        "{}:{}:{}\n",
        account,
        item,
        query.get("filter").map(String::as_str).unwrap_or("")
    )
}

async fn authenticate(mut request: Request, next: Next) -> Response {
    if request.headers().get(header::AUTHORIZATION)
        != Some(&HeaderValue::from_static("Bearer benchmark-token"))
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    request.extensions_mut().insert(User {
        id: "user-7",
        name: "Andre",
        tier: "gold",
    });
    next.run(request).await
}

async fn authenticated_context(Extension(user): Extension<User>) -> impl IntoResponse {
    format!("{}:{}:{}\n", user.id, user.name, user.tier)
}

async fn echo_body(body: Bytes) -> impl IntoResponse {
    (
        [(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/octet-stream"),
        )],
        body,
    )
}

#[tokio::main]
async fn main() {
    let port = std::env::args()
        .nth(1)
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(18080);
    let protected = Router::new()
        .route("/context", get(authenticated_context))
        .layer(middleware::from_fn(authenticate));
    let app = Router::new()
        .route("/plaintext", get(plaintext))
        .route("/accounts/{account}/items/{item}", get(parameters))
        .route("/body", post(echo_body))
        .merge(protected);
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .expect("bind benchmark server");
    axum::serve(listener, app)
        .await
        .expect("serve benchmark requests");
}
