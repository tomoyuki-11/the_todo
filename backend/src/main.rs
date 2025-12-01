use axum::{
    Json, Router,
    extract::{Path, State},
    response::Html,
    routing::{get, put},
};
use dotenvy::dotenv;
use serde::Serialize;
use sqlx::{MySqlPool, mysql::MySqlPoolOptions};
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tower_http::cors::{Any, CorsLayer};

#[derive(Clone)]
struct AppState {
    db: MySqlPool,
}

async fn root() -> Html<&'static str> {
    Html("<h1>Rust Todo API</h1><p>とりあえず動いてるよ！</p>")
}

#[derive(Serialize, sqlx::FromRow, Debug)]
struct Todo {
    id: i32,
    title: String,
    done: bool,
}

#[derive(serde::Deserialize)]
struct NewTodo {
    title: String,
    done: bool,
}

#[derive(serde::Deserialize)]
struct UpdateTodo {
    done: bool,
}

async fn list_todos(State(state): State<AppState>) -> Json<Vec<Todo>> {
    let rows = sqlx::query_as::<_, Todo>("SELECT id, title, done FROM todos ORDER BY id")
        .fetch_all(&state.db)
        .await
        .expect("failed to fetch todos");
    Json(rows)
}

async fn create_todo(State(state): State<AppState>, Json(payload): Json<NewTodo>) -> Json<Todo> {
    let result = sqlx::query("INSERT INTO todos (title, done) VALUES (?, ?)")
        .bind(&payload.title)
        .bind(payload.done)
        .execute(&state.db)
        .await
        .expect("failed to insert todo");

    let id = result.last_insert_id() as i64;

    let todo = sqlx::query_as::<_, Todo>("SELECT id, title, done FROM todos WHERE id = ?")
        .bind(id)
        .fetch_one(&state.db)
        .await
        .expect("failed to fetch inserted todo");

    Json(todo)
}

async fn update_todo(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(payload): Json<UpdateTodo>,
) -> Json<Todo> {
    sqlx::query("UPDATE todos SET done = ? WHERE id = ?")
        .bind(payload.done)
        .bind(id)
        .execute(&state.db)
        .await
        .expect("failed to update todo");

    let todo = sqlx::query_as::<_, Todo>("SELECT id, title, done FROM todos WHERE id = ?")
        .bind(id)
        .fetch_one(&state.db)
        .await
        .expect("failed to fetch updated todo");

    Json(todo)
}

async fn delete_todo(State(state): State<AppState>, Path(id): Path<i64>) -> Json<bool> {
    let result = sqlx::query("DELETE FROM todos WHERE id = ?")
        .bind(id)
        .execute(&state.db)
        .await
        .expect("failed to delete todo");

    let success = result.rows_affected() == 1;
    Json(success)
}

#[tokio::main]
async fn main() {
    dotenv().ok();

    let db_url = std::env::var("DATABASE_URL").expect("DATABASE_URL must be set");

    let pool = MySqlPoolOptions::new()
        .max_connections(5)
        .connect(&db_url)
        .await
        .expect("failed to connect to MySQL");

    let state = AppState { db: pool };

    let app = Router::new()
        .route("/", get(root))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", put(update_todo).delete(delete_todo))
        .with_state(state)
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        );

    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
    println!("Listening on http://{}", addr);

    let listener = TcpListener::bind(addr).await.unwrap();

    axum::serve(listener, app).await.unwrap();
}
