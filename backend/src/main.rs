use axum::extract::Path;
use axum::http::StatusCode;
use axum::{
    Json, Router,
    extract::State,
    routing::{get, put},
};
use mongodb::{
    Client,
    bson::{doc, oid::ObjectId},
};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tower_http::cors::{Any, CorsLayer};

#[derive(Debug, Serialize, Deserialize, Clone)]
struct Todo {
    #[serde(rename = "_id", skip_serializing_if = "Option::is_none")]
    id: Option<ObjectId>,
    title: String,
    done: bool,
}

#[derive(Debug, Deserialize)]
struct NewTodo {
    title: String,
}

#[derive(Clone)]
struct AppState {
    collection: mongodb::Collection<Todo>,
}

#[derive(Debug, Deserialize)]
struct UpdateTodoPayload {
    done: bool,
}

// GET /todos
async fn get_todos(State(state): State<AppState>) -> Json<Vec<Todo>> {
    let mut cursor = state
        .collection
        .find(doc! {}) // 全件取得
        .await
        .expect("Failed to find todos");

    let mut result = Vec::new();
    while cursor.advance().await.expect("Cursor advance failed") {
        result.push(
            cursor
                .deserialize_current()
                .expect("Failed to deserialize todo"),
        );
    }

    Json(result)
}

// POST /todos
async fn create_todo(State(state): State<AppState>, Json(payload): Json<NewTodo>) -> Json<Todo> {
    // まず id なしの Todo を作る
    let todo_without_id = Todo {
        id: None,
        title: payload.title,
        done: false,
    };

    // 挿入結果から inserted_id (BSON) をもらう
    let insert_result = state
        .collection
        .insert_one(&todo_without_id)
        .await
        .expect("Failed to insert todo");

    // ObjectId を取り出す
    let oid = insert_result
        .inserted_id
        .as_object_id()
        .expect("inserted_id is not an ObjectId");

    // id を入れた形でクライアントに返す
    let todo_with_id = Todo {
        id: Some(oid),
        ..todo_without_id
    };

    Json(todo_with_id)
}

// PUT /todos/:id  （完了フラグの更新）
async fn update_todo(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(payload): Json<UpdateTodoPayload>,
) -> StatusCode {
    // id は MongoDB の ObjectId 文字列
    let Ok(oid) = ObjectId::parse_str(&id) else {
        return StatusCode::BAD_REQUEST;
    };

    let filter = doc! { "_id": oid };
    let update = doc! { "$set": { "done": payload.done } };

    match state.collection.update_one(filter, update).await {
        Ok(result) if result.matched_count == 1 => StatusCode::OK,
        Ok(_) => StatusCode::NOT_FOUND,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

// DELETE /todos/:id
async fn delete_todo(State(state): State<AppState>, Path(id): Path<String>) -> StatusCode {
    let Ok(oid) = ObjectId::parse_str(&id) else {
        return StatusCode::BAD_REQUEST;
    };

    let filter = doc! { "_id": oid };

    match state.collection.delete_one(filter).await {
        Ok(result) if result.deleted_count == 1 => StatusCode::OK,
        Ok(_) => StatusCode::NOT_FOUND,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

#[tokio::main]
async fn main() {
    // MongoDB に接続
    let client = Client::with_uri_str("mongodb://localhost:27017")
        .await
        .expect("Failed to connect to MongoDB");

    let db = client.database("the_todo_app");
    let collection = db.collection::<Todo>("todos");

    let state = AppState { collection };

    // CORS 設定（全部許可：開発用）
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    // ルーター定義
    let app = Router::new()
        .route("/todos", get(get_todos).post(create_todo))
        .route("/todos/{id}", put(update_todo).delete(delete_todo))
        .with_state(state)
        .layer(cors);

    // サーバー起動
    let addr = SocketAddr::from(([0, 0, 0, 0], 3000)); // ★ ここを変更
    println!("Listening on {}", addr);

    axum::serve(
        TcpListener::bind(addr).await.unwrap(),
        app.into_make_service(),
    )
    .await
    .unwrap();
}
