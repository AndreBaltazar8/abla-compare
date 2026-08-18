use axum::{
    Json, Router,
    body::Bytes,
    extract::{Extension, Path, Query, Request},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
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

#[derive(Deserialize)]
struct NestedUser {
    id: i64,
    name: String,
    roles: Vec<String>,
}

#[derive(Deserialize)]
struct NestedItem {
    sku: String,
    qty: i64,
    price: i64,
}

#[derive(Deserialize)]
struct NestedRequest {
    request_id: String,
    user: NestedUser,
    items: Vec<NestedItem>,
    active: bool,
    note: String,
}

#[derive(Serialize)]
struct NestedResponse {
    active: bool,
    item_count: usize,
    primary_role: String,
    request_id: String,
    total: i64,
    user: String,
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

async fn route_tail(
    Path((account, order)): Path<(String, String)>,
    Query(query): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    format!(
        "{}:{}:{}\n",
        account,
        order,
        query.get("expand").map(String::as_str).unwrap_or("")
    )
}

async fn decoy() -> impl IntoResponse {
    "decoy\n"
}

async fn parameters_16(
    Path((p0, p1, p2, p3, p4, p5, p6, p7)): Path<(
        String,
        String,
        String,
        String,
        String,
        String,
        String,
        String,
    )>,
    Query(query): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    format!(
        "{}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}:{}\n",
        p0,
        p1,
        p2,
        p3,
        p4,
        p5,
        p6,
        p7,
        query.get("q0").map(String::as_str).unwrap_or(""),
        query.get("q1").map(String::as_str).unwrap_or(""),
        query.get("q2").map(String::as_str).unwrap_or(""),
        query.get("q3").map(String::as_str).unwrap_or(""),
        query.get("q4").map(String::as_str).unwrap_or(""),
        query.get("q5").map(String::as_str).unwrap_or(""),
        query.get("q6").map(String::as_str).unwrap_or(""),
        query.get("q7").map(String::as_str).unwrap_or(""),
    )
}

async fn headers_32(headers: HeaderMap) -> impl IntoResponse {
    let value = |name| {
        headers
            .get(name)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
    };
    format!(
        "{}:{}:{}:{}:{}\n",
        value("x-bench-00"),
        value("x-bench-07"),
        value("x-bench-15"),
        value("x-bench-23"),
        value("x-bench-31"),
    )
}

async fn fanout_target() -> impl IntoResponse {
    "fanout-target\n"
}

async fn query_32_named(Query(query): Query<HashMap<String, String>>) -> impl IntoResponse {
    let value = |name| query.get(name).map(String::as_str).unwrap_or("");
    format!(
        "{}:{}:{}:{}:{}:{}:{}:{}\n",
        value("field-00"),
        value("field-07"),
        value("field-13"),
        value("field-19"),
        value("field-25"),
        value("field-27"),
        value("field-29"),
        value("field-31"),
    )
}

async fn json_nested(Json(input): Json<NestedRequest>) -> Json<NestedResponse> {
    let total = input.items.iter().map(|item| item.qty * item.price).sum();
    let primary_role = input.user.roles.first().cloned().unwrap_or_default();
    let _parsed_but_unreturned = (&input.user.id, &input.note);
    let _sku_bytes: usize = input.items.iter().map(|item| item.sku.len()).sum();
    Json(NestedResponse {
        active: input.active,
        item_count: input.items.len(),
        primary_role,
        request_id: input.request_id,
        total,
        user: input.user.name,
    })
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
    let scenario = std::env::var("ABLA_COMPARE_SCENARIO").unwrap_or_default();
    let protected = Router::new()
        .route("/context", get(authenticated_context))
        .layer(middleware::from_fn(authenticate));
    let mut app = Router::new()
        .route("/plaintext", get(plaintext))
        .route("/accounts/{account}/items/{item}", get(parameters))
        .route(
            "/p/{p0}/s1/{p1}/s2/{p2}/s3/{p3}/s4/{p4}/s5/{p5}/s6/{p6}/s7/{p7}",
            get(parameters_16),
        )
        .route("/headers-32", get(headers_32))
        .route("/query-32", get(query_32_named))
        .route("/body", post(echo_body))
        .route("/json-nested", post(json_nested))
        .merge(protected);
    if scenario == "route-tail-128" {
        app = app.route("/ridiculous/{account}/orders/{order}", get(route_tail));
        for index in 0..128 {
            app = app.route(&format!("/ridiculous/decoy-{index}"), get(decoy));
        }
    }
    if scenario == "route-fanout-1024" {
        for index in 0..1024 {
            app = app.route(&format!("/fanout/decoy-{index}"), get(decoy));
        }
        app = app.route("/fanout/target", get(fanout_target));
    }
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .expect("bind benchmark server");
    axum::serve(listener, app)
        .await
        .expect("serve benchmark requests");
}
